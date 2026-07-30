#!/bin/bash
# PostToolUse hook: git commit 後檢查 CLAUDE.md 是否需要更新
#
# 觸發條件：Bash tool 執行了 git commit
# 檢查邏輯：
#   - HEAD commit 修改了哪些檔案
#   - 有「架構/設定/部署」等重要變更，但 CLAUDE.md 沒被更新 → block 並提醒
#
# 判準全部來自 config（見 scripts/doc-update-config.sh）：
#   claude_md.enabled        是否啟用（預設 true）
#   claude_md.min_files      幾個重要檔案才算「值得提醒」（預設 2）
#   claude_md.arch_patterns  什麼算「架構變更」（預設沿用 doc-guardian 1.0.2 的清單）
#
# ---------------------------------------------------------------------------
# 一處刻意的行為差異（相對 doc-guardian 1.0.2）
# ---------------------------------------------------------------------------
# 舊版把判準拆成三次獨立 grep -c 再相加：
#   IMPORTANT(設定/部署檔) + NEW_COMPONENTS(^web/...) + NEW_R_PKG(^r_pkg/)
# 同時符合兩組的檔案（例如 web/app/package.json）會被計數兩次，等於偷偷降低門檻。
# 新版合併成單一 regex 後一個檔案只算一次 —— 語意上更正確，代價是這類邊界案例
# 會比舊版稍微不容易觸發。這是刻意的，不是搬家疏漏。

set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck source=../scripts/doc-update-config.sh
source "$PLUGIN_ROOT/scripts/doc-update-config.sh"

is_doc_guardian_disabled && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# 只在 Bash tool 執行 git commit 時觸發
[ "$TOOL_NAME" = "Bash" ] || exit 0
echo "$TOOL_INPUT" | grep -q 'git commit' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" || exit 0

load_doc_guardian_config "$PROJECT_DIR"

[ "$CFG_ENABLED" = "true" ] || exit 0
[ "$CFG_CLAUDE_MD_ENABLED" = "true" ] || exit 0
is_skipped_path "$PROJECT_DIR" && exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --root 讓 root commit 回傳它的全部檔案而非空值
CHANGED=$(git diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null)
[ -n "$CHANGED" ] || exit 0

# CLAUDE.md 已在本次 commit 更新 → 不需提醒
echo "$CHANGED" | grep -q 'CLAUDE\.md' && exit 0

ARCH_COUNT=$(echo "$CHANGED" | grep -cE "$CFG_ARCH_PATTERNS_REGEX" || true)
[ "$ARCH_COUNT" -ge "$CFG_CLAUDE_MD_MIN_FILES" ] || exit 0

ARCH_FILES=$(echo "$CHANGED" | grep -E "$CFG_ARCH_PATTERNS_REGEX" | head -10)

jq -n \
  --arg files "$ARCH_FILES" \
  --argjson count "$ARCH_COUNT" \
  --argjson threshold "$CFG_CLAUDE_MD_MIN_FILES" \
  '{
    decision: "block",
    reason: (
      "本次 commit 有 \($count) 個架構／設定變更（threshold=\($threshold)）但沒有更新 CLAUDE.md：\n" +
      $files +
      "\n\n請確認 CLAUDE.md 是否需要反映這些變更。如已確認不需要，直接繼續即可。" +
      "\n\nDisable hint: touch ~/.cache/doc-guardian/disabled" +
      "\nOr per-project: .claude/doc-guardian.json → {\"claude_md\": {\"enabled\": false}}"
    )
  }'
