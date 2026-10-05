#!/bin/bash
# 煙霧測試：把 skills/skill-create/SKILL.md 裡的 bash 區塊原樣抽出來，用一份合成的輸入跑完整流程。
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
B_CLEAN=$(find_block 'skill-create.??????')
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
printf '%s' "$T/Che's skills/plaud-to-srt" > "$WORK/target"; fill "$B_TARGET"
OUT=$("$SH" "$T/filled.sh" 2>&1); [ "$OUT" = "target dir: $T/Che's skills/plaud-to-srt" ] && ok "含單引號的合法路徑通過（${SH}）" || bad "含單引號的路徑沒通過" "$OUT"
printf '%s' $'/tmp/x\nTARGET_EOF\ntouch '"$T"$'/CANARY2\n/plaud-to-srt' > "$WORK/target"; fill "$B_TARGET"
"$SH" "$T/filled.sh" >/dev/null 2>&1; [ $? -ne 0 ] && [ ! -e "$T/CANARY2" ] && ok "惡意路徑被拒絕且沒有執行" || bad "惡意路徑沒被擋或指令被執行"

# Step 6：三種結果分開報
printf '%s' "$T/nonexistent/plaud-to-srt" > "$WORK/target"; fill "$B_STEP6"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"不存在"*"未執行"*) ok "目標不存在 → 如實報未執行";; *) bad "目標不存在的訊息不對" "$OUT";; esac
mkdir -p "$T/nogit/plaud-to-srt"; printf '%s' "$T/nogit/plaud-to-srt" > "$WORK/target"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"不在 git repo"*"不是通過"*) ok "不在 git repo → 如實報未執行";; *) bad "不在 git repo 的訊息不對" "$OUT";; esac
mkdir -p "$T/repo/plugins/p/skills/plaud-to-srt"; git -C "$T/repo" init -q 2>/dev/null
printf '%s' "$T/repo/plugins/p/skills/plaud-to-srt" > "$WORK/target"
OUT=$("$SH" "$T/filled.sh" 2>&1); case "$OUT" in *"引用檢查通過"*|*"發現失效引用"*) ok "在 git repo 內 → 實際跑了檢查並如實報結果";; *) bad "在 git repo 內的訊息不對" "$OUT";; esac

# 清理：守衛。錯的形狀不刪；對的形狀刪
fill "$B_CLEAN"
KEEP="$T/keepme"; mkdir -p "$KEEP"; sed "s|^WORK=.*|WORK=$KEEP|" "$T/filled.sh" > "$T/clean_bad.sh"
TMPDIR="$T" "$SH" "$T/clean_bad.sh" >/dev/null 2>&1; [ -d "$KEEP" ] && ok "形狀不對的目錄不被刪" || bad "形狀不對的目錄被刪了"
TMPDIR="$T" "$SH" "$T/filled.sh" >/dev/null 2>&1; [ ! -d "$WORK" ] && ok "對的工作目錄被刪掉" || bad "對的工作目錄沒被刪"

echo ""; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL  (${SH})"
[ "$FAIL" -eq 0 ]
