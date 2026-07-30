#!/usr/bin/env python3
"""
migrate-marketplace.py — Batch initialize CHANGELOG.md across an entire marketplace

Walks `<marketplace-path>/plugins/*/`, runs `init-changelog.py init <plugin>` on each
that lacks a CHANGELOG.md (or all plugins with --force), then writes a migration report.

Usage:
    migrate-marketplace.py <marketplace-path> [--force] [--dry-run] [--only <name1,name2>]
                                              [--exclude <name1,name2>] [--report-out PATH]

Exit codes:
    0 success (all plugins processed; some may have failed individually — see report)
    4 IO / CLI error
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent


def run_init(
    plugin_path: Path, force: bool, dry_run: bool
) -> tuple[int, Optional[dict], str]:
    """
    Returns (exit_code, json_summary_dict_or_none, stderr_text)
    """
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "init-changelog.py"),
        "init",
        str(plugin_path),
    ]
    if force:
        cmd.append("--force")
    if dry_run:
        cmd.append("--dry-run")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.SubprocessError as exc:
        return 4, None, f"subprocess error: {exc}"

    summary: Optional[dict] = None
    # JSON summary is the last line of stdout
    stdout_lines = [l for l in result.stdout.splitlines() if l.strip()]
    if stdout_lines:
        try:
            summary = json.loads(stdout_lines[-1])
        except json.JSONDecodeError:
            pass

    return result.returncode, summary, result.stderr


def render_report(
    marketplace_path: Path,
    plugins_processed: list[dict],
    today: str,
    dry_run: bool,
) -> str:
    """Render markdown migration report."""
    total = len(plugins_processed)
    init_ok = [p for p in plugins_processed if p["status"] == "init_ok"]
    skipped = [p for p in plugins_processed if p["status"] == "skipped_existing"]
    failed = [p for p in plugins_processed if p["status"] == "failed"]

    title = "DRY RUN" if dry_run else "Applied"
    lines = [
        f"# Migration Report — {marketplace_path.name}",
        "",
        f"**Date**: {today}",
        f"**Mode**: {title}",
        f"**Total plugins scanned**: {total}",
        f"**CHANGELOG.md created (or would be)**: {len(init_ok)}",
        f"**Skipped (already has CHANGELOG.md)**: {len(skipped)}",
        f"**Failed**: {len(failed)}",
        "",
        "## Generated CHANGELOG.md",
        "",
    ]

    if init_ok:
        lines.append("| Plugin | Segments | Dates resolved | Versions |")
        lines.append("|--------|----------|----------------|----------|")
        for p in init_ok:
            s = p["summary"] or {}
            n_seg = s.get("segments", "?")
            n_date = s.get("dates_resolved", "?")
            versions = s.get("versions", []) or []
            v_str = ", ".join(versions[:5]) + ("..." if len(versions) > 5 else "")
            lines.append(
                f"| `{p['plugin']}` | {n_seg} | {n_date}/{n_seg} | {v_str} |"
            )
    else:
        lines.append("(none)")

    lines.extend(["", "## Skipped (existing CHANGELOG.md)", ""])
    if skipped:
        for p in skipped:
            lines.append(f"- `{p['plugin']}`")
    else:
        lines.append("(none)")

    lines.extend(["", "## Failed", ""])
    if failed:
        for p in failed:
            err = (p.get("stderr") or "").strip().splitlines()
            err_first = err[0] if err else "(no error message)"
            lines.append(f"- `{p['plugin']}` (exit {p['exit_code']}): {err_first}")
    else:
        lines.append("(none)")

    lines.extend(
        [
            "",
            "## Manual review needed",
            "",
            "Generated CHANGELOG.md files use best-effort categorization. Review each for:",
            "",
            "1. Section assignment — `### Added` / `### Changed` / `### Fixed` etc. may need re-categorization",
            "2. `(date unknown — please fill in)` entries — manually fill from git tags / release notes / memory",
            "3. Sentence splitting in non-English content (Chinese punctuation `。` not split)",
            "4. Cross-referenced versions (mentioned multiple times) — content from later mentions absorbed into prior segment",
            "",
            "Run `/changelog-tools:changelog-validate <plugin-path>` on each plugin after review.",
        ]
    )

    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "marketplace_path", help="Path to marketplace repo root (containing plugins/)"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing CHANGELOG.md files (default: skip them)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Don't write files; only render report"
    )
    parser.add_argument(
        "--only",
        help="Comma-separated list of plugin names to process (default: all)",
    )
    parser.add_argument(
        "--exclude",
        help="Comma-separated list of plugin names to skip",
    )
    parser.add_argument(
        "--report-out",
        help="Path to write migration report (default: <marketplace>/.claude-plugin/migration-report-YYYY-MM-DD.md)",
    )
    args = parser.parse_args(argv)

    marketplace = Path(args.marketplace_path).resolve()
    plugins_dir = marketplace / "plugins"
    if not plugins_dir.is_dir():
        print(f"ERROR: not a marketplace (missing plugins/): {marketplace}", file=sys.stderr)
        return 4

    only_set = set(args.only.split(",")) if args.only else None
    excl_set = set(args.exclude.split(",")) if args.exclude else set()

    plugins_processed: list[dict] = []

    plugin_dirs = sorted([p for p in plugins_dir.iterdir() if p.is_dir()])
    print(f"Scanning {len(plugin_dirs)} plugin(s) in {plugins_dir}", file=sys.stderr)

    for plugin_dir in plugin_dirs:
        name = plugin_dir.name
        if only_set and name not in only_set:
            continue
        if name in excl_set:
            print(f"  - {name}: excluded", file=sys.stderr)
            continue

        plugin_json = plugin_dir / ".claude-plugin" / "plugin.json"
        if not plugin_json.exists():
            print(f"  - {name}: no .claude-plugin/plugin.json — skipping", file=sys.stderr)
            continue

        changelog = plugin_dir / "CHANGELOG.md"
        if changelog.exists() and not args.force:
            print(f"  - {name}: CHANGELOG.md exists — skipped (use --force to overwrite)", file=sys.stderr)
            plugins_processed.append({"plugin": name, "status": "skipped_existing", "summary": None})
            continue

        print(f"  - {name}: running init…", file=sys.stderr)
        exit_code, summary, stderr = run_init(
            plugin_dir, force=args.force, dry_run=args.dry_run
        )

        if exit_code == 0:
            plugins_processed.append(
                {"plugin": name, "status": "init_ok", "summary": summary}
            )
        else:
            plugins_processed.append(
                {
                    "plugin": name,
                    "status": "failed",
                    "exit_code": exit_code,
                    "stderr": stderr,
                    "summary": summary,
                }
            )

    today = date.today().isoformat()
    report_path = (
        Path(args.report_out).resolve()
        if args.report_out
        else marketplace / ".claude-plugin" / f"migration-report-{today}.md"
    )

    report = render_report(marketplace, plugins_processed, today, args.dry_run)

    if args.dry_run:
        print("\n" + report, file=sys.stderr)
    else:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(report, encoding="utf-8")
        print(f"\n✓ Report written: {report_path}", file=sys.stderr)

    # Final JSON summary on stdout
    print(
        json.dumps(
            {
                "marketplace": str(marketplace),
                "total": len(plugins_processed),
                "init_ok": sum(1 for p in plugins_processed if p["status"] == "init_ok"),
                "skipped": sum(
                    1 for p in plugins_processed if p["status"] == "skipped_existing"
                ),
                "failed": sum(1 for p in plugins_processed if p["status"] == "failed"),
                "report_path": str(report_path),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
