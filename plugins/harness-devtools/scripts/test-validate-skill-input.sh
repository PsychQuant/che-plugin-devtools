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
  [ $rc -eq 1 ] && ok "$1" || bad "$1" "rc=${rc}（預期 1：驗證拒絕）"; }

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
printf '%s' "$T/Che skills/plaud-to-srt" > "$T/t"; accept "路徑含空白是合法的" target "$T/t" "$T/name" "$T/Che skills/plaud-to-srt"
printf '%s' "$T/標楷 資料/plaud-to-srt" > "$T/t"; accept "路徑含中文是合法的" target "$T/t" "$T/name" "$T/標楷 資料/plaud-to-srt"
for BAD in "Che's skills" 'a$(id)b' 'a`id`b' 'a;b' 'a|b' 'a&b' 'a"b' 'a\\b' 'a<b' 'a>b' 'a(b' 'a)b' 'a{b' 'a*b' 'a?b' 'a!b' 'a[b' 'a#b' 'a~b'; do
  printf '%s' "$T/$BAD/plaud-to-srt" > "$T/t"; reject "路徑含 shell 元字元被拒絕：$BAD" target "$T/t" "$T/name"
done
printf '%s' "rel/plaud-to-srt" > "$T/t"; reject "相對路徑" target "$T/t" "$T/name"
printf '%s' "$T/a/../plaud-to-srt" > "$T/t"; reject "含 .. 成分" target "$T/t" "$T/name"
printf '%s' "$T/./plaud-to-srt" > "$T/t"; reject "含 . 成分" target "$T/t" "$T/name"
printf '%s' "$T/x"$'\n'"TARGET_EOF"$'\n'"touch $CANARY"$'\n'"/plaud-to-srt" > "$T/t"; reject "含換行與結束標記的路徑" target "$T/t" "$T/name"; [ ! -e "$CANARY" ] && ok "且沒有執行任何指令" || bad "指令被執行了"
printf '%s' "$T/other" > "$T/t"; reject "目錄名不等於名字" target "$T/t" "$T/name"
mkdir -p "$T/exists/plaud-to-srt"; printf '%s' "$T/exists/plaud-to-srt" > "$T/t"; reject "目標已存在" target "$T/t" "$T/name"
ln -s /nonexistent "$T/dangling-plaud-to-srt"; printf '%s' 'dangling-plaud-to-srt' > "$T/name2"; printf '%s' "$T/dangling-plaud-to-srt" > "$T/t"; reject "懸空 symlink 也算已存在" target "$T/t" "$T/name2"
printf '' > "$T/t"; reject "目標檔為空" target "$T/t" "$T/name"
# 名字檔不合法、且目標目錄名恰好等於那個不合法的名字：只有「target 模式內部重驗名字」那一行能擋下（變異測試：刪掉該行這條會失敗）
printf 'Bad_Name' > "$T/name3"; printf '%s' "$T/newdir/Bad_Name" > "$T/t"; reject "名字檔不合法且目標目錄名與它相同 → 仍拒絕（名字在 target 模式被重驗）" target "$T/t" "$T/name3"
printf 'ab\0cd' > "$T/name4"; printf '%s' "$T/newdir/abcd" > "$T/t"; reject "名字檔含 NUL 時 target 模式也拒絕" target "$T/t" "$T/name4"
reject "沒給名字檔" target "$T/t"

echo "target-used（Step 5、6：名字與格式仍驗，但目標已存在是預期的）:"
printf '%s' "plaud-to-srt" > "$T/name"
mkdir -p "$T/made/plaud-to-srt"; printf '%s' "$T/made/plaud-to-srt" > "$T/t"; accept "目標已存在也通過（用於建好之後）" target-used "$T/t" "$T/name" "$T/made/plaud-to-srt"
printf '%s' "$T/made/a;b/plaud-to-srt" > "$T/t"; reject "target-used 仍擋 shell 元字元" target-used "$T/t" "$T/name"
printf '%s' "$T/made/../plaud-to-srt" > "$T/t"; reject "target-used 仍擋 .." target-used "$T/t" "$T/name"

echo "model（Step 5）:"
printf '%s' 'claude-fable-5-2' > "$T/m"; accept "合法 model ID" model "$T/m" "" "claude-fable-5-2"
printf '%s' 'claude-opus-5-5[1m]' > "$T/m"; accept "含 [1m] 的 model ID" model "$T/m" "" "claude-opus-5-5[1m]"
printf '%s\n' 'gpt-6.2-sol' > "$T/m"; accept "結尾換行被容許並去掉" model "$T/m" "" "gpt-6.2-sol"
printf 'gpt\nx' > "$T/m"; reject "內嵌換行（舊寫法刪掉合法字元後只剩換行，被 \$(...) 吃掉而放行）" model "$T/m"
printf 'gpt\0x' > "$T/m"; reject "含 NUL" model "$T/m"
printf '%s' '-x' > "$T/m"; reject "以 - 開頭" model "$T/m"
printf '%s' 'a b' > "$T/m"; reject "含空白" model "$T/m"
printf '%s' 'a$(id)' > "$T/m"; reject "含 \$(...)" model "$T/m"
printf '' > "$T/m"; reject "空檔案" model "$T/m"
printf '%s' "$(printf 'a%.0s' $(seq 1 100))" > "$T/m"; accept "恰好 100 字元" model "$T/m" "" "$(printf 'a%.0s' $(seq 1 100))"
printf '%s' "$(printf 'a%.0s' $(seq 1 101))" > "$T/m"; reject "101 字元" model "$T/m"

# 白名單那一次 tr 失敗（沒有輸出）時要拒絕，不能當成「什麼都不剩」（verify R7：拿掉 || printf FAIL 這條會失敗）
# 真正的 tr 從環境變數傳給替身，不寫死路徑；並確認拒絕來自白名單那一支，不是 NUL 計數那一次先失敗
REAL_TR=$(type -P tr); export REAL_TR   # type -P 只回可執行檔的路徑，不會回同名函式
mkdir -p "$T/fakebin"; printf '%s\n' '#!/bin/bash' 'for a in "$@"; do [ "$a" = "A-Za-z0-9._:[]-" ] && exit 1; done' 'exec "$REAL_TR" "$@"' > "$T/fakebin/tr"; chmod +x "$T/fakebin/tr"
printf '%s' 'gpt-6.2-sol' > "$T/m"; rc=0; ERR=$(PATH="$T/fakebin:$PATH" bash "$V" model "$T/m" 2>&1 >/dev/null) || rc=$?
case "$ERR" in *"model ID 含不合法字元"*) [ "$rc" -eq 1 ] && ok "白名單的 tr 失敗時拒絕（不放行合法字元以外的東西）" || bad "白名單的 tr 失敗時結束碼不是 1" "rc=$rc";; *) bad "白名單的 tr 失敗時沒有在白名單那一支拒絕" "rc=$rc err=[$ERR]";; esac

echo "mode:"
reject "未知模式" bogus "$T/n"

echo ""; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
