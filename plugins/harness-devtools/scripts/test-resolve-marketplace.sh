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
COUNT=$(list_marketplaces | grep -c .)
assert_eq "lists 4 marketplaces" "4" "$COUNT"

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
assert_eq "finds harness-devtools in che-plugin-devtools" \
  "che-plugin-devtools|$HOME/Developer/che-plugin-devtools" \
  "$(find_plugin_marketplace harness-devtools)"

assert_fails "unknown plugin returns non-zero" \
  find_plugin_marketplace definitely-not-a-real-plugin

assert_fails "empty plugin name returns non-zero" \
  find_plugin_marketplace ""

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
  assert_eq "sourcing under zsh finds harness-devtools" \
    "che-plugin-devtools|$HOME/Developer/che-plugin-devtools" \
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
