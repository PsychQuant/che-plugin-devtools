#!/bin/bash
# 煙霧測試：把 skills/skill-create/SKILL.md 裡的 bash 區塊原樣抽出來，用一份合成的輸入跑 Step 2、3、6 與清理。
# Step 1、4、5 需要真的 skill-creator 與 `claude -p`，不在這裡跑（Step 5 的 model ID 檢查由 test-validate-skill-input.sh 守）。
# 目的是讓文件裡的指令不會只是「看起來對」—— 之前每一輪 verify 都靠人實跑才抓到文件裡的 bash 壞掉。
#
# Run: bash plugins/harness-devtools/scripts/test-skill-create-snippets.sh [shell]   （預設 bash；也可傳 zsh）
set -u
SH="${1:-bash}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$CLAUDE_PLUGIN_ROOT/skills/skill-create/SKILL.md"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
command -v "$SH" >/dev/null 2>&1 || { echo "略過：這台機器沒有 ${SH}"; exit 0; }

# 抽出所有 ```bash 區塊，依序存成 $T/block_N.sh
python3 - "$SKILL" "$T" <<'PY'
import re,sys
t=open(sys.argv[1],encoding='utf-8').read()
for i,b in enumerate(re.findall(r'```bash\n(.*?)\n```',t,re.S),1):
    open(f"{sys.argv[2]}/block_{i}.sh",'w',encoding='utf-8').write(b+"\n")
PY
N=$(ls "$T"/block_*.sh | wc -l | tr -d ' ')
[ "$N" -ge 6 ] && ok "抽到 $N 個 bash 區塊" || bad "只抽到 $N 個 bash 區塊（預期 >= 6）"

find_block() { grep -lF -- "$1" "$T"/block_*.sh 2>/dev/null | head -1; }   # 以區塊內的固定特徵字串找到它
B_WORK=$(find_block 'mktemp -d')
B_NAME=$(find_block 'validate-skill-input.sh" name')
B_TARGET=$(find_block 'validate-skill-input.sh" target')
B_STEP6=$(find_block 'check-skill-references.sh" --repo "$TARGET_REPO"')
B_CLEAN=$(find_block 'rm -rf -- "$WORK"')
for v in B_WORK B_NAME B_TARGET B_STEP6 B_CLEAN; do eval "f=\${$v}"; [ -n "$f" ] && ok "找到區塊 $v" || bad "找不到區塊 $v"; done

# 步驟 2：建工作目錄，取出它印出的 WORK=... 那一行
OUT=$(TMPDIR="$T" "$SH" "$B_WORK" 2>&1); WORKLINE=$(printf '%s\n' "$OUT" | grep '^WORK=' | head -1)
[ -n "$WORKLINE" ] && ok "Step 2 印出 WORK=... 一行" || bad "Step 2 沒印出 WORK=" "$OUT"
eval "$WORKLINE"
fill() { sed "s|<貼上 Step 2 印出的 WORK=... 那一行>|$WORKLINE|" "$1" > "$T/filled.sh"; }   # 模擬 agent 逐字貼回那一行

# 名字：惡意內容（含結束標記）→ 應被拒絕且不執行；合法 → 通過
printf '%s' $'x\nNAME_EOF\ntouch '"$T"$'/CANARY\nNAME_EOF' > "$WORK/name"; fill "$B_NAME"
"$SH" "$T/filled.sh" >/dev/null 2>&1; [ $? -ne 0 ] && [ ! -e "$T/CANARY" ] && ok "惡意名字被拒絕且沒有執行（${SH}）" || bad "惡意名字沒被擋或指令被執行"
printf '%s' 'plaud-to-srt' > "$WORK/name"; OUT=$("$SH" "$T/filled.sh" 2>&1); [ "$OUT" = "name ok: plaud-to-srt" ] && ok "合法名字通過" || bad "合法名字沒通過" "$OUT"

# 目標
printf '%s' "$T/Che skills/plaud-to-srt" > "$WORK/target"; fill "$B_TARGET"
OUT=$("$SH" "$T/filled.sh" 2>&1); [ "$OUT" = "target dir: $T/Che skills/plaud-to-srt" ] && ok "含空白的合法路徑通過（${SH}）" || bad "含空白的路徑沒通過" "$OUT"
printf '%s' "$T/Che's skills/plaud-to-srt" > "$WORK/target"
"$SH" "$T/filled.sh" >/dev/null 2>&1; [ $? -ne 0 ] && ok "含單引號的路徑被拒絕（會原樣交給 skill-creator）" || bad "含單引號的路徑被接受了"
printf '%s' $'/tmp/x\nTARGET_EOF\ntouch '"$T"$'/CANARY2\n/plaud-to-srt' > "$WORK/target"; fill "$B_TARGET"
"$SH" "$T/filled.sh" >/dev/null 2>&1; [ $? -ne 0 ] && [ ! -e "$T/CANARY2" ] && ok "惡意路徑被拒絕且沒有執行" || bad "惡意路徑沒被擋或指令被執行"

# Step 6：四種結果分開報。每一種都要有各自的 fixture 與各自的斷言，所以把分支對調會讓測試失敗（verify R5 變異測試）。
# 而且每次只能印出一種結果：只比對預期字串的話，同時印出兩種互相矛盾的結果也會通過（verify R6）。
one_result() { # $1 = 輸出；印出結果句出現的總次數（同一句印兩次算兩次）
  local n=0 p c
  # 比對 Step 6 自己印的整句，不比對單字：check-skill-references.sh 的輸出本身就有「不存在」等字
  for p in "不存在（Step 4 沒有建出 skill）" "目標不在 git repo 內" "引用檢查通過" "引用檢查跑完了，但發現失效引用" "引用檢查沒有跑成"; do c=$(printf '%s\n' "$1" | grep -oF -- "$p" | wc -l | tr -d ' '); n=$((n+c)); done
  echo "$n"; }
printf '%s' 'plaud-to-srt' > "$WORK/name"
printf '%s' "$T/nonexistent/plaud-to-srt" > "$WORK/target"; fill "$B_STEP6"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"不存在"*"未執行"*) ok "目標不存在 → 報未執行";; *) bad "目標不存在的訊息不對" "$OUT";; esac; [ "$(one_result "$OUT")" = 1 ] || bad "目標不存在時印出不只一種結果" "$OUT"
mkdir -p "$T/nogit/plaud-to-srt"; printf '%s' "$T/nogit/plaud-to-srt" > "$WORK/target"
# GIT_CEILING_DIRECTORIES：TMPDIR 若剛好在某個 checkout 裡，git 會往上找到它，讓這個 fixture 不再是「不在 repo」（verify R6）
OUT=$(GIT_CEILING_DIRECTORIES="$T" "$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"不在 git repo"*"不是通過"*) ok "不在 git repo → 報未執行";; *) bad "不在 git repo 的訊息不對" "$OUT";; esac; [ "$(one_result "$OUT")" = 1 ] || bad "不在 git repo 時印出不只一種結果" "$OUT"
# 乾淨的 repo：有 plugins/，沒有失效引用 → 通過
mkdir -p "$T/clean/plugins/p/skills/plaud-to-srt"; git -C "$T/clean" init -q 2>/dev/null
printf -- '---\nname: plaud-to-srt\n---\nplain text\n' > "$T/clean/plugins/p/skills/plaud-to-srt/SKILL.md"
printf '%s' "$T/clean/plugins/p/skills/plaud-to-srt" > "$WORK/target"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"引用檢查通過"*) ok "乾淨的 repo → 報通過";; *) bad "乾淨 repo 沒報通過" "$OUT";; esac; [ "$(one_result "$OUT")" = 1 ] || bad "乾淨 repo 時印出不只一種結果" "$OUT"
# 目標存在、在 repo 裡，但名字檔與目錄名不符：只有 Step 6 自己的 target-used 重驗擋得下，引用檢查不得被呼叫。
# 變異測試：把那一行改回直接讀檔，這條就會失敗（verify R6：先前五個 fixture 的名字與路徑都合法，看不出差別）
mkdir -p "$T/clean/plugins/p/skills/other-name"; printf '%s' "$T/clean/plugins/p/skills/other-name" > "$WORK/target"
# 引用檢查換成替身：被呼叫就留下記號，用來直接證明它沒有被呼叫（verify R7）
STUB="$T/stubroot"; mkdir -p "$STUB/scripts"; cp "$CLAUDE_PLUGIN_ROOT/scripts/validate-skill-input.sh" "$STUB/scripts/"
# 替身的原始碼是固定字串，記號路徑從環境變數傳入，不把 $T 寫進原始碼
printf '%s\n' '#!/bin/bash' 'touch "$CHECKER_MARK"' 'exit 0' > "$STUB/scripts/check-skill-references.sh"
export CHECKER_MARK="$T/CHECKER_CALLED"
OUT=$(CLAUDE_PLUGIN_ROOT="$STUB" "$SH" "$T/filled.sh" 2>&1); RC=$?
case "$OUT" in *"目錄名必須等於"*) [ "$RC" -ne 0 ] && [ ! -e "$T/CHECKER_CALLED" ] && ok "名字與目錄名不符 → Step 6 重驗擋下，引用檢查沒有被呼叫" || bad "重驗擋下了但引用檢查仍被呼叫，或結束碼為 0" "rc=$RC $OUT";; *) bad "名字與目錄名不符卻沒被 Step 6 重驗擋下" "$OUT";; esac
# 替身本身要能被呼叫到，否則上一條的「沒有被呼叫」不證明任何事
printf '%s' "$T/clean/plugins/p/skills/plaud-to-srt" > "$WORK/target"; CLAUDE_PLUGIN_ROOT="$STUB" "$SH" "$T/filled.sh" > /dev/null 2>&1
[ -e "$T/CHECKER_CALLED" ] && ok "替身在正常路徑上會被呼叫（上一條的檢查有效）" || bad "替身在正常路徑上沒有被呼叫，上一條的檢查無效"; rm -f "$T/CHECKER_CALLED"
# 有失效引用的 repo：指向不存在的 skill → 必須報「發現失效引用」，不可報通過，也不可報「沒跑成」
mkdir -p "$T/dangling/plugins/p/skills/plaud-to-srt"; git -C "$T/dangling" init -q 2>/dev/null
printf -- '---\nname: plaud-to-srt\n---\nrun /p:nonexistent-skill now\n' > "$T/dangling/plugins/p/skills/plaud-to-srt/SKILL.md"
printf '%s' "$T/dangling/plugins/p/skills/plaud-to-srt" > "$WORK/target"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"發現失效引用"*) ok "有失效引用 → 報發現失效引用";; *"引用檢查通過"*) bad "有失效引用卻報通過" "$OUT";; *) bad "有失效引用的訊息不對" "$OUT";; esac; [ "$(one_result "$OUT")" = 1 ] || bad "有失效引用時印出不只一種結果" "$OUT"
# 檢查沒跑成（exit 2）：repo 裡沒有 plugins/ 目錄（個人 .claude/skills/ 的情形）→ 必須報沒跑成，不可報發現失效引用
mkdir -p "$T/noplugins/.claude/skills/plaud-to-srt"; git -C "$T/noplugins" init -q 2>/dev/null
printf '%s' "$T/noplugins/.claude/skills/plaud-to-srt" > "$WORK/target"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"沒有跑成"*) ok "檢查沒跑成（exit 2）→ 如實報沒跑成";; *"發現失效引用"*) bad "把 exit 2 誤報成發現失效引用" "$OUT";; *) bad "exit 2 的訊息不對" "$OUT";; esac; [ "$(one_result "$OUT")" = 1 ] || bad "exit 2 時印出不只一種結果" "$OUT"
# errexit：呼叫端開了 set -e 時，引用檢查回非零也要能分流報告，不能在讀到結束碼之前就離開（verify R6）
printf '%s' "$T/dangling/plugins/p/skills/plaud-to-srt" > "$WORK/target"; { echo 'set -e'; cat "$T/filled.sh"; } > "$T/filled_e.sh"
OUT=$("$SH" "$T/filled_e.sh" 2>&1); case "$OUT" in *"發現失效引用"*) ok "set -e 下有失效引用仍如實報告";; *) bad "set -e 下沒報出失效引用（裸跑在讀到結束碼前離開）" "$OUT";; esac

# 清理：守衛。錯的形狀、錯的位置、巢狀、.. 都不刪；對的才刪
fill "$B_CLEAN"
KEEP="$T/keepme"; mkdir -p "$KEEP"; sed "s|^WORK=.*|WORK=$KEEP|" "$T/filled.sh" > "$T/clean_bad.sh"
TMPDIR="$T" "$SH" "$T/clean_bad.sh" >/dev/null 2>&1; [ -d "$KEEP" ] && ok "形狀不對的目錄不被刪" || bad "形狀不對的目錄被刪了"
mkdir -p "$T/skill-create.abcdef/victim"; mkdir -p "$T/sibling"
for BADW in "$T/skill-create.abcdef/../sibling" "$T/skill-create.abcdef/victim"; do
  sed "s|^WORK=.*|WORK=$BADW|" "$T/filled.sh" > "$T/clean_bad2.sh"; TMPDIR="$T" "$SH" "$T/clean_bad2.sh" >/dev/null 2>&1
done
[ -d "$T/sibling" ] && [ -d "$T/skill-create.abcdef/victim" ] && ok "含 .. 或多一層巢狀的路徑不被刪（glob 繞過已堵）" || bad "含 .. 或巢狀的路徑被刪了"
# 最後一段含 . 的假工作目錄：寬鬆的 ?????? 會比對成功，嚴格的六個英數字不會
mkdir -p "$T/skill-create.ab.d34"; sed "s|^WORK=.*|WORK=$T/skill-create.ab.d34|" "$T/filled.sh" > "$T/clean_bad4.sh"
TMPDIR="$T" "$SH" "$T/clean_bad4.sh" >/dev/null 2>&1; [ -d "$T/skill-create.ab.d34" ] && ok "最後一段含 . 的目錄不被刪（?????? 寬鬆寫法會誤刪）" || bad "最後一段含 . 的目錄被刪了"
mkdir -p "$T/elsewhere/skill-create.zzzzzz"; sed "s|^WORK=.*|WORK=$T/elsewhere/skill-create.zzzzzz|" "$T/filled.sh" > "$T/clean_bad3.sh"
TMPDIR="$T" "$SH" "$T/clean_bad3.sh" >/dev/null 2>&1; [ -d "$T/elsewhere/skill-create.zzzzzz" ] && ok "形狀對但不在 TMPDIR 底下的目錄不被刪" || bad "不在 TMPDIR 底下的目錄被刪了"
# 形狀對、字面上看起來在 TMPDIR 底下，但經「symlink/..」實際指到別處：預設的 cd 會按字面消去 ..，只有 cd -P 擋得下（verify R6）
mkdir -p "$T/deep/sub" "$T/deep/skill-create.qqqqqq"; ln -s "$T/deep/sub" "$T/lnk"
sed "s|^WORK=.*|WORK=$T/lnk/../skill-create.qqqqqq|" "$T/filled.sh" > "$T/clean_bad5.sh"
TMPDIR="$T" "$SH" "$T/clean_bad5.sh" >/dev/null 2>&1; [ -d "$T/deep/skill-create.qqqqqq" ] && ok "經 symlink/.. 指到 TMPDIR 外的目錄不被刪" || bad "經 symlink/.. 指到 TMPDIR 外的目錄被刪了"
TMPDIR="$T" "$SH" "$T/filled.sh" >/dev/null 2>&1; [ ! -d "$WORK" ] && ok "對的工作目錄被刪掉" || bad "對的工作目錄沒被刪"

echo ""; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL  (${SH})"
[ "$FAIL" -eq 0 ]
