#!/bin/bash
# Tests for validate-skill-input.sh
#
# Run: bash plugins/harness-devtools/scripts/test-validate-skill-input.sh
#
# 輸入一律以 printf 寫進檔案，內容從不經過 shell 解析 —— 這正是 skill-create 用 Write 工具傳值的做法。
# 惡意樣本都是前幾輪 verify 實際讓舊設計失守的輸入。

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$SCRIPT_DIR/validate-skill-input.sh"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CANARY="$T/CANARY"

ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
accept() { # desc mode file [namefile] expected-output
  local out rc; out=$(bash "$V" "$2" "$3" ${4:+"$4"} 2>/dev/null); rc=$?
  [ $rc -eq 0 ] && [ "$out" = "$5" ] && ok "$1" || bad "$1" "rc=$rc out=[$out] expected=[$5]"; }
reject() { # desc mode file [namefile]
  local rc; bash "$V" "$2" "$3" ${4:+"$4"} >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && ok "$1" || bad "$1" "rc=$rc（預期 1：驗證拒絕）"; }

echo "name:"
printf '%s' 'plaud-to-srt' > "$T/n"; accept "合法名字" name "$T/n" "" "plaud-to-srt"
printf '%s\n' 'plaud-to-srt' > "$T/n"; accept "結尾換行被容許並去掉" name "$T/n" "" "plaud-to-srt"
printf '%s' "x"$'\n'"NAME_EOF"$'\n'"touch $CANARY"$'\n'"NAME_EOF" > "$T/n"; reject "含結束標記與 touch 的名字" name "$T/n"; [ ! -e "$CANARY" ] && ok "且沒有執行任何指令" || bad "指令被執行了"
printf '%s' "a'; touch $CANARY; echo '" > "$T/n"; reject "含單引號的名字" name "$T/n"; [ ! -e "$CANARY" ] && ok "且沒有執行任何指令" || bad "指令被執行了"
printf '%s' 'Bad_Name' > "$T/n"; reject "大寫與底線" name "$T/n"
printf '%s' '-lead' > "$T/n"; reject "連字號開頭" name "$T/n"
printf '%s' '../x' > "$T/n"; reject "路徑穿越" name "$T/n"
printf '%s' 'a b' > "$T/n"; reject "含空白" name "$T/n"
printf '' > "$T/n"; reject "空檔案" name "$T/n"
reject "檔案不存在" name "$T/__nope__"
printf 'ab\0cd' > "$T/n"; reject "含 NUL" name "$T/n"
printf '%s' "$(printf 'a%.0s' $(seq 1 65))" > "$T/n"; reject "超過 64 字元" name "$T/n"

echo "target:"
printf '%s' 'plaud-to-srt' > "$T/name"
printf '%s' "$T/newdir/plaud-to-srt" > "$T/t"; accept "合法目標" target "$T/t" "$T/name" "$T/newdir/plaud-to-srt"
printf '%s' "$T/Che's skills/plaud-to-srt" > "$T/t"; accept "路徑含單引號是合法的（不進 shell 原始碼）" target "$T/t" "$T/name" "$T/Che's skills/plaud-to-srt"
printf '%s' "rel/plaud-to-srt" > "$T/t"; reject "相對路徑" target "$T/t" "$T/name"
printf '%s' "$T/a/../plaud-to-srt" > "$T/t"; reject "含 .. 成分" target "$T/t" "$T/name"
printf '%s' "$T/./plaud-to-srt" > "$T/t"; reject "含 . 成分" target "$T/t" "$T/name"
printf '%s' "$T/x"$'\n'"TARGET_EOF"$'\n'"touch $CANARY"$'\n'"/plaud-to-srt" > "$T/t"; reject "含換行與結束標記的路徑" target "$T/t" "$T/name"; [ ! -e "$CANARY" ] && ok "且沒有執行任何指令" || bad "指令被執行了"
printf '%s' "$T/other" > "$T/t"; reject "目錄名不等於名字" target "$T/t" "$T/name"
mkdir -p "$T/exists/plaud-to-srt"; printf '%s' "$T/exists/plaud-to-srt" > "$T/t"; reject "目標已存在" target "$T/t" "$T/name"
ln -s /nonexistent "$T/dangling-plaud-to-srt"; printf '%s' 'dangling-plaud-to-srt' > "$T/name2"; printf '%s' "$T/dangling-plaud-to-srt" > "$T/t"; reject "懸空 symlink 也算已存在" target "$T/t" "$T/name2"
printf '' > "$T/t"; reject "目標檔為空" target "$T/t" "$T/name"
printf '%s' "$T/newdir/plaud-to-srt" > "$T/t"; printf 'Bad_Name' > "$T/name3"; reject "名字檔本身不合法時，目標驗證也失敗" target "$T/t" "$T/name3"
reject "沒給名字檔" target "$T/t"

echo "mode:"
reject "未知模式" bogus "$T/n"

echo ""; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
