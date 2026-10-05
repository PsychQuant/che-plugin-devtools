#!/bin/bash
# Tests for check-skill-creator.sh
#
# Run: bash plugins/harness-devtools/scripts/test-check-skill-creator.sh
# Exit 0 = all pass, 1 = any failure.
#
# 腳本的判斷來源有兩個：`claude plugin list --json`（主），以及本機安裝紀錄檔
# （CLI 不在或回傳不可用時的後援）。兩者都用環境變數注入（CLAUDE_BIN、
# INSTALLED_PLUGINS_JSON），所以測試完全不碰這台機器真正裝了什麼。
#
# 夾具刻意讓 installPath 的最後一段是 12 位十六進位 hash —— 官方 skill-creator 的
# 版本就是這種形狀，沒有 semver 順序可比。腳本若偷偷依賴「取最高版本目錄」，
# 這組夾具會讓它露餡。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check-skill-creator.sh"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

ID="skill-creator@claude-plugins-official"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "  ✓ $desc" ;;
    *) FAIL=$((FAIL + 1)); echo "  ✗ $desc"
       echo "      missing:  '$needle'"
       echo "      in:       '$haystack'" ;;
  esac
}

# 一個合成的已安裝 skill-creator：hash 目錄 + 官方的 skills/skill-creator/SKILL.md 佈局
INSTALL="$TMPROOT/cache/claude-plugins-official/skill-creator/d182ca456ca0"
mkdir -p "$INSTALL/skills/skill-creator"
echo "# fixture" > "$INSTALL/skills/skill-creator/SKILL.md"

# 假的 claude CLI：把 $FAKE_CLAUDE_OUT 原樣印出，並以 $FAKE_CLAUDE_RC 結束
FAKE_BIN="$TMPROOT/fake-claude"
cat > "$FAKE_BIN" <<'EOF'
#!/bin/bash
[ -n "${FAKE_CLAUDE_SLEEP:-}" ] && sleep "$FAKE_CLAUDE_SLEEP"
printf '%s' "${FAKE_CLAUDE_OUT:-}"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "$FAKE_BIN"

cli_json() {  # $1=id  $2=enabled(true|false)  $3=installPath
  printf '[{"id":"%s","version":"d182ca456ca0","enabled":%s,"scope":"user","installPath":"%s"}]' "$1" "$2" "$3"
}

disk_json() {  # $1=id  $2=installPath
  printf '{"version":2,"plugins":{"%s":[{"scope":"user","installPath":"%s","version":"d182ca456ca0"}]}}' "$1" "$2"
}

NO_DISK="$TMPROOT/does-not-exist.json"
EMPTY_DISK="$TMPROOT/empty-disk.json"
echo '{"version":2,"plugins":{}}' > "$EMPTY_DISK"

# run: 以環境注入執行腳本，把 stdout、stderr、exit code 分別存起來
run() {  # $1=CLAUDE_BIN  $2=INSTALLED_PLUGINS_JSON  (其餘環境變數由呼叫端先 export)
  OUT=$(CLAUDE_BIN="$1" INSTALLED_PLUGINS_JSON="$2" bash "$CHECKER" 2>"$TMPROOT/err")
  RC=$?
  ERR=$(cat "$TMPROOT/err")
}

echo "CLI 為主："
FAKE_CLAUDE_OUT=$(cli_json "$ID" true "$INSTALL") FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$NO_DISK"
assert_eq "已安裝且啟用 → exit 0" "0" "$RC"
assert_contains "stdout 印出 installPath（hash 目錄名不影響判斷）" "$INSTALL" "$OUT"

export FAKE_CLAUDE_OUT='[]' FAKE_CLAUDE_RC=0
run "$FAKE_BIN" "$NO_DISK"
assert_eq "CLI 說沒裝 → exit 1" "1" "$RC"
assert_contains "缺席時印出安裝指令" "claude plugin install $ID" "$ERR"

FAKE_CLAUDE_OUT=$(cli_json "$ID" false "$INSTALL") run "$FAKE_BIN" "$NO_DISK"
assert_eq "已安裝但停用 → exit 3" "3" "$RC"
assert_contains "停用時印出啟用指令" "claude plugin enable $ID" "$ERR"

FAKE_CLAUDE_OUT=$(cli_json "$ID" true "$TMPROOT/gone") run "$FAKE_BIN" "$NO_DISK"
assert_eq "登記了但 installPath 不存在 → exit 1" "1" "$RC"
assert_contains "指出是檔案不在而不是沒登記" "installPath" "$ERR"

FAKE_CLAUDE_OUT=$(cli_json "skill-creator@some-other-marketplace" true "$INSTALL") run "$FAKE_BIN" "$NO_DISK"
assert_eq "同名但來自別的 marketplace 不算 → exit 1" "1" "$RC"

FAKE_CLAUDE_OUT=$(cli_json "skill-creator-extra@claude-plugins-official" true "$INSTALL") run "$FAKE_BIN" "$NO_DISK"
assert_eq "名稱只是前綴相同的另一個 plugin 不算 → exit 1" "1" "$RC"

echo "CLI 不可用 → 磁碟後援："
disk_json "$ID" "$INSTALL" > "$TMPROOT/disk-ok.json"
run "$TMPROOT/no-such-claude" "$TMPROOT/disk-ok.json"
assert_eq "CLI 缺席、磁碟有 → exit 0" "0" "$RC"
assert_contains "後援路徑說明 enabled 狀態無法確認" "enabled" "$ERR"

run "$TMPROOT/no-such-claude" "$EMPTY_DISK"
assert_eq "CLI 缺席、磁碟紀錄為空 → exit 1" "1" "$RC"
assert_contains "後援也找不到時印出安裝指令" "claude plugin install $ID" "$ERR"

run "$TMPROOT/no-such-claude" "$NO_DISK"
assert_eq "CLI 缺席、連紀錄檔都沒有 → exit 1" "1" "$RC"

disk_json "$ID" "$TMPROOT/gone" > "$TMPROOT/disk-stale.json"
run "$TMPROOT/no-such-claude" "$TMPROOT/disk-stale.json"
assert_eq "CLI 缺席、紀錄有但目錄已不在 → exit 1" "1" "$RC"

FAKE_CLAUDE_OUT='not json at all' FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$TMPROOT/disk-ok.json"
assert_eq "CLI 回傳損毀 → 退到磁碟，磁碟有 → exit 0" "0" "$RC"

FAKE_CLAUDE_OUT='not json at all' FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$NO_DISK"
assert_eq "CLI 回傳損毀、磁碟也無 → exit 1" "1" "$RC"

FAKE_CLAUDE_OUT='' FAKE_CLAUDE_RC=1 run "$FAKE_BIN" "$TMPROOT/disk-ok.json"
assert_eq "CLI 非零結束 → 退到磁碟 → exit 0" "0" "$RC"

echo "設計決定（verify R1 補上：這些在腳本檔頭明寫過，但原本沒有測試守著）："
FAKE_CLAUDE_OUT='[]' FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$TMPROOT/disk-ok.json"
assert_eq "CLI 說沒裝、磁碟卻有紀錄 → 以 CLI 為準，exit 1" "1" "$RC"

MULTI=$(printf '[{"id":"%s","version":"x","enabled":false,"scope":"user","installPath":"%s"},{"id":"%s","version":"x","enabled":true,"scope":"project","installPath":"%s"}]' "$ID" "$TMPROOT/gone" "$ID" "$INSTALL")
FAKE_CLAUDE_OUT="$MULTI" FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$NO_DISK"
assert_eq "同一 id 多個 scope，其中一個停用、一個啟用且可用 → exit 0" "0" "$RC"
assert_contains "印出的是那個可用的 installPath" "$INSTALL" "$OUT"

NOEN=$(printf '[{"id":"%s","version":"x","scope":"user","installPath":"%s"}]' "$ID" "$INSTALL")
FAKE_CLAUDE_OUT="$NOEN" FAKE_CLAUDE_RC=0 run "$FAKE_BIN" "$TMPROOT/disk-ok.json"
assert_eq "CLI 回傳沒有 enabled 欄位（舊版）→ 不誤報停用，退到磁碟 exit 0" "0" "$RC"
assert_contains "並說明 enabled 無法確認" "enabled" "$ERR"

if command -v perl >/dev/null 2>&1; then
  FAKE_CLAUDE_OUT=$(cli_json "$ID" true "$INSTALL") FAKE_CLAUDE_RC=0 FAKE_CLAUDE_SLEEP=3 CLAUDE_TIMEOUT=1 run "$FAKE_BIN" "$TMPROOT/disk-ok.json"
  assert_eq "CLI 卡住超過逾時 → 退到磁碟，不讓整個 skill 卡在 Step 1" "0" "$RC"
  assert_contains "並說明改用了本機安裝紀錄" "本機安裝紀錄" "$ERR"
else
  echo "  - 略過逾時測試：這台機器沒有 perl"
fi

mkdir -p "$TMPROOT/emptybin"
OUT=$(PATH="$TMPROOT/emptybin" CLAUDE_BIN="$FAKE_BIN" INSTALLED_PLUGINS_JSON="$TMPROOT/disk-ok.json" /bin/bash "$CHECKER" 2>"$TMPROOT/err"); RC=$?; ERR=$(cat "$TMPROOT/err")
assert_eq "python3 不在 PATH → exit 2（不是誤報成「找不到 skill-creator」）" "2" "$RC"
assert_contains "訊息點名 python3" "python3" "$ERR"

echo ""
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
