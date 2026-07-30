#!/bin/bash
# Stop hook: 偵測 changelog 有更新但 GitHub Wiki 尚未同步時 block
#
# 判定方式：
#   - 今天的 commits 有新增/修改 changelog 目錄下的檔案
#   - .wiki-last-sync marker 不存在或不是今天
#   - repo 有可辨識的 GitHub origin，且該 repo 確實開啟了 wiki
#
# 判準來自 config（見 scripts/doc-update-config.sh）：
#   wiki_sync.enabled        是否啟用（預設 true）
#   wiki_sync.changelog_dir  changelog 目錄名（預設 "changelog/"）
#
# 防止無限迴圈：stop_hook_active=true 時直接放行。
#
# 保守設計（沿襲 1.0.1 / 1.0.2 的兩次修正）：
#   - wiki URL 從當前 repo 的 origin 推導，不硬編碼任何專案的 wiki
#   - repo 未開 wiki（private repo + free org 常見）→ 放行，不製造死巷
#   - gh 不可用／查詢失敗回空字串 ≠ "false" → 保守維持 block

set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck source=../scripts/doc-update-config.sh
source "$PLUGIN_ROOT/scripts/doc-update-config.sh"

is_doc_guardian_disabled && exit 0

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" || exit 0

load_doc_guardian_config "$PROJECT_DIR"

[ "$CFG_ENABLED" = "true" ] || exit 0
[ "$CFG_WIKI_SYNC_ENABLED" = "true" ] || exit 0
is_skipped_path "$PROJECT_DIR" && exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 今天是否有 changelog 變動
CHANGELOG_TODAY=$(git log --since="midnight" --name-only --pretty=format:"" 2>/dev/null \
  | sort -u | grep -E "$CFG_CHANGELOG_DIR_REGEX" || true)
[ -n "$CHANGELOG_TODAY" ] || exit 0

MARKER="$PROJECT_DIR/.wiki-last-sync"
if [ -f "$MARKER" ]; then
  MARKER_DATE=$(date -r "$MARKER" +%Y-%m-%d 2>/dev/null)
  [ "$MARKER_DATE" = "$(date +%Y-%m-%d)" ] && exit 0
fi

# Wiki URL 從當前 repo 的 origin 推導
ORIGIN=$(git remote get-url origin 2>/dev/null | sed -E 's#(\.git)?$##; s#.*[:/]([^/]+/[^/]+)$#\1#')
if [ -z "$ORIGIN" ] || ! echo "$ORIGIN" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  exit 0   # 沒有可辨識的 GitHub origin → 沒有對應 wiki 可同步
fi

# Wiki 功能未開啟 → 結構上沒有 wiki 可同步，放行不擋。
# gh 不可用／rate limit 時回空字串 ≠ "false" → 保守維持 block。
HAS_WIKI=$(gh api "repos/$ORIGIN" --jq .has_wiki 2>/dev/null)
[ "$HAS_WIKI" = "false" ] && exit 0

REPO_NAME="${ORIGIN##*/}"
NEW_FILES=$(echo "$CHANGELOG_TODAY" | tr '\n' ', ' | sed 's/,$//')

jq -n --arg files "$NEW_FILES" --arg origin "$ORIGIN" --arg repo "$REPO_NAME" \
  '{
    decision: "block",
    reason: (
      "Wiki 尚未同步！今天更新了 changelog：" + $files +
      "\n\n請將 changelog 同步到 GitHub Wiki（攤平模式）：" +
      "\n1. git clone https://github.com/" + $origin + ".wiki.git /tmp/" + $repo + "-wiki" +
      "\n   （若 clone 回 Repository not found = wiki 尚未初始化，先到 https://github.com/" + $origin + "/wiki 建第一頁再 clone）" +
      "\n2. 將新的 changelog 複製為獨立 wiki 頁面（檔名 _ 換 -）" +
      "\n3. 重新生成 Changelog.md：把所有 changelog 檔案依日期倒序串接（用 --- 分隔），不要只放連結" +
      "\n4. 更新 _Sidebar.md 加入新頁面連結" +
      "\n5. git add + commit + push" +
      "\n6. touch .wiki-last-sync 標記完成" +
      "\n\n完成後我會自動放行。" +
      "\n\nDisable hint: .claude/doc-guardian.json → {\"wiki_sync\": {\"enabled\": false}}"
    )
  }'
