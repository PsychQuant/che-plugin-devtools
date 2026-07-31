#!/bin/bash
# check-skill-references.sh — 找出文件裡指向不存在 skill 的引用。
#
# Usage:
#   check-skill-references.sh [--repo <dir>] [--format table|tsv]
#
# Exit codes:
#   0  所有引用都解析得到
#   1  有失效引用
#   2  路徑錯誤
#
# WHY THIS EXISTS
#   Plugin 改名的成本不在改名本身，在引用的長尾。這個 repo 踩過兩次：
#
#     changelog-tools → doc-tools → doc-guardian
#     plugin-tools / mcp-tools / cli-tools → devtools → harness-devtools
#
#   第二次改名時掃的是「當前名字」(devtools)，所以 21 處寫著更早的
#   `/changelog-tools:`（此處刻意保留舊名以說明問題）的引用**搜不到、
#   也就沒人知道它們存在**，一路存活到
#   兩代之後。使用者照文件打指令會直接找不到 skill，而沒有任何機制會報錯 ——
#   skill 引用不像 import，不存在時是靜默的。
#
#   兩類檢查：
#     A. `/<plugin>:<skill>` 指向的 SKILL.md 必須真的在
#     B. 已退役的 plugin 前綴不該再出現
#
# 刻意的例外（不需 allowlist 檔，規則自解釋）：
#   同一行出現 `Phase 2` / `尚未實作` / `not implemented` / `刻意保留`
#   / `舊的` / `合併前` 者視為前瞻或歷史引用，跳過。CHANGELOG.md 整份跳過 ——
#   那裡的舊名是「當時的事實」，改掉等於竄改歷史。

set -u

RETIRED_PREFIXES="changelog-tools doc-tools plugin-tools mcp-tools cli-tools devtools"
INTENTIONAL_RE='Phase 2|尚未實作|not implemented|刻意保留|舊的|合併前|formerly'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd || echo "")"
FORMAT="table"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO_ROOT="$2"; shift 2 ;;
    --format)  FORMAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/plugins" ] || {
  echo "✗ no plugins/ under: ${REPO_ROOT:-<empty>}" >&2; exit 2; }

# 一律經此列舉待掃檔案。三類排除：
#   CHANGELOG.md  舊名在那裡是「當時的事實」
#   .git/         非內容
#   test-* / test_*  測試檔裡的舊前綴是 **fixture（資料）**，不是叫誰去執行的
#                 引用。而且無法用豁免字樣解決 —— 驗證「沒有豁免字樣時會被抓」
#                 的那個 case，本體就必須是一個不帶豁免字樣的壞引用。
scan_files() {
  find "$REPO_ROOT/plugins" -type f \( -name "*.md" -o -name "*.sh" -o -name "*.py" \) \
    ! -name "CHANGELOG.md" ! -path "*/.git/*" \
    ! -name "test-*" ! -name "test_*"
}

FINDINGS=$(
  scan_files | while IFS= read -r f; do
    rel="${f#"$REPO_ROOT"/}"

    # --- A. /<plugin>:<skill> 必須存在 --------------------------------------
    grep -nE '/[a-z][a-z0-9-]*:[a-z][a-z0-9-]*' "$f" 2>/dev/null | while IFS= read -r hit; do
      lineno="${hit%%:*}"
      text="${hit#*:}"
      echo "$text" | grep -qE "$INTENTIONAL_RE" && continue

      echo "$text" | grep -oE '/[a-z][a-z0-9-]*:[a-z][a-z0-9-]*' | while IFS= read -r ref; do
        plug="${ref#/}"; plug="${plug%%:*}"
        skill="${ref##*:}"
        # 只驗本 repo 有的 plugin；外部 plugin (superpowers 等) 無從驗證
        [ -d "$REPO_ROOT/plugins/$plug" ] || continue
        [ -f "$REPO_ROOT/plugins/$plug/skills/$skill/SKILL.md" ] && continue
        printf 'missing-skill\t%s\t%s\t%s\n' "$rel" "$lineno" "$ref"
      done
    done

    # --- B. 已退役的前綴不該再出現 -------------------------------------------
    for old in $RETIRED_PREFIXES; do
      grep -nE "/${old}:" "$f" 2>/dev/null | while IFS= read -r hit; do
        lineno="${hit%%:*}"
        text="${hit#*:}"
        echo "$text" | grep -qE "$INTENTIONAL_RE" && continue
        printf 'retired-prefix\t%s\t%s\t%s\n' "$rel" "$lineno" "/${old}:"
      done
    done
  done | sort -u
)

COUNT=$( [ -n "$FINDINGS" ] && printf '%s\n' "$FINDINGS" | wc -l | tr -d ' ' || echo 0 )

if [ "$FORMAT" = "tsv" ]; then
  printf 'kind\tfile\tline\tref\n'
  [ -n "$FINDINGS" ] && printf '%s\n' "$FINDINGS"
else
  if [ "$COUNT" -eq 0 ]; then
    echo "✓ 所有 skill 引用都解析得到，且無退役前綴殘留"
  else
    printf '%-15s %-52s %6s  %s\n' kind file line ref
    printf '%-15s %-52s %6s  %s\n' --------------- ---------------------------------------------------- ------ ---
    printf '%s\n' "$FINDINGS" | while IFS=$'\t' read -r k f l r; do
      printf '%-15s %-52s %6s  %s\n' "$k" "$f" "$l" "$r"
    done
    echo
    echo "$COUNT 個失效引用。"
    echo "  missing-skill  — 指向的 SKILL.md 不存在（多半是改名後沒跟上）"
    echo "  retired-prefix — 用了已退役的 plugin 前綴"
    echo "刻意的前瞻/歷史引用請在同一行寫明 Phase 2 / 尚未實作 / 刻意保留 等字樣。"
  fi
fi

[ "$COUNT" -eq 0 ] || exit 1
exit 0
