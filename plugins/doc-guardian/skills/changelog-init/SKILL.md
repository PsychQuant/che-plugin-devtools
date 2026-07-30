---
name: changelog-init
description: |
  為單一 plugin 從 plugin.json description 反向 bootstrap CHANGELOG.md（Keep a Changelog 1.1.0 格式）。
  Parse description 的 vX.Y.Z 段落（同時支援 colon-style `vX.Y.Z:` 和 space-style `vX.Y.Z `），按 plugin 自己的 major version 過濾掉 dep version 噪音，git log pickaxe 解析每個 version 的引入日期，分類 prose 到 Added/Changed/Deprecated/Removed/Fixed/Security 六個 KAC section。
  另一個 mode: normalize 把既有非 KAC CHANGELOG.md（如 PsychQuant 的 em-dash 格式 `## 2.37.0 — 2026-05-02`）改寫成 KAC 標準（`## [2.37.0] - 2026-05-02`）。
  Use when: 你想為一個沒 CHANGELOG.md 的 plugin 補一個；或想把舊格式 normalize 成 KAC 標準。
  防止的失敗：手寫 KAC entries 太繁瑣 → 索性不寫 CHANGELOG.md；或寫了但格式偏差被 marketplace consumer 解析錯。
argument-hint: "<init|normalize> <plugin-path> [--force] [--dry-run]"
allowed-tools:
  - Bash(python3:*)
  - Bash(git:*)
  - Bash(realpath:*)
  - Read
  - Write
---

# /changelog-init — Bootstrap CHANGELOG.md

## Purpose

把 [`scripts/init-changelog.py`](../../scripts/init-changelog.py) 包裝成 skill 入口。Script 做 parse + categorize + render；skill 負責路由 + 互動確認。

## Two modes

### `init` — 從 plugin.json description 產生 CHANGELOG.md

```bash
/changelog-tools:changelog-init init <plugin-path> [--force] [--dry-run]
```

行為：
1. Read `<plugin-path>/.claude-plugin/plugin.json` 的 `description` 欄位
2. 用正則找出 `vX.Y.Z` segments，按 plugin 自己的 major version 過濾（避免把 dep `v0.21.x` 當成 segment）
3. 對每個 segment，跑 `git log -S "vX.Y.Z"` 找最早引入時間 → 當該 version 的日期；找不到就 `(date unknown — please fill in)`
4. 把 prose 用關鍵字 markers（NEW / fixes / BREAKING / deprecated / removed / security）分到六個 KAC section
5. 寫 KAC 1.1.0 格式 + 預載 `[Unreleased]` placeholder
6. 預設**拒絕覆寫**既有 CHANGELOG.md，需 `--force`

`--dry-run` 印出 output 不寫檔，方便 review。

### `normalize` — 修既有非 KAC CHANGELOG.md

```bash
/changelog-tools:changelog-init normalize <plugin-path> [--dry-run]
```

行為：
- 把 `## 2.37.0 — 2026-05-02`（em-dash, 無方括號）改寫成 `## [2.37.0] - 2026-05-02`
- 不動 body content（不重排 section / 不改字）— 只觸版本標題那一行
- Idempotent — 已是 KAC 格式時印 `✓ Already KAC compliant` 後 exit 0

## Execution

### Step 0: Bootstrap Stage Task List

```
TaskCreate(name="resolve_mode", description="parse arg → init or normalize")
TaskCreate(name="resolve_plugin_path", description="realpath + 確認 .claude-plugin/plugin.json 存在")
TaskCreate(name="dry_run_first", description="先跑 --dry-run 給 user 看 preview（init mode 必要、normalize mode 推薦）")
TaskCreate(name="ask_confirm", description="AskUserQuestion 確認要實際寫檔，或想先手動 review preview")
TaskCreate(name="execute", description="跑 init/normalize 不帶 --dry-run")
TaskCreate(name="route_next", description="提示 changelog-validate 驗證輸出 / 提示手動 review categorization")
```

### Step 1: Resolve mode + path

```bash
MODE=$1   # init or normalize
PLUGIN_PATH=$(realpath "$2")
[ -d "$PLUGIN_PATH" ] || { echo "ERROR: not a directory: $PLUGIN_PATH"; exit 4; }
[ -f "$PLUGIN_PATH/.claude-plugin/plugin.json" ] || { echo "ERROR: not a plugin: $PLUGIN_PATH"; exit 4; }
```

### Step 2: Dry-run first (init mode)

Init mode 一定先跑 `--dry-run` 顯示 preview，再用 AskUserQuestion 確認：

```
question: "Preview 顯示了 N 個 segment，要實際寫到 {path}/CHANGELOG.md 嗎？"
options:
  - "寫入" — 跑 init 不帶 --dry-run
  - "再跑一次 dry-run" — 重跑 preview（如 user 中途改了 plugin.json）
  - "手動 review preview" — 把 dry-run 輸出存到 /tmp/CHANGELOG_preview.md，user 自己編輯後 cp 到目的地
  - "中止" — 不寫檔
```

### Step 3: Execute

```bash
python3 "$CLAUDE_PLUGIN_ROOT/scripts/init-changelog.py" "$MODE" "$PLUGIN_PATH" [--force]
```

### Step 4: Route next

| 完成情境 | 下一步 |
|---------|-------|
| init 成功 | → 跑 `/changelog-tools:changelog-validate $PLUGIN_PATH` 驗格式；review section categorization；填補 `(date unknown)` |
| normalize 成功 | → 跑 `/changelog-tools:changelog-validate` 確認 |
| init `EXIT=1`（CHANGELOG 已存在） | → 改用 normalize mode；或加 `--force` overwrite |

## Examples

```bash
# 為 che-word-mcp 補 CHANGELOG.md
/changelog-tools:changelog-init init plugins/che-word-mcp

# Preview only
/changelog-tools:changelog-init init plugins/che-word-mcp --dry-run

# Overwrite existing CHANGELOG.md
/changelog-tools:changelog-init init plugins/che-word-mcp --force

# Normalize issue-driven-dev 的 em-dash format
/changelog-tools:changelog-init normalize plugins/issue-driven-dev
```

## Limitations & manual cleanup needed

Init mode 是 **best-effort migration**，產出後通常需要手動 review：

1. **Section categorization 偏差** — keyword markers 不完美，例如「pre-fix three structural defects: (1) deprecated...」可能被歸 Deprecated，實際應在 Fixed。Section 內的 bullet 順序也只是 sentence split，可能切錯。
2. **Date 缺漏** — `git log -S` pickaxe 只能找 plugin.json 內提到該 version 的 commit；如果 description 沒提到舊版本，就只能 fallback `(date unknown)` 等手填。
3. **Sentence boundary** — 中文句號 `。` 不會被 split，整個 paragraph 變一條 bullet。可後續手動拆。
4. **Cross-references 被 dedupe** — 同一個 version 在 description 多次出現（如 v3.16.2 被前後文 cross-reference）只保留第一個 segment header；其他 mention 的內容會吃進前一個 segment。

工具的價值是**結構化 + 大幅省手寫時間**，不是替代人類編輯。

## 鐵律

- **不在 SKILL 裡 inline parsing logic** — 全部在 `scripts/init-changelog.py`
- **Init 預設不覆寫** — 保護既有 CHANGELOG，需 `--force` 才覆寫
- **Dry-run 是第一等公民** — init mode 必先 dry-run 給 user 看 preview

## Related

- [`scripts/init-changelog.py`](../../scripts/init-changelog.py) — 實作
- [`changelog-validate`](../changelog-validate/SKILL.md) — init 後驗格式
- [`changelog-migrate`](../changelog-migrate/SKILL.md) — batch 跨多 plugin 跑 init
