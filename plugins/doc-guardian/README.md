# doc-guardian

Documentation lifecycle toolkit for Claude Code plugin marketplaces.

## What is this?

Three concerns under one roof:

1. **CHANGELOG hygiene** — enforce [Keep a Changelog](https://keepachangelog.com) 1.1.0 format + three-way sync (`CHANGELOG.md` ↔ `plugin.json` description ↔ `marketplace.json` description)
2. **Doc-update guardrail** — Stop hook that blocks turn-end when a commit changes ≥3 code files but updates none of `CHANGELOG.md` / `README.md` / `CLAUDE.md` / `changelog/`
3. **Bootstrap migration** — for marketplaces with many legacy plugins lacking `CHANGELOG.md`, batch-init from existing `plugin.json` description prose

## Why?

Audit of PsychQuant's marketplace surfaced a structural problem: **35 of 36 plugins had no `CHANGELOG.md`**. All release history lived in `plugin.json` `description` as a run-on string spanning 5+ versions, making history unreadable in the marketplace UI. Separately, a user-level Stop hook (`~/.claude/hooks/changelog-update.sh`) enforced "update doc when committing big changes" but only registered globally — every other plugin user had to recreate it.

`doc-guardian` consolidates these concerns: skills for CHANGELOG, three hooks for doc/CLAUDE.md/wiki enforcement, three-tier config injection so behavior is tunable per-machine and per-project.

## Skills

| Skill | What it does |
|-------|-------------|
| `/doc-guardian:changelog-validate <plugin-path>` | Check KAC compliance + 3-way sync drift. Exit 0/1/2/3/4 for CI. |
| `/doc-guardian:changelog-init <plugin-path>` | Initialize `CHANGELOG.md` from `plugin.json` description (`init` mode) OR rewrite non-KAC headers to KAC strict (`normalize` mode). |
| `/doc-guardian:changelog-migrate <marketplace-path>` | Batch: run `changelog-init` across an entire marketplace. Migration report per plugin. |
| `/doc-guardian:doc-guardian` | Run all three hook checks manually and report. For Codex and any agent that does not receive PostToolUse / Stop hooks. |

## Hooks

| File | Event | Behavior | Config gate |
|------|-------|----------|-------------|
| `hooks/doc-update-guard.sh` | `Stop` | Block turn-end when HEAD commit changed ≥3 code files but no doc was updated | `enabled`, `min_changed_files` |
| `hooks/claude-md-reminder.sh` | `PostToolUse` (Bash) | After `git commit`, block when ≥2 architectural/config files changed but `CLAUDE.md` did not | `claude_md.*` |
| `hooks/sync-wiki-check.sh` | `Stop` | Block when today's commits touched `changelog/` but the GitHub Wiki was not synced | `wiki_sync.*` |

Auto-registered via `hooks/hooks.json` on plugin install — no manual `~/.claude/settings.json` edit needed.

All three short-circuit to exit 0 when: the kill switch is set, `enabled` is false, the repo matches `skip_paths`, or the directory is not a git work tree. `sync-wiki-check` additionally passes through when the repo has no recognizable GitHub origin or has wiki disabled — there is no point blocking on a sync that is structurally impossible.

### Three-tier config injection

```
1. <repo>/.claude/doc-guardian.json    ← per-project (highest priority)
2. ~/.cache/doc-guardian/config.json   ← per-machine
3. built-in defaults                ← ships with the plugin
```

Plus kill-switch:

```bash
touch ~/.cache/doc-guardian/disabled    # one-touch silence
```

Schema (all fields optional):

```json
{
  "enabled": true,
  "min_changed_files": 3,
  "code_extensions": ["py", "ts", "swift"],
  "doc_files": ["CHANGELOG.md", "README.md"],
  "skip_paths": ["~/Developer/scratch/**", "/tmp/**"],

  "claude_md": {
    "enabled": true,
    "min_files": 2,
    "arch_patterns": ["^infra/", "flake\\.nix", "\\.github/workflows"]
  },

  "wiki_sync": {
    "enabled": false,
    "changelog_dir": "changelog/"
  }
}
```

`code_extensions` / `doc_files` / `arch_patterns` are **full replace** (give the complete list);
`skip_paths` **appends** across layers. Every default matches the pre-2.0.0 hardcoded value, so
an absent config file changes nothing.

Legacy `.claude/doc-tools.json` and `~/.cache/doc-tools/` are still read (applied first, then
overlaid by their `doc-guardian` equivalents), so existing setups keep working untouched.

Full design rationale: [`references/doc-update-design.md`](references/doc-update-design.md).

## Format spec (strict KAC 1.1.0)

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

**Six allowed section types**: Added / Changed / Deprecated / Removed / Fixed / Security. Anything else fails `changelog-validate` with exit code 2.

## Quick start

```bash
# Validate one plugin
/doc-guardian:changelog-validate plugins/issue-driven-dev

# Initialize a CHANGELOG.md from existing plugin.json description
/doc-guardian:changelog-init init plugins/che-word-mcp

# Normalize an existing non-KAC CHANGELOG.md (em-dash format → KAC bracket)
/doc-guardian:changelog-init normalize plugins/issue-driven-dev

# Batch migrate every plugin in a marketplace
/doc-guardian:changelog-migrate /path/to/marketplace-repo

# Disable the hook for this machine
touch ~/.cache/doc-guardian/disabled

# Disable the hook for one repo only
echo '{"enabled": false}' > .claude/doc-guardian.json
```

## Coming in Phase 2

| Skill / Integration | Purpose |
|---------------------|---------|
| `/doc-guardian:changelog-add <plugin-path>` *(Phase 2 — not implemented)* | Interactive `[Unreleased]` entry creation. Calls Composio's `changelog-generator` for git-commit parsing. |
| `/doc-guardian:changelog-release <plugin-path>` *(Phase 2 — not implemented)* | Promote `[Unreleased]` → `vX.Y.Z` + DATE. Auto-bump semver from sections. Sync 3 files. |
| Hooks into `plugin-deploy` / `mcp-deploy` / `cli-deploy` | Deploy-time CHANGELOG freshness check |
| ~~Absorb `claude-md-reminder.sh`~~ | **Done in v2.0.0** — merged from doc-guardian 1.0.2, judgement criteria moved to config |

## License

MIT
