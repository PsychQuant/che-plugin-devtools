# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.1] - 2026-07-31

`validate-changelog.py` 的 `--marketplace` 參數修正，並補上這支腳本的第一份測試（此前 0 覆蓋率）。修的是 #3。

### Fixed

- **`--marketplace` 傳目錄時不再 traceback**。usage 文字一直寫的是 `<marketplace-json>/.claude-plugin/marketplace.json`（目錄形式，自動接後綴），實作卻只接受完整檔案路徑 —— 照文件寫法傳目錄會在 `Path.read_text()` 拋 `IsADirectoryError`，使用者看到的是 Python traceback 而非一行錯誤訊息。

  根因是 `Path.exists()` 對目錄也回 `True`，既有的存在性檢查因此形同虛設。改用 `is_file()`，並讓兩種形式都合法：傳目錄自動接 `.claude-plugin/marketplace.json`，傳檔案直接用，都不可用才 exit 4 並印明確原因。

- **不傳 `--marketplace` 時不再謊報「3-way sync OK」**。此前無論是否讀了 marketplace.json，通過訊息一律是 `✓ 3-way sync OK`；而 marketplace 版本落後**正是這支工具唯一要抓的東西**，把只做過兩方的檢查報成三方是實質的假陽性。

  現在依實際檢查範圍顯示 `3-way` / `2-way`，2-way 時額外標明 `↳ marketplace.json NOT checked`。exit 3 的意義字串也由 `3-way sync drift` 改為 `sync drift` —— 沒有 `--marketplace` 時同樣會因 CHANGELOG ↔ plugin.json 落差而 exit 3，該路徑從未讀過第三個來源。

- **usage 文字自相矛盾修正**。第 6 行寫 `<marketplace-json-path>`（檔案）、第 11 行寫 `<marketplace-json>/.claude-plugin/marketplace.json`（目錄），兩種讀法而實作只支援其一。改為明列兩種皆可。

### Added

- **`test-validate-changelog.py`** —— 11 個 test，這支腳本的第一份測試。黑箱測試（subprocess 呼叫真實 CLI），因為它的契約是 exit code 與 stderr 文字，CI 消費的正是這兩者；import 層測試抓不到未捕捉的 traceback 與 argparse 行為。

  涵蓋三類：`--marketplace` 的四種路徑形式、報告措辭誠實性、以及四個 exit code 的回歸（此前無任何保護）。

## [2.0.0] - 2026-07-30

合併 `doc-tools` 0.2.0 與 `doc-guardian` 1.0.2，遷入新 marketplace `che-plugin-devtools`。版本號承接 `doc-guardian` 1.0.2（沿用其名稱與身份），而非 `doc-tools` 的 0.2.0。

### Changed

- **plugin 更名 `doc-tools` → `doc-guardian`**，兩者合併為一。呼叫方式由 `/doc-tools:*` 改為 `/doc-guardian:*`；skill 名不變。

  取名理由：合併後職責是 CHANGELOG + CLAUDE.md + wiki + README 的一致性**稽核與擋**，`guardian` 精確，`-tools`（處理文件的工具）指向錯誤的心智模型——那是 `docflow` / `document-skills` 在做的事。`doc-tools` 的 keywords 裡原本就列有 `doc-guardian`。

- **設定檔改名** `.claude/doc-tools.json` → `.claude/doc-guardian.json`，cache 目錄 `~/.cache/doc-tools/` → `~/.cache/doc-guardian/`。舊路徑保留 fallback（先讀舊、再由新的覆蓋），kill switch 兩個位置皆有效。

- **`claude-md-reminder` 的計數方式**：舊版把判準拆成三次獨立 `grep -c` 相加（設定檔 + `^web/...` + `^r_pkg/`），同時符合兩組的檔案（如 `web/app/package.json`）會被計兩次、等於偷偷降低門檻。新版合併為單一 regex，一個檔案只算一次。**這是刻意的行為差異**，會讓這類邊界案例比 1.0.2 稍微不容易觸發。

### Added

- **`claude-md-reminder` 與 `sync-wiki-check` 併入**（來自 doc-guardian 1.0.2），判準全面 config 化，**預設值逐字沿用原硬編碼值**，行為不變：
  - `claude_md.enabled` / `claude_md.min_files` / `claude_md.arch_patterns`
  - `wiki_sync.enabled` / `wiki_sync.changelog_dir`

  這兩支 hook 原本把某個 Next.js + R 專案的結構寫死在 shell 裡（`^web/(app|components|lib)/`、`^r_pkg/`、`_targets.R`、`changelog/`），其他專案要用就得改 code。這也完成了 doc-tools CLAUDE.md「Phase 2」列而未做的一項待辦。

- **`doc-guardian` skill**（來自 1.0.2）：手動跑 hook 邏輯並回報，供收不到 PostToolUse / Stop hook 的 Codex 使用。

- **`scripts/test-doc-update-config.sh`** — 20 個測試，涵蓋預設值、覆寫實際生效、legacy fallback、kill switch、bash 3.2 無 stderr。

### Fixed

- **double-fire（live bug）**：`doc-tools` 的 `doc-update-guard.sh` 與 `doc-guardian` 1.0.2 的 `changelog-update.sh` 是同一個檢查的兩份實作，而 `settings.json` 中**兩個 plugin 皆為 enabled**，每次 Stop 都跑兩遍。doc-tools 0.2.0 宣稱已解，但它移除的是 user-level 的 `~/.claude/hooks/changelog-update.sh`，plugin 版本仍在。本版只保留 `doc-update-guard.sh` 一支。

- **config 覆寫靜默失效（live bug）**：`doc-update-config.sh` 的 `_merge_config()` 用 `local -n`（nameref，bash 4.3+），但 macOS 是 `/bin/bash` 3.2.57。腳本有 `set -u` 而無 `set -e`，報 `local: -n: invalid option` 後**繼續執行**，結果 `enabled` / `min_changed_files` / `skip_paths` 正常，`code_extensions` / `doc_files` **寫了也不生效**，且每次觸發往 stderr 噴錯。改以空格分隔字串取代陣列傳遞，全面 bash 3.2 相容。

**Migration**

```bash
claude plugin uninstall doc-tools@psychquant-claude-plugins
claude plugin uninstall doc-guardian@che-local-plugins
claude plugin install doc-guardian@che-plugin-devtools
```

既有的 `.claude/doc-tools.json` 與 `~/.cache/doc-tools/` 無須改動即可繼續運作。

## [0.2.0] - 2026-05-02

### Changed
- **Renamed plugin from `changelog-tools` to `doc-tools`** — scope expanded from CHANGELOG-only to general documentation lifecycle. Skill names keep `changelog-` prefix (no need to retrain muscle memory) but plugin invocation changes from `/changelog-tools:*` to `/doc-tools:*`. Migration: `claude plugin uninstall changelog-tools && claude plugin install doc-tools@psychquant-claude-plugins`.
- Plugin description rewritten to reflect the three concerns (CHANGELOG hygiene + doc-update guardrail + bootstrap migration) instead of CHANGELOG-only positioning.

### Added
- **NEW Stop hook**: `hooks/doc-update-guard.sh` — absorbs the user-level `~/.claude/hooks/changelog-update.sh` from `che-claude-config`. Blocks turn-end when HEAD commit changed ≥3 code files but updated none of `CHANGELOG.md` / `README.md` / `CLAUDE.md` / `changelog/`. Auto-registered via `hooks/hooks.json` (no manual `~/.claude/settings.json` edit needed). Original design rationale preserved: per-commit (compact-aware), Stop+block (intentional because doc updates are clearly actionable), 3-file threshold (heuristic for significant change), code-extension allowlist (R/sh/sql/py/ts/swift/go/rs/etc — user's primary languages), `stop_hook_active=true` bypass (infinite-loop protection).
- **NEW three-tier config injection** for the hook (precedence high → low):
  1. `<repo>/.claude/doc-tools.json` — per-project override
  2. `~/.cache/doc-tools/config.json` — per-machine override
  3. Built-in defaults in `scripts/doc-update-config.sh`
- **NEW kill-switch**: `~/.cache/doc-tools/disabled` flag file — touch to silence the hook entirely (mirrors `archive-first` plugin pattern).
- **Config schema**: `{enabled, min_changed_files, code_extensions[], doc_files[], skip_paths[]}` — all fields optional, missing keys fall through to defaults. `code_extensions` and `doc_files` use full replace; `skip_paths` appends across layers.
- **NEW `references/doc-update-design.md`** — full hook design rationale captured for the first time. Covers both originally-documented decisions (per-commit not per-day, Stop+block intentional) AND previously-implicit ones (3-file threshold reasoning, code-extension list source, 4-doc-files acceptance set, lenient pass criterion). Also includes a "Rejected alternatives" table mirroring the `pending-tasks-nudge.py` README convention.
- `scripts/doc-update-config.sh` — shared config loader sourced by the hook. Uses `jq has()` (not `// empty` which silently swallows the literal `false` value).

### Fixed
- `_merge_config` JSON loading: switched from `jq -r '.field // empty'` to `jq -r 'if has("field") then .field else empty end'` — the `//` operator falls through on falsy values (`false`, `null`, `0`, `""`), making `{"enabled": false}` config get silently ignored. The `has()` form correctly distinguishes "field absent" from "field is false".
- Hook BLOCK output: built reason string entirely inside `jq` filter using `\n` escapes instead of passing multi-line shell variable via `--arg`. Resulting JSON now has properly-escaped `\n` (RFC 8259 compliant) instead of literal control characters.
- Hook git diff: added `--root` flag to `git diff-tree --no-commit-id --name-only -r HEAD` — without it, root commits (no parent) return empty file list, silently passing all checks even when files were committed.

## [0.1.1] - 2026-05-02

### Changed
- `changelog-validate`: Relaxed the "description must start with `vX.Y.Z:`" check to "description must mention `vX.Y.Z` somewhere in first 400 chars" — PsychQuant convention leads descriptions with product tagline, not version prefix. Drift count drops from ~30 plugins to 0 with this change.
- `changelog-validate`: Version header parser now accepts placeholder dates like `(date unknown — please fill in)` so init-output entries are still parsed; ISO-format check happens separately and reports placeholder as a violation user can fix later.
- `changelog-init normalize`: Now also remaps common non-KAC section names (`### Changes` → `### Changed`, `### Migration` → `### Changed`, `### Bug Fixes` → `### Fixed`, etc.) and injects KAC preamble if missing. Three idempotent transforms in one pass: bracket headers + section remap + preamble.

### Fixed
- `issue-driven-dev` CHANGELOG.md hand-fixed two custom subsection names that don't auto-remap (`### 上下游責任分工` and `### Thesis` → `### Changed` with `<!-- (formerly: ...) -->` comment markers preserving original intent).

## [0.1.0] - 2026-05-02

### Added
- `changelog-validate` skill — KAC 1.1.0 compliance check + 3-way sync drift detection between `CHANGELOG.md` latest entry, `plugin.json` description, and `marketplace.json` description. Exit codes 0/1/2/3/4 for CI.
- `changelog-init` skill — bootstrap `CHANGELOG.md` for one plugin from `plugin.json` description. Two modes: `init` (parse `vX.Y.Z` segments → KAC entries) and `normalize` (rewrite non-KAC headers like em-dash format to KAC strict).
- `changelog-migrate` skill — batch run `changelog-init` across an entire marketplace, producing a markdown migration report at `<marketplace>/.claude-plugin/migration-report-YYYY-MM-DD.md`.
- `scripts/validate-changelog.py` — KAC parser + 3-way sync checker (Python 3, no external deps).
- `scripts/init-changelog.py` — description segment parser with major-version filtering (excludes dep-version mid-text noise) and `git log -S` pickaxe date resolution.
- `scripts/migrate-marketplace.py` — batch orchestrator that calls `init-changelog.py` per plugin and aggregates results into a markdown report.
- KAC 1.1.0 spec enforcement: six allowed section types (Added / Changed / Deprecated / Removed / Fixed / Security); strict version header format `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`; preamble must reference Keep a Changelog.

### Changed
- PsychQuant marketplace migration: 33 plugins gained `CHANGELOG.md` files via `changelog-migrate` first run (only `issue-driven-dev` already had one). `che-word-mcp` extracted 15 historical version segments with all dates resolved via `git log` pickaxe; other plugins extracted 1 segment (current version) since their descriptions only describe the latest release.
