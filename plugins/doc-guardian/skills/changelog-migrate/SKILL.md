---
name: changelog-migrate
description: |
  跨整個 Claude Code marketplace 批次跑 changelog-init — 為所有缺 CHANGELOG.md 的 plugin 補上 KAC 1.1.0 格式的檔案，並產出 migration report。
  Use when: 你的 marketplace 有大量 plugin 沒 CHANGELOG.md（PsychQuant 起初 35/36）；想一次性整頓 changelog 健康度；想看哪些 plugin 的 description 結構好/差（segment 數可作為品質代理指標）。
  防止的失敗：手動為 N 個 plugin 跑 init 太費時；漏了某些 plugin；migration 結果沒留 audit trail。
argument-hint: "<marketplace-path> [--force] [--dry-run] [--only name1,name2] [--exclude name1,name2] [--report-out PATH]"
allowed-tools:
  - Bash(python3:*)
  - Bash(realpath:*)
  - Bash(ls:*)
  - Read
  - AskUserQuestion
---

# /changelog-migrate — Batch CHANGELOG.md initialization

## Purpose

把 [`scripts/migrate-marketplace.py`](../../scripts/migrate-marketplace.py) 包裝成 skill 入口。Script orchestrates per-plugin invocations of `init-changelog.py`，生成 markdown migration report。

## Workflow philosophy

這是**一次性 migration tool**。理想狀態下每個 marketplace 跑一次就完成。後續新增 plugin 用 `changelog-tools:changelog-init` 處理單一 plugin。

## Argument

- `marketplace_path` （必填）— marketplace repo 根目錄（含 `plugins/` 子目錄）
- `--force` — 對既有 CHANGELOG.md 的 plugin 也跑 init（覆寫）。預設 skip
- `--dry-run` — 不寫檔，只印 preview 跟 report
- `--only name1,name2,...` — 只處理列表中的 plugin
- `--exclude name1,name2,...` — 跳過列表中的 plugin
- `--report-out PATH` — report 輸出位置（預設 `<marketplace>/.claude-plugin/migration-report-YYYY-MM-DD.md`）

## Execution

### Step 0: Bootstrap Stage Task List

```
TaskCreate(name="resolve_marketplace", description="realpath + 確認有 plugins/ 子目錄")
TaskCreate(name="dry_run_first", description="先跑 --dry-run 顯示會處理哪些 plugin、預估 segment 數")
TaskCreate(name="ask_confirm", description="AskUserQuestion 確認要實際執行 / 調整 --only --exclude / 中止")
TaskCreate(name="execute_batch", description="跑 migrate 不帶 --dry-run，記錄 report 路徑")
TaskCreate(name="post_process", description="提示 user 開 report 看哪些 plugin 需手動 review section categorization")
```

### Step 1: Dry-run preview

```bash
python3 "$CLAUDE_PLUGIN_ROOT/scripts/migrate-marketplace.py" "$MARKETPLACE" --dry-run
```

Stderr 印 plugin-by-plugin 處理狀態 + 完整 report；stdout 印 JSON summary（total / init_ok / skipped / failed）。

### Step 2: Confirm

用 AskUserQuestion：

```
question: "Dry-run 顯示 N plugin 待 init、M 已存在 CHANGELOG.md（將跳過）、K 失敗。要實際寫檔嗎？"
options:
  - "全部寫入" — 跑 migrate 不帶 --dry-run
  - "排除某些 plugin" — 用 --exclude 重跑
  - "只處理某些 plugin" — 用 --only 重跑
  - "強制覆寫已存在的 CHANGELOG.md" — 加 --force 重跑（包含 dry-run 確認）
  - "中止" — 不執行
```

### Step 3: Execute

```bash
python3 "$CLAUDE_PLUGIN_ROOT/scripts/migrate-marketplace.py" "$MARKETPLACE" [其他 flags]
```

執行後：
- 每個 plugin 的 CHANGELOG.md 寫到 `<marketplace>/plugins/<name>/CHANGELOG.md`
- Migration report 寫到 `<marketplace>/.claude-plugin/migration-report-YYYY-MM-DD.md`
- Stdout 一行 JSON summary（CI / 後續腳本可消費）

### Step 4: Post-process

提示 user：

1. **開 migration report** — 看哪些 plugin 已 init / 哪些 segment 數異常少（≤1 表示 description 沒歷史）
2. **跑 changelog-validate** — `for p in plugins/*/; do /changelog-tools:changelog-validate $p; done`（或 batch 模式 — 留給 Phase 2）
3. **手動 review categorization** — script 是 best-effort，section 分類常需要調整
4. **填補 `(date unknown — please fill in)`** — 找不到 git pickaxe match 的版本要手填

## Examples

```bash
# 標準用法：dry-run preview, confirm, write
/changelog-tools:changelog-migrate /Users/che/Developer/psychquant-claude-plugins

# 只 migrate IDD-related plugins
/changelog-tools:changelog-migrate . --only issue-driven-dev,plugin-tools,mcp-tools

# 排除 binary-based plugin（它們的 description 通常很複雜）
/changelog-tools:changelog-migrate . --exclude che-word-mcp,che-pdf-mcp,che-pptx-mcp

# Dry-run only — 不寫檔，看 preview
/changelog-tools:changelog-migrate . --dry-run

# 強制覆寫所有 plugin 的 CHANGELOG.md（包括 issue-driven-dev）
/changelog-tools:changelog-migrate . --force
```

## Migration report 結構

```markdown
# Migration Report — psychquant-claude-plugins

**Date**: 2026-05-02
**Mode**: Applied
**Total plugins scanned**: 36
**CHANGELOG.md created**: 33
**Skipped (already has CHANGELOG.md)**: 1
**Failed**: 0

## Generated CHANGELOG.md

| Plugin | Segments | Dates resolved | Versions |
|--------|----------|----------------|----------|
| `che-word-mcp` | 15 | 15/15 | 3.17.8, 3.17.7, 3.17.6, 3.17.5, 3.17.4... |
| `agent-cacher` | 1 | 0/1 | 0.1.0 |
| ...

## Skipped (existing CHANGELOG.md)
- `issue-driven-dev`

## Failed
(none)

## Manual review needed
{4-point reminder}
```

## 鐵律

- **Idempotent by default** — 第二次跑只會 skip 既有 CHANGELOG.md，不會破壞 manual edits
- **Report 是 audit trail** — 永遠寫 report 到磁碟（除 dry-run），不在 Claude 對話中遺失
- **Best-effort migration** — 結構化 + 省手寫，不替代人類編輯
- **不在 SKILL 裡 inline migration logic** — 全部在 `scripts/migrate-marketplace.py`

## Limitations

- **不跨 marketplace** — 一次只處理一個 marketplace。多個要 loop 呼叫
- **不處理 binary repo CHANGELOG** — 只處理 plugin marketplace 結構（`plugins/<name>/`）；binary repo（如 `mcp/che-word-mcp/` 直接 git clone 的）要單獨用 `changelog-init`
- **Section categorization 仍需 review** — 詳見 [changelog-init Limitations](../changelog-init/SKILL.md#limitations--manual-cleanup-needed)

## Related

- [`scripts/migrate-marketplace.py`](../../scripts/migrate-marketplace.py) — 實作
- [`changelog-init`](../changelog-init/SKILL.md) — 單 plugin 版本
- [`changelog-validate`](../changelog-validate/SKILL.md) — migrate 完用來驗結果
