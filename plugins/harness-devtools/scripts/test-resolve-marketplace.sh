#!/bin/bash
# Unit tests for resolve-marketplace.sh
#
# Run: bash scripts/test-resolve-marketplace.sh
# Exit 0 = all pass, 1 = any failure.
#
# Deliberately runs under /bin/bash (3.2 on macOS) — resolve-marketplace.sh must
# not use bash 4+ features (nameref, associative arrays). This mirrors the
# doc-update-config.sh `local -n` bug: shebang says #!/bin/bash, macOS gives you
# 3.2.57, and bash-4-only syntax fails silently mid-function.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "      expected: '$expected'"
    echo "      actual:   '$actual'"
  fi
}

assert_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc (expected non-zero exit, got 0)"
  else
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  fi
}

# ---------------------------------------------------------------------------

echo "Loading resolve-marketplace.sh ..."
# shellcheck source=./resolve-marketplace.sh
source "$SCRIPT_DIR/resolve-marketplace.sh"

echo
echo "resolve_marketplace_root:"
assert_eq "known marketplace → absolute path" \
  "$HOME/Developer/che-plugin-devtools" \
  "$(resolve_marketplace_root che-plugin-devtools)"

assert_eq "psychquant resolves" \
  "$HOME/Developer/psychquant-claude-plugins" \
  "$(resolve_marketplace_root psychquant-claude-plugins)"

assert_eq "che-local-plugins is nested inside che-claude-config" \
  "$HOME/Developer/che-claude-config/che-local-plugins" \
  "$(resolve_marketplace_root che-local-plugins)"

assert_fails "unknown marketplace returns non-zero" \
  resolve_marketplace_root no-such-marketplace

assert_fails "empty argument returns non-zero" \
  resolve_marketplace_root ""

echo
echo "list_marketplaces:"
# **不斷言確切數字。** 這裡原本是 `assert_eq "lists 4 marketplaces" "4"` ——
# 它不只沒抓到 registry 的覆蓋率缺口，還把缺口鎖住：任何人加第 5 個 marketplace
# 都會弄紅它。下界 + 「已知的都還在」才是這條該驗的東西。
COUNT=$(list_marketplaces | grep -c .)
if [ "$COUNT" -ge 4 ]; then
    PASS=$((PASS + 1)); echo "  ✓ lists at least the four originally hardcoded (got $COUNT)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ lists at least the four originally hardcoded"; echo "      actual: $COUNT"
fi

# Every listed name must itself resolve — guards against a name being added to
# the list but not to the case statement.
ORPHANS=""
for mp in $(list_marketplaces); do
  resolve_marketplace_root "$mp" >/dev/null 2>&1 || ORPHANS="$ORPHANS $mp"
done
assert_eq "every listed marketplace resolves" "" "$ORPHANS"

echo
echo "find_plugin_marketplace:"
# harness-devtools lives in this repo — the one certainty regardless of machine state.
# 三元組（#18）：第三欄是 manifest `plugins[].source` 解析出的 plugin 目錄，
# 不是 `$root/plugins/<name>` 的再約定。消費端用 IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR。
assert_eq "finds harness-devtools in che-plugin-devtools (name|root|plugin_dir)" \
  "che-plugin-devtools|$HOME/Developer/che-plugin-devtools|$HOME/Developer/che-plugin-devtools/plugins/harness-devtools" \
  "$(find_plugin_marketplace harness-devtools)"

assert_fails "unknown plugin returns non-zero" \
  find_plugin_marketplace definitely-not-a-real-plugin

assert_fails "empty plugin name returns non-zero" \
  find_plugin_marketplace ""

# 查一個 plugin 不該印出**別的** marketplace 的警告。find_plugin_marketplace 原本
# 對每個名稱各呼叫一次 resolve_marketplace_root，而後者在同名多候選時會 warn ——
# 於是查 macdoc 會噴出 che-apple-mail-mcp 的多重 checkout 警告。既有的 stderr 測試
# 只涵蓋 **source 當下**，涵蓋不到呼叫時，所以這條是另一個軸。
LOOKUP_NOISE=$(find_plugin_marketplace harness-devtools 2>&1 >/dev/null)
assert_eq "find_plugin_marketplace emits no stderr" "" "$LOOKUP_NOISE"

echo
echo
echo "discovery (#20) — registry is scanned, not enumerated:"

# 存在性先驗。沒有這兩條，下面用到 _marketplace_name_of / marketplace_candidates
# 的斷言在函式**不存在**時也會綠（呼叫失敗 → assert_fails 通過；無輸出 → grep
# 找不到東西）。假綠在函式日後被刪掉時同樣不會亮。
for fn in _marketplace_name_of marketplace_candidates; do
    if command -v "$fn" >/dev/null 2>&1 || type "$fn" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "  ✓ $fn is defined"
    else
        FAIL=$((FAIL + 1)); echo "  ✗ $fn is defined"
    fi
done

# 硬編的 4 筆漏掉本機 29 個 marketplace。macdoc 是觸發本 issue 的那一個：
# 它是正常運作的 self-hosted marketplace，plugin 也裝著，但 resolver 不認得。
assert_eq "macdoc resolves (was missing from the hardcoded case)" \
    "$HOME/Developer/macdoc" \
    "$(resolve_marketplace_root macdoc)"

# 不斷言確切數字 —— 那正是舊測試 `lists 4 marketplaces` 犯的錯（它把缺口鎖住，
# 任何人加第 5 個 marketplace 都會弄紅它）。下界即可。
DISCOVERED=$(list_marketplaces | grep -c .)
if [ "$DISCOVERED" -ge 20 ]; then
    PASS=$((PASS + 1)); echo "  ✓ discovers >= 20 marketplaces (got $DISCOVERED)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ discovers >= 20 marketplaces"; echo "      actual: $DISCOVERED"
fi

echo
echo "name extraction is bounded to the top-level key:"

# 樸素的「抓第一個 \"name\"」對這種 manifest 會靜默回傳 **plugin 的名字**當成
# marketplace 名。抽取必須限定在第一個 "plugins" 之前，取不到才退回真 JSON parser。
NAME_TMP=$(mktemp -d)
cat > "$NAME_TMP/plugins-first.json" <<'FIXTURE'
{
  "plugins": [ { "name": "some-plugin", "source": "./p" } ],
  "name": "real-marketplace-name"
}
FIXTURE
assert_eq "plugins-before-name manifest still yields the marketplace name" \
    "real-marketplace-name" \
    "$(_marketplace_name_of "$NAME_TMP/plugins-first.json")"

cat > "$NAME_TMP/normal.json" <<'FIXTURE'
{ "name": "ordinary", "plugins": [ { "name": "a-plugin" } ] }
FIXTURE
assert_eq "ordinary manifest yields its own name" \
    "ordinary" "$(_marketplace_name_of "$NAME_TMP/normal.json")"

assert_fails "missing manifest returns non-zero" \
    _marketplace_name_of "$NAME_TMP/does-not-exist.json"
rm -rf "$NAME_TMP"

echo
echo "multi-hit disambiguation:"

# che-local-plugins 有兩份 manifest 自報同名：父層 che-claude-config 是 aggregator
# （source 指進子層、自己沒有 plugins/），子層才是實體 marketplace。候選必須自帶
# plugins/ —— 這條規則讓上面那條既有斷言（解析到子層）繼續成立。
CANDS=$(marketplace_candidates che-local-plugins)
assert_eq "candidates exclude the aggregator parent (no plugins/ of its own)" \
    "" \
    "$(printf '%s\n' "$CANDS" | grep -x "$HOME/Developer/che-claude-config" || true)"

# git worktree 帶著同一份 marketplace.json。選中它會讓 plugin-update 的 Phase 0.5
# git gate 跑在 worktree 上 —— 正是 #16 要防的「gate 跑在錯的 repo 上」換一條路徑進來。
assert_eq "candidates exclude git worktrees" \
    "" \
    "$(marketplace_candidates che-local-plugins | grep -c '_wt-' | sed 's/^0$//')"

# 契約與姊妹檔 resolve-mcp-project.sh 的 mcp_project_candidates 對齊：
# 讓 caller 與測試看得到 shadowing，而不是靠推測。
assert_eq "candidates are one per line, resolve_marketplace_root takes the first" \
    "$(marketplace_candidates che-plugin-devtools | head -1)" \
    "$(resolve_marketplace_root che-plugin-devtools)"

echo
echo "marketplace layout independence:"

# **不是每個 marketplace 都有 plugins/ 目錄。** 單一 plugin 的 marketplace（rush、
# che-keychain、che-ical-mcp…）就是 repo 本身，manifest 的 source 寫 `./plugin`（單數）。
# 消歧規則若當成全域准入條件用，會把這一整類全部砍掉 —— 那是把 #20 的覆蓋率缺口
# 換一個機制重新造出來。所以 plugins/ 只在**同名多候選**時當 tie-break。
LAYOUT_TMP=$(mktemp -d)
mkdir -p "$LAYOUT_TMP/solo/.claude-plugin" "$LAYOUT_TMP/solo/plugin"
cat > "$LAYOUT_TMP/solo/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-solo", "plugins": [ { "name": "fixture-solo", "source": "./plugin" } ] }
JSON
# 同名兩份：父層無 plugins/、子層有 —— tie-break 必須選子層
mkdir -p "$LAYOUT_TMP/agg/.claude-plugin" "$LAYOUT_TMP/agg/real/.claude-plugin" "$LAYOUT_TMP/agg/real/plugins"
cat > "$LAYOUT_TMP/agg/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-dup", "plugins": [ { "name": "x", "source": "./real/plugins/x" } ] }
JSON
cat > "$LAYOUT_TMP/agg/real/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-dup", "plugins": [ { "name": "x", "source": "./plugins/x" } ] }
JSON

SAVED_ROOT="$MARKETPLACE_SEARCH_ROOT"
MARKETPLACE_SEARCH_ROOT="$LAYOUT_TMP"

assert_eq "single-plugin marketplace (no plugins/ dir) resolves" \
    "$LAYOUT_TMP/solo" \
    "$(resolve_marketplace_root fixture-solo)"

assert_eq "single-plugin marketplace is listed" \
    "fixture-solo" \
    "$(list_marketplaces | grep -x fixture-solo)"

assert_eq "plugins/-bearing candidate wins when two declare the same name" \
    "$LAYOUT_TMP/agg/real" \
    "$(resolve_marketplace_root fixture-dup)"

MARKETPLACE_SEARCH_ROOT="$SAVED_ROOT"
rm -rf "$LAYOUT_TMP"

echo
echo "plugin dir resolution (#18) — source comes from the manifest, not a layout guess:"

# **plugin 在哪裡，manifest 已經寫了。** `plugins[].source` 是 marketplace schema 既有的
# 欄位；在 #18 之前 find_plugin_marketplace 從不讀它，只探測 `$root/plugins/<name>`
# 是否存在 —— 於是 `source: "./plugin"` 的單一 plugin marketplace 一律 rc=1，而
# plugin-update 的 Step 0.1 把它讀成「不在任何 marketplace」。
#
# 三個 rc 各有語意，消費端靠它們決定 abort 訊息：
#   0  entry 在、source 是相對路徑、目錄存在 → 印絕對 dir
#   1  manifest 沒有這個 entry
#   2  entry 在，但 source 不是相對路徑（github: / URL / 絕對路徑）或目錄不存在
PD_TMP=$(mktemp -d)
mkdir -p "$PD_TMP/solo/.claude-plugin" "$PD_TMP/solo/plugin"
cat > "$PD_TMP/solo/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-solo", "plugins": [ { "name": "pd-solo", "source": "./plugin" } ] }
JSON
mkdir -p "$PD_TMP/agg/.claude-plugin" "$PD_TMP/agg/plugins/x"
cat > "$PD_TMP/agg/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-agg",
  "plugins": [
    { "name": "x",        "source": "./plugins/x" },
    { "name": "ghost",    "source": "./plugins/ghost" },
    { "name": "remote",   "source": "github:someone/remote" },
    { "name": "absolute", "source": "/tmp/absolute" }
  ] }
JSON

SAVED_ROOT="$MARKETPLACE_SEARCH_ROOT"
MARKETPLACE_SEARCH_ROOT="$PD_TMP"

assert_eq "resolve_plugin_dir: ./plugin (single-plugin layout)" \
    "$PD_TMP/solo/plugin" \
    "$(resolve_plugin_dir "$PD_TMP/solo" pd-solo)"

assert_eq "resolve_plugin_dir: ./plugins/x (aggregator layout)" \
    "$PD_TMP/agg/plugins/x" \
    "$(resolve_plugin_dir "$PD_TMP/agg" x)"

resolve_plugin_dir "$PD_TMP/agg" nope >/dev/null 2>&1; RC_NOENTRY=$?
assert_eq "resolve_plugin_dir: no entry → rc 1" "1" "$RC_NOENTRY"

resolve_plugin_dir "$PD_TMP/agg" ghost >/dev/null 2>&1; RC_GHOST=$?
assert_eq "resolve_plugin_dir: entry present but dir missing → rc 2" "2" "$RC_GHOST"

resolve_plugin_dir "$PD_TMP/agg" remote >/dev/null 2>&1; RC_REMOTE=$?
assert_eq "resolve_plugin_dir: github: source → rc 2" "2" "$RC_REMOTE"

resolve_plugin_dir "$PD_TMP/agg" absolute >/dev/null 2>&1; RC_ABS=$?
assert_eq "resolve_plugin_dir: absolute source → rc 2" "2" "$RC_ABS"

assert_eq "find_plugin_marketplace: single-plugin layout yields name|root|plugin_dir" \
    "pd-solo|$PD_TMP/solo|$PD_TMP/solo/plugin" \
    "$(find_plugin_marketplace pd-solo)"

assert_eq "find_plugin_marketplace: aggregator layout yields name|root|plugin_dir" \
    "pd-agg|$PD_TMP/agg|$PD_TMP/agg/plugins/x" \
    "$(find_plugin_marketplace x)"

# entry 在但目錄不在：對 find_plugin_marketplace 是「不命中」（同名 plugin 可能在
# 另一個 checkout 是完整的），不是「命中一個壞路徑」。
assert_fails "find_plugin_marketplace: entry whose dir is missing is not a hit" \
    find_plugin_marketplace ghost

PD_NOISE=$( { resolve_plugin_dir "$PD_TMP/agg" ghost; resolve_plugin_dir "$PD_TMP/agg" nope; \
              find_plugin_marketplace pd-solo; find_plugin_marketplace ghost; } 2>&1 >/dev/null )
assert_eq "plugin dir resolution emits no stderr" "" "$PD_NOISE"

MARKETPLACE_SEARCH_ROOT="$SAVED_ROOT"
rm -rf "$PD_TMP"

echo
echo "bash 3.2 compatibility:"
# The whole point: this file must be sourceable by macOS system bash with no
# stderr noise. `local -n` would emit "invalid option" here.
NOISE=$(/bin/bash -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && resolve_marketplace_root che-plugin-devtools >/dev/null" 2>&1)
assert_eq "sourcing under /bin/bash emits no stderr" "" "$NOISE"

echo
echo "zsh compatibility (#16):"
# **這一節是這個 bug 活下來的原因的補救。** 先前整份測試只跑 bash，而這個檔案是被
# `source` 的——跑它的是呼叫端的 shell，`#!/bin/bash` 不生效。Claude Code 的 Bash
# 工具跑在 zsh，而 zsh 預設不對 unquoted 變數做 word-split，於是
# `for mp in $MARKETPLACE_NAMES` 只迭代一次（整個字串當一個項目），
# `find_plugin_marketplace` 對**每一個** plugin 都回 rc=1。
#
# 破壞實作確認過會紅：把 MARKETPLACE_NAMES 改回空白分隔 + `for mp in $VAR`，
# 下面兩條在 zsh 那邊會失敗（bash 那邊仍然全綠——那正是重點）。
if command -v zsh >/dev/null 2>&1; then
  ZSH_HIT=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && find_plugin_marketplace harness-devtools" 2>/dev/null)
  assert_eq "sourcing under zsh finds harness-devtools (three fields)" \
    "che-plugin-devtools|$HOME/Developer/che-plugin-devtools|$HOME/Developer/che-plugin-devtools/plugins/harness-devtools" \
    "$ZSH_HIT"

  ZSH_COUNT=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && list_marketplaces | wc -l" 2>/dev/null | tr -d ' ')
  BASH_COUNT=$(list_marketplaces | wc -l | tr -d ' ')
  assert_eq "list_marketplaces yields the same count under zsh and bash" \
    "$BASH_COUNT" "$ZSH_COUNT"

  ZSH_NOISE=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && resolve_marketplace_root che-plugin-devtools >/dev/null" 2>&1)
  assert_eq "sourcing under zsh emits no stderr" "" "$ZSH_NOISE"
else
  echo "  ⊘ zsh not on PATH — skipped (這台機器不是 macOS 預設環境?)"
fi

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
