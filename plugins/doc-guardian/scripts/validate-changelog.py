#!/usr/bin/env python3
"""
validate-changelog.py — Keep a Changelog 1.1.0 compliance + 3-way sync check

Usage:
    validate-changelog.py <plugin-path> [--marketplace <marketplace-json-path>] [--sync-chars N]

Plugin path conventions (auto-detected):
    <plugin-path>/CHANGELOG.md
    <plugin-path>/.claude-plugin/plugin.json
    <marketplace-json>/.claude-plugin/marketplace.json (optional, omit to skip 3-way check)

Exit codes:
    0 — pass
    1 — CHANGELOG.md missing
    2 — KAC compliance violation (parse + structural rules)
    3 — 3-way sync drift between CHANGELOG.md, plugin.json, marketplace.json
    4 — IO / CLI error

Output: human-readable report on stderr, machine-parseable JSON summary on stdout (last line).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# KAC 1.1.0 spec constants
# ---------------------------------------------------------------------------

# https://keepachangelog.com/en/1.1.0/
KAC_SECTIONS = {"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}

# ## [1.2.3] - 2026-05-02   or   ## [Unreleased]   or   ## [1.2.3] - (date unknown — fill in)
# Accept any non-empty trailer after `- `; ISO date check happens during validation pass.
VERSION_HEADER_RE = re.compile(
    r"^## \[(?P<version>Unreleased|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\](?: - (?P<date>.+?))?\s*$"
)
SECTION_HEADER_RE = re.compile(r"^### (?P<name>\w+)\s*$")

# Non-conformant patterns we want to flag explicitly
NON_KAC_VERSION_PATTERNS = [
    # ## 2.37.0 — 2026-05-02   (em-dash, no brackets — PsychQuant's existing freeform style)
    re.compile(r"^## (\d+\.\d+\.\d+)\s+[—–-]\s+(\d{4}-\d{2}-\d{2})\s*$"),
    # ## v1.2.3
    re.compile(r"^## v(\d+\.\d+\.\d+)"),
    # ## 1.2.3 (no date)
    re.compile(r"^## (\d+\.\d+\.\d+)\s*$"),
]


@dataclass
class ChangelogEntry:
    version: str  # e.g. "1.2.0" or "Unreleased"
    date: Optional[str]  # ISO date string or None for Unreleased
    sections: dict[str, list[str]] = field(default_factory=dict)  # section name → bullet lines
    line_no: int = 0  # 1-indexed line in source file
    raw_header: str = ""


@dataclass
class ValidationResult:
    plugin_path: str
    changelog_path: str
    plugin_json_path: str
    marketplace_json_path: Optional[str]
    has_changelog: bool
    kac_violations: list[str] = field(default_factory=list)
    sync_drifts: list[str] = field(default_factory=list)
    entries: list[ChangelogEntry] = field(default_factory=list)
    plugin_json_version: Optional[str] = None
    plugin_json_description: Optional[str] = None
    marketplace_version: Optional[str] = None
    marketplace_description: Optional[str] = None
    exit_code: int = 0

    def to_summary_dict(self) -> dict:
        return {
            "plugin_path": self.plugin_path,
            "exit_code": self.exit_code,
            "has_changelog": self.has_changelog,
            "kac_violation_count": len(self.kac_violations),
            "sync_drift_count": len(self.sync_drifts),
            "entry_count": len(self.entries),
            "latest_version_in_changelog": (
                next((e.version for e in self.entries if e.version != "Unreleased"), None)
            ),
            "plugin_json_version": self.plugin_json_version,
            "marketplace_version": self.marketplace_version,
        }


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_changelog(path: Path) -> tuple[list[ChangelogEntry], list[str]]:
    """
    Returns (entries, violations).
    Violations are KAC compliance issues discovered during parse.
    """
    violations: list[str] = []
    entries: list[ChangelogEntry] = []
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    current_entry: Optional[ChangelogEntry] = None
    current_section: Optional[str] = None

    for i, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip()

        # Detect version headers
        m_v = VERSION_HEADER_RE.match(line)
        if m_v:
            if current_entry:
                entries.append(current_entry)
            version = m_v.group("version")
            date = m_v.group("date")
            if version != "Unreleased" and not date:
                violations.append(
                    f"line {i}: '{version}' missing date (expected `## [{version}] - YYYY-MM-DD`)"
                )
            current_entry = ChangelogEntry(
                version=version,
                date=date,
                line_no=i,
                raw_header=line,
            )
            current_section = None
            continue

        # Detect non-KAC version-like headers
        if line.startswith("## ") and not line.startswith("## ["):
            # Skip metadata sections at top of file
            if line in {"## Format", "## Unreleased"}:
                pass  # tolerated
            else:
                for pat in NON_KAC_VERSION_PATTERNS:
                    if pat.match(line):
                        violations.append(
                            f"line {i}: non-KAC version header '{line.strip()}' — expected `## [VERSION] - YYYY-MM-DD`"
                        )
                        break

        # Detect section headers (### Added etc.)
        m_s = SECTION_HEADER_RE.match(line)
        if m_s and current_entry is not None:
            section_name = m_s.group("name")
            if section_name not in KAC_SECTIONS:
                violations.append(
                    f"line {i}: non-KAC section '### {section_name}' — allowed: {', '.join(sorted(KAC_SECTIONS))}"
                )
            current_section = section_name
            current_entry.sections.setdefault(section_name, [])
            continue

        # Bullet content
        if current_entry is not None and current_section is not None and line.strip():
            current_entry.sections[current_section].append(line)

    if current_entry:
        entries.append(current_entry)

    # Header-level validation
    if not entries:
        violations.append("no version entries found — file may not be KAC format")
    else:
        # First non-Unreleased entry should have a date
        first_released = next((e for e in entries if e.version != "Unreleased"), None)
        if first_released and not first_released.date:
            violations.append(
                f"latest released entry [{first_released.version}] (line {first_released.line_no}) has no date"
            )

        # Date format sanity (already enforced by regex but date content)
        for e in entries:
            if e.date and not re.match(r"^\d{4}-\d{2}-\d{2}$", e.date):
                violations.append(
                    f"line {e.line_no}: date '{e.date}' not ISO 8601 (YYYY-MM-DD)"
                )

    # File-level KAC preamble check (best effort)
    head = "\n".join(lines[:10]).lower()
    if "keep a changelog" not in head:
        violations.append(
            "file preamble missing 'Keep a Changelog' reference (recommended for spec compliance)"
        )

    return entries, violations


def load_plugin_json(path: Path) -> tuple[Optional[str], Optional[str], list[str]]:
    """Returns (version, description, violations)."""
    if not path.exists():
        return None, None, [f"plugin.json not found at {path}"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, None, [f"plugin.json invalid JSON: {exc}"]
    return data.get("version"), data.get("description"), []


def load_marketplace_entry(
    path: Path, plugin_name: str
) -> tuple[Optional[str], Optional[str], list[str]]:
    """Returns (version, description, violations) for the named plugin in marketplace.json."""
    if not path.exists():
        return None, None, [f"marketplace.json not found at {path}"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, None, [f"marketplace.json invalid JSON: {exc}"]
    entries = [p for p in data.get("plugins", []) if p.get("name") == plugin_name]
    if not entries:
        return None, None, [
            f"plugin '{plugin_name}' not registered in marketplace.json"
        ]
    if len(entries) > 1:
        return None, None, [
            f"plugin '{plugin_name}' registered {len(entries)} times in marketplace.json (duplicates)"
        ]
    return entries[0].get("version"), entries[0].get("description"), []


# ---------------------------------------------------------------------------
# 3-way sync check
# ---------------------------------------------------------------------------


def check_three_way_sync(
    entries: list[ChangelogEntry],
    plugin_version: Optional[str],
    plugin_description: Optional[str],
    marketplace_version: Optional[str],
    marketplace_description: Optional[str],
    sync_chars: int,
) -> list[str]:
    drifts: list[str] = []
    latest = next((e for e in entries if e.version != "Unreleased"), None)

    if not latest:
        drifts.append("no released entry in CHANGELOG.md to sync against")
        return drifts

    cv = latest.version

    # Version sync
    if plugin_version and plugin_version != cv:
        drifts.append(
            f"version mismatch: CHANGELOG latest = [{cv}], plugin.json version = {plugin_version}"
        )
    if marketplace_version and marketplace_version != cv:
        drifts.append(
            f"version mismatch: CHANGELOG latest = [{cv}], marketplace.json version = {marketplace_version}"
        )

    # Description should mention the latest version somewhere (looser than "starts with")
    # — PsychQuant-style descriptions often lead with product tagline, not version.
    expected_token = f"v{cv}"
    if plugin_description and expected_token not in plugin_description[:400]:
        drifts.append(
            f"plugin.json description does not mention '{expected_token}' in first 400 chars "
            f"— marketplace consumers won't see what's new in this release"
        )
    if marketplace_description and expected_token not in marketplace_description[:400]:
        drifts.append(
            f"marketplace.json description does not mention '{expected_token}' in first 400 chars"
        )

    # plugin.json vs marketplace.json description prefix should match (first sync_chars chars)
    if plugin_description and marketplace_description:
        a = plugin_description[:sync_chars]
        b = marketplace_description[:sync_chars]
        if a != b:
            drifts.append(
                f"description prefix mismatch (first {sync_chars} chars) between plugin.json and marketplace.json"
            )

    return drifts


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def run(plugin_path: Path, marketplace_json: Optional[Path], sync_chars: int) -> ValidationResult:
    plugin_json = plugin_path / ".claude-plugin" / "plugin.json"
    changelog = plugin_path / "CHANGELOG.md"
    plugin_name = plugin_path.name

    result = ValidationResult(
        plugin_path=str(plugin_path),
        changelog_path=str(changelog),
        plugin_json_path=str(plugin_json),
        marketplace_json_path=str(marketplace_json) if marketplace_json else None,
        has_changelog=changelog.exists(),
    )

    if not changelog.exists():
        result.exit_code = 1
        return result

    entries, kac_violations = parse_changelog(changelog)
    result.entries = entries
    result.kac_violations = kac_violations

    pv, pd, pj_violations = load_plugin_json(plugin_json)
    result.plugin_json_version = pv
    result.plugin_json_description = pd
    result.kac_violations.extend(pj_violations)  # treat plugin.json IO errors as KAC scope

    mv, md = None, None
    if marketplace_json:
        mv, md, mp_violations = load_marketplace_entry(marketplace_json, plugin_name)
        result.marketplace_version = mv
        result.marketplace_description = md
        result.kac_violations.extend(mp_violations)

    result.sync_drifts = check_three_way_sync(
        entries=entries,
        plugin_version=pv,
        plugin_description=pd,
        marketplace_version=mv,
        marketplace_description=md,
        sync_chars=sync_chars,
    )

    if result.kac_violations:
        result.exit_code = 2
    elif result.sync_drifts:
        result.exit_code = 3

    return result


def render_report(result: ValidationResult) -> str:
    lines = [f"=== changelog-validate: {result.plugin_path} ==="]
    if not result.has_changelog:
        lines.append(f"❌ MISSING: {result.changelog_path}")
        lines.append(
            "→ Run `/changelog-tools:changelog-init` to bootstrap from plugin.json description"
        )
        return "\n".join(lines)

    lines.append(f"📄 CHANGELOG.md: {len(result.entries)} entries parsed")
    if result.entries:
        latest = next((e for e in result.entries if e.version != "Unreleased"), None)
        if latest:
            lines.append(f"   latest released: [{latest.version}] - {latest.date or '(no date)'}")
        unreleased = next((e for e in result.entries if e.version == "Unreleased"), None)
        if unreleased:
            section_count = len([s for s in unreleased.sections if unreleased.sections[s]])
            lines.append(f"   [Unreleased]: {section_count} non-empty section(s)")

    if result.kac_violations:
        lines.append("")
        lines.append(f"❌ KAC violations ({len(result.kac_violations)}):")
        for v in result.kac_violations:
            lines.append(f"   • {v}")
    else:
        lines.append("✓ KAC compliant")

    if result.sync_drifts:
        lines.append("")
        lines.append(f"⚠ 3-way sync drift ({len(result.sync_drifts)}):")
        for d in result.sync_drifts:
            lines.append(f"   • {d}")
    else:
        lines.append("✓ 3-way sync OK")

    lines.append("")
    lines.append(f"Exit code: {result.exit_code}  ({_exit_meaning(result.exit_code)})")
    return "\n".join(lines)


def _exit_meaning(code: int) -> str:
    return {
        0: "pass",
        1: "CHANGELOG.md missing",
        2: "KAC compliance violation",
        3: "3-way sync drift",
        4: "IO / CLI error",
    }.get(code, "unknown")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin_path", help="Path to plugin directory (containing .claude-plugin/plugin.json)")
    parser.add_argument(
        "--marketplace",
        help="Path to marketplace.json file (optional; omit to skip 3-way sync drift on marketplace side)",
    )
    parser.add_argument(
        "--sync-chars",
        type=int,
        default=200,
        help="Number of leading description chars to compare for plugin.json vs marketplace.json sync (default 200)",
    )
    parser.add_argument(
        "--quiet", "-q", action="store_true", help="Skip human report; only print JSON summary"
    )
    args = parser.parse_args(argv)

    plugin_path = Path(args.plugin_path).resolve()
    if not plugin_path.is_dir():
        print(f"ERROR: not a directory: {plugin_path}", file=sys.stderr)
        return 4

    marketplace = Path(args.marketplace).resolve() if args.marketplace else None

    result = run(plugin_path, marketplace, args.sync_chars)

    if not args.quiet:
        print(render_report(result), file=sys.stderr)

    print(json.dumps(result.to_summary_dict()))
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
