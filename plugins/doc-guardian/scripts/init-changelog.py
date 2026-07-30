#!/usr/bin/env python3
"""
init-changelog.py — Bootstrap CHANGELOG.md from plugin.json description

Parses the version segments out of `plugin.json` `description` field (PsychQuant pattern:
"vX.Y.Z: ... vA.B.C: ...") and emits a Keep a Changelog 1.1.0 compliant CHANGELOG.md.

Modes:
    init        — generate CHANGELOG.md from scratch (errors if file exists; --force to overwrite)
    normalize   — read existing non-KAC CHANGELOG.md and rewrite in strict KAC format
                  (e.g., convert em-dash header `## 2.37.0 — 2026-05-02` → `## [2.37.0] - 2026-05-02`)

Date resolution:
    1. Try `git log --diff-filter=A --pretty=%ad --date=short -- <plugin.json>` for the line
       that introduced `vX.Y.Z:` token
    2. Fallback: '(date unknown — please fill in)'

Output is idempotent in normalize mode; init mode refuses to overwrite without --force.

Usage:
    init-changelog.py init <plugin-path> [--force] [--dry-run]
    init-changelog.py normalize <plugin-path> [--dry-run]

Exit codes:
    0 success / 1 file-already-exists / 2 parse-failure / 4 IO error
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date as date_type
from pathlib import Path
from typing import Optional

# Match `vX.Y.Z:` or `vX.Y.Z ` at sentence boundaries (start-of-string OR after `. `)
# We further filter to "own-plugin major version" using current plugin.json version.
VERSION_SEGMENT_RE = re.compile(
    r"(?:^|(?<=[.;]\s)|(?<=[.;]\s\s)|(?<=\)\s)|(?<=\)\s\s))v(?P<version>\d+\.\d+\.\d+(?:\.\d+)?)(?::|\s+(?=\S))",
    re.MULTILINE,
)

# Markers that hint at section type
ADDED_MARKERS = re.compile(r"\b(NEW|新增|Added|introduces?|adds?)\b", re.IGNORECASE)
FIXED_MARKERS = re.compile(r"\b(fix(?:es|ed)?|bug|patch(?:es)?|修[復補])\b", re.IGNORECASE)
BREAKING_MARKERS = re.compile(r"\b(BREAKING|breaking change)\b", re.IGNORECASE)
DEPRECATED_MARKERS = re.compile(r"\b(deprecat(?:e|ed|ion))\b", re.IGNORECASE)
REMOVED_MARKERS = re.compile(r"\b(remov(?:e|ed|al))\b", re.IGNORECASE)
SECURITY_MARKERS = re.compile(r"\b(security|CVE|vulnerab|patch.*vuln)\b", re.IGNORECASE)

# Existing non-KAC version header in CHANGELOG.md (em-dash / no brackets)
EM_DASH_HEADER_RE = re.compile(
    r"^## (?P<version>\d+\.\d+\.\d+(?:\.\d+)?)\s+[—–-]\s+(?P<date>\d{4}-\d{2}-\d{2})\s*$",
    re.MULTILINE,
)


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class ParsedSegment:
    version: str  # e.g. "2.37.0"
    text: str  # raw prose between this version header and the next
    date: Optional[str] = None  # ISO date if discoverable
    sections: dict[str, list[str]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# plugin.json description parsing
# ---------------------------------------------------------------------------


def parse_description_segments(
    description: str, plugin_major: Optional[int] = None
) -> list[ParsedSegment]:
    """Split run-on description into version segments.

    If plugin_major is given (e.g., 3 for plugin currently on v3.x.x),
    only versions with that major are treated as segment headers — this
    filters out dep-version noise (e.g., 'ooxml-swift v0.21.10').
    """
    matches = list(VERSION_SEGMENT_RE.finditer(description))
    if not matches:
        return []

    # Filter by major if specified
    if plugin_major is not None:
        matches = [
            m for m in matches if int(m.group("version").split(".")[0]) == plugin_major
        ]
        if not matches:
            return []

    # De-dup: keep only first occurrence of each version (cross-references stay inline)
    seen_versions: set[str] = set()
    deduped: list[re.Match] = []
    for m in matches:
        v = m.group("version")
        if v not in seen_versions:
            seen_versions.add(v)
            deduped.append(m)
    matches = deduped

    segments: list[ParsedSegment] = []
    for i, m in enumerate(matches):
        version = m.group("version")
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(description)
        text = description[start:end].strip().rstrip(".")
        text = text.lstrip(":").strip()
        segments.append(ParsedSegment(version=version, text=text))
    return segments


def categorize_text(text: str) -> dict[str, list[str]]:
    """Best-effort routing of prose into KAC sections.

    Strategy:
    - Split into sentences (period-delimited)
    - Each sentence routed to most specific section that matches its markers
    - Sentences with no clear marker → Changed (catch-all per KAC convention)
    """
    sections: dict[str, list[str]] = {}

    # Sentence-ish split (period followed by space + capital, or end)
    sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z🆕])", text)

    for s in sentences:
        s = s.strip()
        if not s:
            continue

        # Order matters: most specific first
        if SECURITY_MARKERS.search(s):
            sections.setdefault("Security", []).append(s)
        elif BREAKING_MARKERS.search(s):
            # BREAKING is signaled in Changed section per KAC convention
            sections.setdefault("Changed", []).append(f"**BREAKING:** {s}")
        elif REMOVED_MARKERS.search(s):
            sections.setdefault("Removed", []).append(s)
        elif DEPRECATED_MARKERS.search(s):
            sections.setdefault("Deprecated", []).append(s)
        elif FIXED_MARKERS.search(s):
            sections.setdefault("Fixed", []).append(s)
        elif ADDED_MARKERS.search(s):
            sections.setdefault("Added", []).append(s)
        else:
            sections.setdefault("Changed", []).append(s)

    return sections


# ---------------------------------------------------------------------------
# Git date resolution
# ---------------------------------------------------------------------------


def find_version_introduction_date(
    repo_root: Path, plugin_json_relpath: str, version: str
) -> Optional[str]:
    """Best-effort: find the commit date when `v{version}:` was introduced into plugin.json.

    Uses `git log -S` (pickaxe) on the literal token. Returns ISO date or None.
    """
    # Try with colon (issue-driven-dev style) first, fall back to space-suffix
    for needle in (f"v{version}:", f"v{version} "):
        try:
            result = subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo_root),
                    "log",
                    "-S",
                    needle,
                    "--pretty=%ad",
                    "--date=short",
                    "--",
                    plugin_json_relpath,
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                lines = [l.strip() for l in result.stdout.splitlines() if l.strip()]
                if lines:
                    return lines[-1]  # oldest = earliest introduction
        except (subprocess.SubprocessError, OSError):
            continue
    return None
    return None


def resolve_git_repo(plugin_path: Path) -> Optional[Path]:
    """Walk up to find .git directory."""
    p = plugin_path.resolve()
    for parent in [p] + list(p.parents):
        if (parent / ".git").exists():
            return parent
    return None


# ---------------------------------------------------------------------------
# CHANGELOG rendering
# ---------------------------------------------------------------------------


KAC_PREAMBLE = """# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> ⚠ This file was bootstrapped by `changelog-tools:changelog-init` from the
> `plugin.json` description field. Section categorization is best-effort —
> review and refine `Added` / `Changed` / `Fixed` etc. as needed.

## [Unreleased]

"""


def render_entry(segment: ParsedSegment) -> str:
    """Render one ParsedSegment into KAC entry markdown."""
    date_str = segment.date or "(date unknown — please fill in)"
    header = f"## [{segment.version}] - {date_str}\n"
    body_parts = []

    # Stable section order per KAC convention
    section_order = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]
    for section in section_order:
        bullets = segment.sections.get(section, [])
        if not bullets:
            continue
        body_parts.append(f"\n### {section}\n")
        for b in bullets:
            body_parts.append(f"- {b}\n")

    return header + "".join(body_parts) + "\n"


def render_changelog(segments: list[ParsedSegment]) -> str:
    parts = [KAC_PREAMBLE]
    for s in segments:
        parts.append(render_entry(s))
    return "".join(parts).rstrip() + "\n"


# ---------------------------------------------------------------------------
# Normalize mode (existing non-KAC CHANGELOG → KAC)
# ---------------------------------------------------------------------------


# Common non-KAC section names → KAC equivalents (additive to bracket-header normalize)
SECTION_REMAP = {
    "Changes": "Changed",
    "Change": "Changed",
    "Migration": "Changed",
    "Migrations": "Changed",
    "Breaking": "Changed",  # KAC convention: BREAKING signaled inside Changed
    "BREAKING": "Changed",
    "Improvements": "Changed",
    "Improvement": "Changed",
    "Bug Fixes": "Fixed",
    "Bug Fix": "Fixed",
    "Bugfix": "Fixed",
    "Bugfixes": "Fixed",
    "New": "Added",
    "Features": "Added",
    "Feature": "Added",
    "Enhancements": "Changed",
    "Enhancement": "Changed",
}

KAC_PREAMBLE_INJECT = """All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

"""


def normalize_changelog(text: str) -> str:
    """Best-effort rewrite of non-KAC format to KAC strict.

    Three transforms (idempotent):
      1. Version header brackets:   `## 2.37.0 — 2026-05-02` → `## [2.37.0] - 2026-05-02`
      2. Section remap:             `### Changes` → `### Changed`, `### Migration` → `### Changed`
                                    (NEW prefixes like `### NEW: foo` become `### Added` with
                                    description retained as the next line — best-effort)
      3. Preamble injection:        if missing 'Keep a Changelog' reference, insert standard
                                    preamble after the `# Changelog` title.
    """
    # 1. Version headers (em-dash → bracket)
    text = EM_DASH_HEADER_RE.sub(r"## [\g<version>] - \g<date>", text)

    # 2. Section remap. Match `### <name>[: optional context]`
    def remap_section(match: re.Match) -> str:
        raw = match.group("raw")
        # Strip "NEW: " etc. prefixes
        cleaned = raw.strip()
        # Try direct remap first
        if cleaned in SECTION_REMAP:
            return f"### {SECTION_REMAP[cleaned]}"
        # Try first word
        first = cleaned.split(":")[0].split()[0] if cleaned else ""
        if first in SECTION_REMAP:
            return f"### {SECTION_REMAP[first]}"
        return match.group(0)  # unchanged

    text = re.sub(
        r"^### (?P<raw>[^\n]+?)\s*$",
        remap_section,
        text,
        flags=re.MULTILINE,
    )

    # 3. Preamble injection
    if "keep a changelog" not in text[:500].lower():
        # Find the `# Changelog` line and insert preamble after it
        m = re.match(r"^(# Changelog\s*\n+)", text)
        if m:
            text = m.group(1) + KAC_PREAMBLE_INJECT + text[m.end():]
        else:
            # No `# Changelog` title — prepend full preamble
            text = "# Changelog\n\n" + KAC_PREAMBLE_INJECT + text

    return text


# ---------------------------------------------------------------------------
# Main commands
# ---------------------------------------------------------------------------


def cmd_init(plugin_path: Path, force: bool, dry_run: bool) -> int:
    plugin_json = plugin_path / ".claude-plugin" / "plugin.json"
    changelog = plugin_path / "CHANGELOG.md"

    if not plugin_json.exists():
        print(f"ERROR: plugin.json not found: {plugin_json}", file=sys.stderr)
        return 4

    if changelog.exists() and not force:
        print(
            f"ERROR: CHANGELOG.md already exists: {changelog}\n"
            f"       Use --force to overwrite, or 'normalize' mode to convert in place.",
            file=sys.stderr,
        )
        return 1

    try:
        data = json.loads(plugin_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR: plugin.json invalid JSON: {exc}", file=sys.stderr)
        return 4

    description = data.get("description", "")
    if not description.strip():
        print(
            f"ERROR: plugin.json description is empty — nothing to migrate", file=sys.stderr
        )
        return 2

    # Derive major from plugin.json version to filter out dep-version noise
    current_version = data.get("version", "0.1.0")
    try:
        plugin_major = int(current_version.split(".")[0])
    except (ValueError, IndexError):
        plugin_major = None

    segments = parse_description_segments(description, plugin_major=plugin_major)
    if not segments:
        print(
            f"WARN: no version segments matching major v{plugin_major}.x.x found — "
            f"writing skeleton with current version only",
            file=sys.stderr,
        )
        segments = [
            ParsedSegment(version=current_version, text=description.strip().rstrip("."))
        ]

    # Resolve dates via git log on plugin.json
    repo_root = resolve_git_repo(plugin_path)
    if repo_root:
        try:
            rel = plugin_json.relative_to(repo_root)
        except ValueError:
            rel = plugin_json
        for s in segments:
            s.date = find_version_introduction_date(repo_root, str(rel), s.version)

    # Categorize each segment's text
    for s in segments:
        s.sections = categorize_text(s.text)

    output = render_changelog(segments)
    date_known = sum(1 for s in segments if s.date)

    if dry_run:
        print(f"=== DRY RUN: would write {changelog} ===\n", file=sys.stderr)
        print(output, file=sys.stderr)
        print(
            f"=== END DRY RUN ({len(segments)} segments, {date_known} with dates) ===",
            file=sys.stderr,
        )
    else:
        changelog.write_text(output, encoding="utf-8")
        print(
            f"✓ Wrote {changelog}\n"
            f"  segments: {len(segments)}, dates resolved: {date_known}/{len(segments)}",
            file=sys.stderr,
        )

    # JSON summary on stdout regardless of mode (for batch consumers)
    print(
        json.dumps(
            {
                "plugin_path": str(plugin_path),
                "changelog_path": str(changelog),
                "segments": len(segments),
                "dates_resolved": date_known,
                "versions": [s.version for s in segments],
                "dry_run": dry_run,
            }
        )
    )
    return 0


def cmd_normalize(plugin_path: Path, dry_run: bool) -> int:
    changelog = plugin_path / "CHANGELOG.md"

    if not changelog.exists():
        print(f"ERROR: CHANGELOG.md not found: {changelog}", file=sys.stderr)
        print("       Use 'init' mode to create from plugin.json description first.", file=sys.stderr)
        return 1

    original = changelog.read_text(encoding="utf-8")
    normalized = normalize_changelog(original)

    if normalized == original:
        print(f"✓ Already KAC compliant: {changelog}", file=sys.stderr)
        return 0

    if dry_run:
        print(f"=== DRY RUN: would normalize {changelog} ===\n")
        # Show line-level diff via simple comparison
        for i, (a, b) in enumerate(zip(original.splitlines(), normalized.splitlines()), start=1):
            if a != b:
                print(f"line {i}:\n  - {a}\n  + {b}")
        return 0

    changelog.write_text(normalized, encoding="utf-8")
    print(f"✓ Normalized {changelog}", file=sys.stderr)
    print(json.dumps({"plugin_path": str(plugin_path), "normalized": True}))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="Generate CHANGELOG.md from plugin.json description")
    p_init.add_argument("plugin_path")
    p_init.add_argument("--force", action="store_true", help="Overwrite existing CHANGELOG.md")
    p_init.add_argument("--dry-run", action="store_true", help="Print output without writing")

    p_norm = sub.add_parser(
        "normalize", help="Rewrite existing non-KAC CHANGELOG.md headers to KAC format"
    )
    p_norm.add_argument("plugin_path")
    p_norm.add_argument("--dry-run", action="store_true")

    args = parser.parse_args(argv)
    plugin_path = Path(args.plugin_path).resolve()

    if not plugin_path.is_dir():
        print(f"ERROR: not a directory: {plugin_path}", file=sys.stderr)
        return 4

    if args.cmd == "init":
        return cmd_init(plugin_path, args.force, args.dry_run)
    elif args.cmd == "normalize":
        return cmd_normalize(plugin_path, args.dry_run)
    else:
        parser.print_help()
        return 4


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
