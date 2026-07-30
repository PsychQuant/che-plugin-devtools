---
name: changelog-validate
description: |
  驗證 plugin 的 CHANGELOG.md 是否符合 Keep a Changelog 1.1.0 規範，並檢查三處同步（CHANGELOG.md latest entry ↔ plugin.json description ↔ marketplace.json description）。
  Exit codes: 0 pass / 1 missing CHANGELOG / 2 KAC violation / 3 sync drift / 4 IO error。CI 友善。
  Use when: 發 release 前檢查格式對不對；audit 一個 marketplace 的 CHANGELOG 健康度；改完 description 後驗 sync 沒漏。
  防止的失敗：plugin.json 跟 CHANGELOG 版本不同步（marketplace 顯示舊版）；用了非 KAC section name（### 改進、### Bug Fix 等）；忘記寫日期。
argument-hint: "<plugin-path> [--marketplace <marketplace-json-path>] [--sync-chars N] [--quiet]"
allowed-tools:
  - Bash(python3:*)
  - Bash(realpath:*)
  - Bash(ls:*)
  - Read
---

# /changelog-validate — 驗證 CHANGELOG

## Purpose

把 [`scripts/validate-changelog.py`](../../scripts/validate-changelog.py) 包裝成 skill 入口。Script 做機械驗證（KAC parse + sync check），skill 負責告訴使用者「下一步該做什麼」。

## Argument

- `plugin_path` （必填）— plugin 目錄絕對路徑（含 `.claude-plugin/plugin.json`）
- `--marketplace <path>` （選）— `marketplace.json` 絕對路徑；省略則跳過 marketplace 那一邊的 sync drift 檢查
- `--sync-chars N` （選，預設 200）— plugin.json 跟 marketplace.json description 比對前 N 字
- `--quiet` （選）— 只輸出 JSON summary（CI 用）

## Execution

### Step 0: Bootstrap Stage Task List

```
TaskCreate(name="resolve_paths", description="解析 plugin_path → 找 CHANGELOG.md / plugin.json / marketplace.json")
TaskCreate(name="run_validator", description="跑 validate-changelog.py，蒐集 exit code + JSON summary + human report")
TaskCreate(name="route_action", description="根據 exit code 給使用者具體下一步指引")
```

### Step 1: Resolve paths

```bash
PLUGIN_PATH=$(realpath "$ARG_PLUGIN_PATH")
[ -d "$PLUGIN_PATH" ] || { echo "ERROR: not a directory: $PLUGIN_PATH"; exit 4; }
[ -f "$PLUGIN_PATH/.claude-plugin/plugin.json" ] || { echo "ERROR: not a plugin (missing .claude-plugin/plugin.json): $PLUGIN_PATH"; exit 4; }

# Optional marketplace
if [ -n "$ARG_MARKETPLACE" ]; then
    MARKETPLACE_FLAG="--marketplace $(realpath "$ARG_MARKETPLACE")"
else
    MARKETPLACE_FLAG=""
fi
```

### Step 2: Run validator

```bash
python3 "$CLAUDE_PLUGIN_ROOT/scripts/validate-changelog.py" \
    "$PLUGIN_PATH" \
    $MARKETPLACE_FLAG \
    --sync-chars ${ARG_SYNC_CHARS:-200} \
    ${QUIET:+--quiet}
EXIT=$?
```

The script writes:
- Human-readable report to **stderr**
- One-line JSON summary to **stdout** (last line)
- Exit code 0/1/2/3/4

Capture both for routing.

### Step 3: Route by exit code

| Exit | Meaning | Recommended next action (tell user) |
|------|---------|------------------------------------|
| 0 | pass | ✓ 沒事。如要 release，跑 `/changelog-tools:changelog-release` (Phase 2) |
| 1 | CHANGELOG.md missing | → 跑 `/changelog-tools:changelog-init <plugin-path>` 從 plugin.json description 反向 bootstrap |
| 2 | KAC violation | → 顯示 violation list；若是 em-dash format（PsychQuant legacy 風格），跑 `/changelog-tools:changelog-init --normalize <plugin-path>`；若是個別 section name 錯誤，手動修 |
| 3 | sync drift | → 顯示 drift list；通常是 plugin.json / marketplace.json description 沒跟 CHANGELOG 最新 entry 同步；下個 release 時 `/changelog-tools:changelog-release` 會自動同步，現在可手動 Edit |
| 4 | IO / CLI error | → 報錯給使用者，通常是路徑寫錯 |

## Engine 模式

預設 verbose（人讀）。`--quiet` 切到 JSON-only 模式給 CI / batch 場景（`changelog-migrate` 內部就用這個）。

## Examples

```bash
# 單一 plugin 驗證（含 marketplace sync）
/changelog-tools:changelog-validate plugins/issue-driven-dev --marketplace .claude-plugin/marketplace.json

# 只驗 CHANGELOG.md 本身（跳過 sync）
/changelog-tools:changelog-validate plugins/changelog-tools

# CI mode（only JSON to stdout）
/changelog-tools:changelog-validate plugins/issue-driven-dev --quiet
```

## 鐵律

- **不在 SKILL 裡 inline parse logic** — 全部在 `scripts/validate-changelog.py`。SKILL 只 orchestrate。
- **Exit code 是契約** — 0/1/2/3/4 對應 5 種狀態，呼叫者（CI、其他 skill）依此 branch
- **Sync drift ≠ KAC violation** — 兩者獨立報、獨立 exit。Drift 不阻擋 KAC pass

## Related

- [`scripts/validate-changelog.py`](../../scripts/validate-changelog.py) — 實作
- [`changelog-init`](../changelog-init/SKILL.md) — exit 1/2 後的修復路徑
- [`changelog-migrate`](../changelog-migrate/SKILL.md) — batch 跨多 plugin 用 `--quiet` mode
- [Keep a Changelog 1.1.0 spec](https://keepachangelog.com/en/1.1.0/)
