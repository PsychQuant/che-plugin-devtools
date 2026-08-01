#!/bin/bash
# Tests for resolve-mcp-project.sh
#
# Run: bash plugins/harness-devtools/scripts/test-resolve-mcp-project.sh
# Exit 0 = all pass, 1 = any failure.
#
# Fixtures override HOME so the search roots point at a synthetic tree. That is
# what makes precedence and the Package.swift gate testable without depending on
# whatever happens to be on this machine — and it also pins the contract that the
# roots are HOME-relative rather than absolute.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-mcp-project.sh"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ✗ $desc"
    echo "      expected: '$expected'"
    echo "      actual:   '$actual'"
  fi
}

# Build a synthetic HOME with the three umbrellas.
FAKE="$TMPROOT/home"
mk_project() {  # $1 = umbrella-relative dir, $2 = name
  mkdir -p "$FAKE/$1/$2"
  echo "// swift-tools-version:5.9" > "$FAKE/$1/$2/Package.swift"
}
mkdir -p "$FAKE/Developer/che-mcps" "$FAKE/Developer/che-msg"
mk_project Developer/che-mcps       che-ical-mcp
mk_project Developer/che-mcps       che-word-mcp
mk_project Developer/che-msg        che-telegram-all-mcp
mk_project Developer                iss-compute-mcp
# Decoys: no Package.swift → must not resolve
mkdir -p "$FAKE/Developer/che-mcps/archived"
mkdir -p "$FAKE/Developer/some-unrelated-mcp"
# 一般目錄下不以 -mcp 結尾的 Swift package —— 不該被當成 MCP 專案
mk_project Developer                macdoc
# 非 Swift 的 MCP（iss-compute-mcp 就是這種：requirements.txt，無 pyproject.toml）
mkdir -p "$FAKE/Developer/che-mcps/python-thing-mcp"
echo "mcp" > "$FAKE/Developer/che-mcps/python-thing-mcp/requirements.txt"
# Shadowed name: exists in both che-mcps and the bare Developer root
mk_project Developer/che-mcps       dup-mcp
mk_project Developer                dup-mcp
# 專屬 umbrella 下不以 -mcp 結尾的共用 library —— 該被收（mode=any）
mk_project Developer/che-mcps       shared-lib-swift

run() { HOME="$FAKE" bash -c "source '$RESOLVER'; $1" 2>/dev/null; }

echo "resolution:"
assert_eq "che-mcps 底下的專案" \
  "$FAKE/Developer/che-mcps/che-ical-mcp" "$(run 'resolve_mcp_project che-ical-mcp')"
assert_eq "che-msg 底下的專案（第二個 umbrella）" \
  "$FAKE/Developer/che-msg/che-telegram-all-mcp" "$(run 'resolve_mcp_project che-telegram-all-mcp')"
assert_eq "Developer 根底下的獨立專案" \
  "$FAKE/Developer/iss-compute-mcp" "$(run 'resolve_mcp_project iss-compute-mcp')"
assert_eq "不存在的名字 → 空輸出" "" "$(run 'resolve_mcp_project no-such-mcp')"
assert_eq "不存在的名字 → 非零 exit" "1" \
  "$(HOME="$FAKE" bash -c "source '$RESOLVER'; resolve_mcp_project no-such-mcp" >/dev/null 2>&1; echo $?)"
assert_eq "空參數 → 非零 exit" "1" \
  "$(HOME="$FAKE" bash -c "source '$RESOLVER'; resolve_mcp_project" >/dev/null 2>&1; echo $?)"

echo
echo "Package.swift gate（沒有它就不是專案）:"
assert_eq "archived/ 不算專案" "" "$(run 'resolve_mcp_project archived')"
assert_eq "無 Package.swift 的 *-mcp 目錄不算專案" "" \
  "$(run 'resolve_mcp_project some-unrelated-mcp')"

echo
echo "mcp-suffix gate（一般目錄只收 *-mcp）:"
assert_eq "Developer 根下的 macdoc 不算 MCP 專案" "" "$(run 'resolve_mcp_project macdoc')"
assert_eq "  但 -mcp 結尾的仍解析得到" \
  "$FAKE/Developer/iss-compute-mcp" "$(run 'resolve_mcp_project iss-compute-mcp')"
assert_eq "  list 不含 macdoc" "0" "$(run 'list_mcp_projects' | grep -c '^macdoc$')"
assert_eq "  專屬 umbrella 不受後綴限制（共用 library 也收）" \
  "$FAKE/Developer/che-mcps/shared-lib-swift" "$(run 'resolve_mcp_project shared-lib-swift')"

echo
echo "多語言 gate（不是每個 MCP 都是 Swift）:"
assert_eq "只有 requirements.txt 的 Python MCP 也解析得到" \
  "$FAKE/Developer/che-mcps/python-thing-mcp" "$(run 'resolve_mcp_project python-thing-mcp')"

echo
echo "precedence（第一個 root 勝出）:"
assert_eq "同名時取 che-mcps 而非 Developer 根" \
  "$FAKE/Developer/che-mcps/dup-mcp" "$(run 'resolve_mcp_project dup-mcp')"
assert_eq "list_mcp_projects 對同名只列一次" "1" \
  "$(run 'list_mcp_projects' | grep -c '^dup-mcp$')"

# #11：che-msg 必須排在 che-mcps 之前。原順序讓 resolver 確定地指向
# 四個月前的 stale clone —— 確定不等於正確。
mk_project Developer/che-msg        shadowed-mcp
mk_project Developer/che-mcps       shadowed-mcp
assert_eq "che-msg 優先於 che-mcps（#11 stale-clone 修正）" \
  "$FAKE/Developer/che-msg/shadowed-mcp" "$(run 'resolve_mcp_project shadowed-mcp')"

echo
echo "shadowing 必須可見（#11 — 靜默取勝者正是本 issue 的根因）:"
SHADOW_ERR=$(HOME="$FAKE" bash -c "source '$RESOLVER'; resolve_mcp_project shadowed-mcp" 2>&1 >/dev/null)
case "$SHADOW_ERR" in
  *"同時存在於多個 umbrella"*) PASS=$((PASS+1)); echo "  ✓ 遮蔽時往 stderr 警告" ;;
  *) FAIL=$((FAIL+1)); echo "  ✗ 遮蔽時往 stderr 警告" ;;
esac
case "$SHADOW_ERR" in
  *che-mcps/shadowed-mcp*) PASS=$((PASS+1)); echo "  ✓ 警告列出被遮蔽的那份" ;;
  *) FAIL=$((FAIL+1)); echo "  ✗ 警告列出被遮蔽的那份" ;;
esac
assert_eq "  警告不污染 stdout（呼叫端 cd \$(...) 仍安全）" \
  "$FAKE/Developer/che-msg/shadowed-mcp" "$(run 'resolve_mcp_project shadowed-mcp')"
NOSHADOW_ERR=$(HOME="$FAKE" bash -c "source '$RESOLVER'; resolve_mcp_project che-ical-mcp" 2>&1 >/dev/null)
assert_eq "  無遮蔽時 stderr 全空（不製造雜訊）" "" "$NOSHADOW_ERR"
assert_eq "  mcp_project_candidates 列出全部候選" "2" \
  "$(run 'mcp_project_candidates shadowed-mcp' | wc -l | tr -d ' ')"

echo
echo "listing:"
assert_eq "list_mcp_roots 只列出實際存在的" "3" "$(run 'list_mcp_roots' | wc -l | tr -d ' ')"
assert_eq "list_mcp_projects 列出全部 8 個" "8" "$(run 'list_mcp_projects' | wc -l | tr -d ' ')"

MISSING_ROOT="$TMPROOT/empty-home"
mkdir -p "$MISSING_ROOT"
assert_eq "roots 都不存在時 list_mcp_roots 空且 exit 0" "0" \
  "$(HOME="$MISSING_ROOT" bash -c "source '$RESOLVER'; list_mcp_roots" >/dev/null 2>&1; echo $?)"

echo
echo "require_mcp_project 的錯誤訊息:"
ERR=$(HOME="$FAKE" bash -c "source '$RESOLVER'; require_mcp_project ghost-mcp" 2>&1 >/dev/null)
case "$ERR" in
  *"找不到 MCP 專案"*) PASS=$((PASS+1)); echo "  ✓ 說明找不到什麼" ;;
  *) FAIL=$((FAIL+1)); echo "  ✗ 說明找不到什麼" ;;
esac
case "$ERR" in
  *che-mcps*) PASS=$((PASS+1)); echo "  ✓ 列出搜尋過的位置" ;;
  *) FAIL=$((FAIL+1)); echo "  ✗ 列出搜尋過的位置" ;;
esac
case "$ERR" in
  *che-ical-mcp*) PASS=$((PASS+1)); echo "  ✓ 列出可用的專案" ;;
  *) FAIL=$((FAIL+1)); echo "  ✗ 列出可用的專案" ;;
esac
assert_eq "找得到時輸出路徑且 exit 0" \
  "$FAKE/Developer/che-mcps/che-word-mcp" "$(run 'require_mcp_project che-word-mcp')"

echo
echo "bash 3.2 相容（macOS /bin/bash 是 3.2.57）:"
OUT_F="$TMPROOT/o.txt"; ERR_F="$TMPROOT/e.txt"
HOME="$FAKE" /bin/bash -c "source '$RESOLVER'; resolve_mcp_project che-ical-mcp; list_mcp_projects; list_mcp_roots" \
  > "$OUT_F" 2> "$ERR_F"
assert_eq "  /bin/bash 下 stderr 全空（無 nameref / declare -A 錯誤）" "" "$(cat "$ERR_F")"
assert_eq "  /bin/bash 下仍解析得到" \
  "$FAKE/Developer/che-mcps/che-ical-mcp" "$(head -1 "$OUT_F")"

echo
echo "against this machine (真實環境 smoke test — 不斷言具體數量):"
REAL=$(bash -c "source '$RESOLVER'; list_mcp_projects" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REAL" -gt 0 ]; then
  PASS=$((PASS+1)); echo "  ✓ 本機解析到 $REAL 個 MCP 專案"
else
  # 不算 FAIL：別台機器可能沒有這些 umbrella。
  echo "  (skipped — 本機沒有任何 MCP umbrella)"
fi

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
