# doc-guardian — CLAUDE.md

## Purpose

Documentation lifecycle toolkit for Claude Code plugin marketplaces. Three concerns under one roof:

1. **CHANGELOG hygiene** — enforce [Keep a Changelog](https://keepachangelog.com) 1.1.0 format + three-way sync between `CHANGELOG.md` latest entry ↔ `plugin.json` description ↔ `marketplace.json` description.
2. **Doc-update guardrail** — Stop hook that blocks turn-end when a commit changes ≥3 code files but updates none of `CHANGELOG.md` / `README.md` / `CLAUDE.md` / `changelog/`.
3. **Bootstrap migration** — for marketplaces with many legacy plugins lacking `CHANGELOG.md`, batch-init from existing `plugin.json` description run-on prose.

History: started as `changelog-tools` v0.1.x for CHANGELOG-only concerns. Renamed to `doc-tools` in v0.2.0 when the user-level `~/.claude/hooks/changelog-update.sh` got absorbed — its real intent (per the original prompt) was always "update **README/CLAUDE.md/CHANGELOG.md** on big changes," not just CHANGELOG.

## Skills

| Skill | Purpose |
|-------|---------|
| `changelog-validate` | KAC compliance + 3-way sync drift. Exit 0/1/2/3/4 for CI. |
| `changelog-init` | Bootstrap `CHANGELOG.md` for one plugin from `plugin.json` description (init mode) or rewrite non-KAC headers (normalize mode with section remap + preamble injection). |
| `changelog-migrate` | Batch run `changelog-init` across an entire marketplace; produces markdown migration report. |

Skill names keep the `changelog-` prefix for clarity even though the plugin is now `doc-guardian`. Future doc-related skills (e.g., `doc-validate` checking README/CLAUDE.md staleness) can use other prefixes.

## Hooks

| File | Event | Behavior | Config gate |
|------|-------|----------|-------------|
| `hooks/doc-update-guard.sh` | `Stop` | Block turn-end when HEAD commit has ≥3 code files but no doc updates. Auto-bypass via `stop_hook_active=true`. | `enabled`, `min_changed_files` |
| `hooks/claude-md-reminder.sh` | `PostToolUse` (Bash) | After `git commit`, block when ≥2 architectural/config files changed but `CLAUDE.md` did not. | `claude_md.*` |
| `hooks/sync-wiki-check.sh` | `Stop` | Block when today's commits touched `changelog/` but the wiki was not synced. Passes through when the repo has no GitHub origin or wiki is disabled. | `wiki_sync.*` |

**Never hardcode judgement criteria in these scripts.** Everything comes from
`scripts/doc-update-config.sh`. That file is also the cautionary tale: its
pre-2.0.0 version used `local -n` (bash 4.3+) on a platform whose `/bin/bash`
is 3.2.57, so `code_extensions` and `doc_files` overrides were silently
discarded while the hook appeared to work. Keep it bash-3.2-clean and keep
`scripts/test-doc-update-config.sh` green.

Full design rationale: [`references/doc-update-design.md`](references/doc-update-design.md). Includes both originally-documented decisions (per-commit not per-day for compact-resilience; Stop+block trade-off vs warn-only) and previously-implicit ones (3-file threshold, code-extension allowlist, 4-doc-files acceptance set).

## Three-Tier Hook Config Injection

Precedence high → low:

```
1. <repo>/.claude/doc-guardian.json    ← per-project (highest)
2. ~/.cache/doc-guardian/config.json   ← per-machine
3. built-in defaults                ← in scripts/doc-update-config.sh
```

Plus kill-switch:

```
~/.cache/doc-guardian/disabled         ← touch to silence the hook entirely
```

Schema (all fields optional, missing keys fall through):

```json
{
  "enabled": true,
  "min_changed_files": 3,
  "code_extensions": ["py", "ts", "swift", ...],
  "doc_files": ["CHANGELOG.md", "README.md", "CLAUDE.md", "changelog/"],
  "skip_paths": ["~/Developer/scratch/**"]
}
```

`code_extensions` and `doc_files` use **full replace** (provide complete list); `skip_paths` is **append across layers**.

## Format Spec (KAC 1.1.0)

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-05-02

### Added
- New thing

### Fixed
- Old bug
```

Six allowed section types: **Added / Changed / Deprecated / Removed / Fixed / Security**.

Version header: `[MAJOR.MINOR.PATCH] - YYYY-MM-DD` (brackets, ISO date). Em-dash format `## 2.37.0 — 2026-05-02` is non-conformant; auto-fix via `changelog-init normalize`.

## Three-Way Sync Rule

`changelog-validate` enforces:

- `plugin.json` `version` == `marketplace.json` plugin entry `version` == latest non-Unreleased entry version in `CHANGELOG.md`
- `plugin.json` `description` mentions `v<version>` in first 400 chars (relaxed from "must start with" — PsychQuant style leads with product tagline)
- `marketplace.json` plugin description mentions `v<version>` in first 400 chars

Drift → exit code 3 + readable diff. `changelog-release` (Phase 2) auto-syncs all three.

## Why a Plugin

Could be loose scripts — but as a plugin:

- Skills are discoverable via `/doc-guardian:*`
- Hook auto-registers via `hooks.json` (no manual `~/.claude/settings.json` edit)
- `claude plugin marketplace update` distributes new validation rules
- Three-tier config supports per-machine + per-project override without script edits
- Other marketplace consumers benefit (not just PsychQuant)

## Phase 2 (separate release)

| Skill / Integration | Purpose |
|---------------------|---------|
| `changelog-add` | Interactive `[Unreleased]` entry creation. Calls Composio `changelog-generator` for commit parsing. |
| `changelog-release` | Promote `[Unreleased]` → `vX.Y.Z` + DATE. Auto-bump semver. Sync 3 files. |
| Hook into `plugin-deploy` / `mcp-deploy` / `cli-deploy` | Deploy-time CHANGELOG freshness check |
| ~~Absorb `claude-md-reminder.sh`~~ | **Done in v2.0.0** — merged from doc-guardian 1.0.2, judgement criteria moved to config |

## Related

- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
- [olivierlacan/keep-a-changelog](https://github.com/olivierlacan/keep-a-changelog)
- [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
- [`references/doc-update-design.md`](references/doc-update-design.md) — hook design rationale
- [`ComposioHQ/awesome-claude-skills/changelog-generator`](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/changelog-generator) — Phase 2 commit-parser integration target
