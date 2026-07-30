#!/bin/bash
# Stop hook: 偵測最近一筆 commit 有重大程式碼變更但沒更新文件時 block
#
# Migrated from ~/.claude/hooks/changelog-update.sh (che-claude-config) into the
# plugin so any plugin user gets the same documentation-update guard.
#
# doc-guardian 2.0.0: this hook supersedes doc-guardian 1.0.2's changelog-update.sh.
# Both were registered and enabled at once (doc-tools + doc-guardian), so the same
# check fired twice on every Stop. The 1.0.2 script is deliberately not carried over.
#
# 判定方式：
#   - 檢查 HEAD commit 修改的檔案
#   - 預設 ≥3 個程式碼檔案被修改（可由 config 覆寫 min_changed_files）
#   - 但該 commit 沒有更新任一文件（CHANGELOG.md / README.md / CLAUDE.md / changelog/）
#
# Why "per-commit" not "per-day":
#   compact 後 Claude 會忘記先前改了什麼，每筆 commit 都應該獨立檢查。
#
# Why Stop event + decision:block:
#   文件更新是明確可執行動作（不像 task 不確定要標哪個），block 強制 user/Claude
#   處理；不會卡住流程。infinite-loop 由 stop_hook_active=true bypass 防護。
#
# Why ≥3 files threshold:
#   Heuristic — 1-2 file hot-fix 通常不需要 doc 更新；3+ 已是 "significant
#   change" 規模。可由 config min_changed_files 覆寫。
#
# Why these code extensions:
#   User 主要工作的程式語言（R / sh / sql / py / ts / swift / go / rs / etc）。
#   Markdown / JSON / YAML / TXT 不算「code change」（它們可能就是 doc 自己）。
#
# Three-tier config injection (high → low priority):
#   1. <repo>/.claude/doc-guardian.json  ← per-project override
#   2. ~/.cache/doc-guardian/config.json ← per-machine override
#   3. built-in defaults (this script)
#
# One-touch kill switch:
#   touch ~/.cache/doc-guardian/disabled → hook 完全短路 exit 0
#
# 完整 design notes 見 ${CLAUDE_PLUGIN_ROOT}/references/doc-update-design.md

set -u

# Disabled flag — short-circuit before any work (honors both new and legacy paths)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck source=../scripts/doc-update-config.sh
source "$PLUGIN_ROOT/scripts/doc-update-config.sh"
is_doc_guardian_disabled && exit 0

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# Prevent infinite loop: if Claude is already responding to a hook block, let it through
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" || exit 0

load_doc_guardian_config "$PROJECT_DIR"

# Disabled in config → exit 0
if [ "$CFG_ENABLED" != "true" ]; then
  exit 0
fi

# Skipped path → exit 0
if is_skipped_path "$PROJECT_DIR"; then
  exit 0
fi

# Non-git directory → exit 0
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Files changed in HEAD commit (--root makes root commits return all their files instead of empty)
CHANGED=$(git diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null)
if [ -z "$CHANGED" ]; then
  exit 0
fi

# Count significant code changes
SIG_COUNT=$(echo "$CHANGED" | grep -cE "$CFG_CODE_EXTENSIONS_REGEX" || true)

# Below threshold → not a significant change → exit 0
if [ "$SIG_COUNT" -lt "$CFG_MIN_CHANGED_FILES" ]; then
  exit 0
fi

# Any doc file updated → exit 0 (lenient: any one of the four counts)
DOC_UPDATED=$(echo "$CHANGED" | grep -cE "$CFG_DOC_FILES_REGEX" || true)
if [ "$DOC_UPDATED" -gt 0 ]; then
  exit 0
fi

# Block with structured JSON. Build reason entirely inside jq using \n escapes
# so the emitted JSON has properly-escaped newlines (passing the multi-line
# string via --arg leaks literal control characters into the JSON output, which
# is technically invalid per RFC 8259).
jq -n \
  --argjson count "$SIG_COUNT" \
  --argjson threshold "$CFG_MIN_CHANGED_FILES" \
  --arg plugin_root "$PLUGIN_ROOT" \
  '{
    decision: "block",
    reason: (
      "HEAD commit 有 \($count) 個程式檔案變更（threshold=\($threshold)）但沒有更新文件，請補上：" +
      "\n- CHANGELOG.md 或 changelog/ 目錄新增變更記錄" +
      "\n- README.md（如有新功能、API 變更等需反映）" +
      "\n- CLAUDE.md（如有架構變更、新指令等需反映）" +
      "\n\n至少更新其中一項文件後即可繼續。" +
      "\n\nDisable hint: touch ~/.cache/doc-guardian/disabled  (one-touch kill switch)" +
      "\nConfig: see " + $plugin_root + "/references/doc-update-design.md"
    )
  }'
