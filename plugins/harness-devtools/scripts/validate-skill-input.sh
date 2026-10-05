#!/bin/bash
# validate-skill-input.sh — 驗證 skill-create 收到的不可信輸入（名字、目標路徑）。
#
# Usage:
#   validate-skill-input.sh name   <file>
#   validate-skill-input.sh target <file> <name-file>
#
# 通過：把驗證後的值印在 stdout，exit 0。不通過：原因印在 stderr，exit 1。
#
# WHY THIS EXISTS
#   skill-create 的輸入（名字、路徑）來自使用者，不可信。前三輪 verify 證明：把值貼進
#   shell 原始碼（單引號、heredoc）再驗證，每一種都在驗證之前就被內容裡的字元或結束標記
#   提早結束而執行。所以值一律用 Write 工具寫進檔案（Write 的內容不經 shell），本腳本只
#   讀檔、驗證、把值印回去 —— 驗證用的值與之後使用的值是同一次讀取的結果，不是兩份。
#
#   驗證邏輯放在這裡而不是 SKILL.md 的散文裡，是為了每個步驟都用同一份、有測試守著，
#   而不是各步驟各抄一段然後日後各自改動。
#
#   跑在 /bin/bash 3.2 下。

set -u
export LC_ALL=C

die() { echo "✗ $*" >&2; exit 1; }

MODE="${1:-}"; FILE="${2:-}"
[ -n "$MODE" ] && [ -n "$FILE" ] || die "用法：validate-skill-input.sh name|target <file> [name-file]"
[ -f "$FILE" ] || die "找不到輸入檔：$FILE"

# NUL 在 $(...) 裡會被各 shell 以不同方式處理（bash 丟掉、zsh 保留），所以在讀取之前就拒絕。
if [ "$(tr -d '\000' < "$FILE" | wc -c)" -ne "$(wc -c < "$FILE")" ]; then die "輸入含 NUL 位元組"; fi

read_value() { local v; v=$(cat "$1"); printf '%s' "$v"; }   # $(...) 會去掉結尾換行；中間的換行留給下面的檢查擋

check_name() {  # $1 = 值
  case "$1" in
    ''|-*|*[!a-z0-9-]*) die "名字格式不合：只接受小寫英數與連字號（不得為空、不得以連字號開頭、不得含換行或其他字元）" ;;
  esac
  [ "${#1}" -le 64 ] || die "名字超過 64 字元"
}

case "$MODE" in
  name)
    NAME=$(read_value "$FILE"); check_name "$NAME"; printf '%s\n' "$NAME" ;;
  target)
    NAMEFILE="${3:-}"; [ -n "$NAMEFILE" ] && [ -f "$NAMEFILE" ] || die "target 模式需要名字檔"
    NAME=$(read_value "$NAMEFILE"); check_name "$NAME"     # 目標驗證之前，名字自己再驗一次，不信任「前一步已經驗過」
    TARGET=$(read_value "$FILE")
    [ -n "$TARGET" ] || die "目標路徑是空的"
    case "$TARGET" in /*) : ;; *) die "目標必須是絕對路徑" ;; esac
    case "$TARGET" in *[[:cntrl:]]*) die "路徑含控制字元（含換行）" ;; esac
    case "$TARGET/" in */../*|*/./*) die "路徑含 . 或 .. 成分" ;; esac
    [ "${TARGET##*/}" = "$NAME" ] || die "目錄名必須等於已驗證的名字 $NAME"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then die "$TARGET 已存在（含懸空 symlink），不覆蓋"; fi
    printf '%s\n' "$TARGET" ;;
  *) die "未知模式：$MODE" ;;
esac
