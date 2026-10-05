#!/bin/bash
# check-skill-creator.sh — 判斷官方 skill-creator 是否已安裝且啟用。
#
# Usage:
#   check-skill-creator.sh
#
# Exit codes:
#   0  可用（stdout 印出 installPath）
#   1  未安裝，或登記了但檔案不在（stderr 印出一行安裝指令）
#   2  這台機器沒有 python3（本腳本用它解析 JSON；不能退回猜測，否則會把「缺 python3」誤報成「找不到 skill-creator」）
#   3  已安裝但停用（stderr 印出一行啟用指令）
#
# 環境變數（測試用注入，平常不需要設）：
#   CLAUDE_BIN              claude CLI 的路徑，預設 `claude`
#   INSTALLED_PLUGINS_JSON  本機安裝紀錄檔，預設 ~/.claude/plugins/installed_plugins.json
#   CLAUDE_TIMEOUT          claude CLI 的逾時秒數，預設 20（需要 perl；沒有 perl 就不設逾時）
#
# WHY THIS EXISTS
#   skill-create 要呼叫官方 skill-creator，這是這個 repo 第一個對外部 plugin 的硬依賴。
#   Claude Code 沒有 plugin 依賴宣告機制，缺依賴時流程會靜默斷裂，所以在呼叫前先查。
#
#   判斷來源有兩個：
#     1. `claude plugin list --json` —— 主。回傳 id / enabled / installPath。
#     2. 本機安裝紀錄檔 —— CLI 不在、非零結束、或回傳不是 JSON 陣列時的後援。
#        紀錄檔不帶 enabled，所以走這條路時 exit 0 但在 stderr 明說 enabled 無法確認。
#
#   CLI 說「沒裝」是權威答案，不會再退去看磁碟：兩個來源不一致時以 CLI 為準。
#
#   刻意不做「取最高版本目錄」：官方 skill-creator 的版本是 12 位十六進位 hash，
#   沒有大小順序可比。本機 plugin cache 底下同一個 plugin 可以有十幾個舊 hash 目錄，
#   取字典序最大的會挑到一個過期的。永遠用 CLI 或紀錄檔給的 installPath。
#
#   id 必須整串相等（skill-creator@claude-plugins-official）。只比名稱會把另一個
#   marketplace 的同名 plugin、或名稱只是前綴相同的 plugin 當成它。
#
#   CLI 回傳的 JSON 若缺 enabled 欄位（舊版 CLI），視同 CLI 不可用而退到磁碟，不當成停用。
#
#   需要 python3（macOS 內建）。跑在 /bin/bash 3.2 下，不用 bash 4 的語法。

set -u

PLUGIN_ID="skill-creator@claude-plugins-official"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
INSTALLED_PLUGINS_JSON="${INSTALLED_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"

# 判斷一個 installPath 可不可用的規則（目錄底下要有 skills/skill-creator/SKILL.md）寫在兩段 python 裡各一份。
# 只有目錄存在不夠 —— 被清掉內容的殘留目錄會讓 Skill() 呼叫失敗，而不是讓這個檢查失敗。
# 改這條規則時兩處要一起改（見下方兩段 python 的 os.path.isfile）。

# python3 是硬前置：沒有它兩個來源都解析不了，最後會落到 report_missing，把「缺 python3」誤報成「找不到 skill-creator」。
command -v python3 >/dev/null 2>&1 || { echo "✗ 需要 python3 來解析 JSON，但 PATH 上找不到。這與 skill-creator 有沒有裝無關。" >&2; exit 2; }

hint_install() {
  echo "  安裝：claude plugin install ${PLUGIN_ID}" >&2
}

report_missing() {
  echo "✗ 找不到官方 skill-creator（${PLUGIN_ID}）。skill-create 需要它，不會退回內建流程。" >&2
  hint_install
  exit 1
}

report_stale() {  # $1 = installPath
  echo "✗ ${PLUGIN_ID} 已登記，但 installPath 不存在或缺少 skills/skill-creator/SKILL.md：$1" >&2
  echo "  重新安裝：claude plugin install ${PLUGIN_ID}" >&2
  exit 1
}

report_disabled() {
  echo "✗ ${PLUGIN_ID} 已安裝但停用，Skill() 呼叫會失敗。" >&2
  echo "  啟用：claude plugin enable ${PLUGIN_ID}" >&2
  exit 3
}

# --- 來源 1：claude CLI --------------------------------------------------------
# 輸出格式（python 印一行）：
#   BAD                    不是 JSON 陣列 —— 當作 CLI 不可用，退到磁碟
#   MISSING                陣列裡沒有這個 id
#   DISABLED               有登記但全部 enabled=false
#   OK<TAB><path>          有登記、啟用，且其中一個 installPath 通過檢查
#   STALE<TAB><path>       有登記、啟用，但沒有任何 installPath 通過檢查
CLI_VERDICT=""
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-20}"
  if command -v perl >/dev/null 2>&1; then
    # 輸出寫到暫存檔而不是 $(...)：command substitution 會等所有持有 stdout 管線的行程結束，
    # CLI 若留下子行程，alarm 只殺得到直接的那個，$(...) 仍會卡到子行程結束。檔案不是管線，沒有這個問題。
    CLI_TMP=$(mktemp "${TMPDIR:-/tmp}/check-skill-creator.XXXXXX") || CLI_TMP=""
    if [ -n "$CLI_TMP" ]; then
      perl -e 'alarm shift; exec @ARGV' "$CLAUDE_TIMEOUT" "$CLAUDE_BIN" plugin list --json >"$CLI_TMP" 2>/dev/null
      CLI_RC=$?
      CLI_OUT=$(cat "$CLI_TMP"); rm -f "$CLI_TMP"
    else
      CLI_OUT=$("$CLAUDE_BIN" plugin list --json 2>/dev/null); CLI_RC=$?
    fi
  else
    CLI_OUT=$("$CLAUDE_BIN" plugin list --json 2>/dev/null); CLI_RC=$?
  fi
  if [ "$CLI_RC" -eq 0 ]; then
    CLI_VERDICT=$(printf '%s' "$CLI_OUT" | python3 -c '
import json, os, sys
pid = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("BAD"); sys.exit()
if not isinstance(d, list):
    print("BAD"); sys.exit()
ent = [e for e in d if isinstance(e, dict) and e.get("id") == pid]
if not ent:
    print("MISSING"); sys.exit()
if any("enabled" not in e for e in ent):
    print("BAD"); sys.exit()      # 舊版 CLI 沒有這個欄位：當作 CLI 不可用，不當成停用
on = [e for e in ent if e.get("enabled") is True]
if not on:
    print("DISABLED"); sys.exit()
paths = [str(e.get("installPath") or "") for e in on]
for p in paths:
    if p and os.path.isfile(os.path.join(p, "skills", "skill-creator", "SKILL.md")):
        print("OK\t" + p); sys.exit()
print("STALE\t" + (paths[0] if paths else ""))
' "${PLUGIN_ID}" 2>/dev/null)
  fi
fi

case "$CLI_VERDICT" in
  "OK	"*)      printf '%s\n' "${CLI_VERDICT#OK	}"; exit 0 ;;
  MISSING)      report_missing ;;
  DISABLED)     report_disabled ;;
  "STALE	"*)   report_stale "${CLI_VERDICT#STALE	}" ;;
esac

# --- 來源 2：本機安裝紀錄檔（後援）----------------------------------------------
# 走到這裡代表 CLI 不在、非零結束、或回傳不是 JSON 陣列。
echo "⚠ 無法由 claude CLI 取得 plugin 清單，改用本機安裝紀錄；enabled 狀態無法確認。" >&2

DISK_VERDICT=$(python3 -c '
import json, os, sys
pid, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
    entries = d.get("plugins", {}).get(pid, [])
except Exception:
    print("MISSING"); sys.exit()
if not entries:
    print("MISSING"); sys.exit()
paths = [str(e.get("installPath") or "") for e in entries if isinstance(e, dict)]
for p in paths:
    if p and os.path.isfile(os.path.join(p, "skills", "skill-creator", "SKILL.md")):
        print("OK\t" + p); sys.exit()
print("STALE\t" + (paths[0] if paths else ""))
' "${PLUGIN_ID}" "$INSTALLED_PLUGINS_JSON" 2>/dev/null)

case "$DISK_VERDICT" in
  "OK	"*)      printf '%s\n' "${DISK_VERDICT#OK	}"; exit 0 ;;
  "STALE	"*)   report_stale "${DISK_VERDICT#STALE	}" ;;
  *)            report_missing ;;
esac
