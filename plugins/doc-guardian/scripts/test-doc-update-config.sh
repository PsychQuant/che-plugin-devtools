#!/bin/bash
# Unit tests for doc-update-config.sh
#
# Run: bash scripts/test-doc-update-config.sh
# Exit 0 = all pass, 1 = any failure.
#
# The headline case is "config override actually takes effect". Under doc-tools
# 0.2.0 the code_extensions / doc_files overrides were silently dropped on macOS
# because `local -n` does not exist in bash 3.2 — the config file parsed fine,
# the hook ran fine, and the setting just never applied. These tests would have
# caught that, so they exist now.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "  ✓ $desc" ;;
    *) FAIL=$((FAIL + 1)); echo "  ✗ $desc"
       echo "      expected to contain: '$needle'"
       echo "      actual:              '$haystack'" ;;
  esac
}

# Run a snippet in a clean /bin/bash with HOME pointed at a scratch dir, so the
# developer's real ~/.cache/doc-guardian never leaks into the results.
run_isolated() {
  local project_dir="$1" snippet="$2"
  HOME="$TMPROOT/fakehome" /bin/bash -c "
    source '$SCRIPT_DIR/doc-update-config.sh'
    load_doc_guardian_config '$project_dir'
    $snippet
  " 2>&1
}

mkdir -p "$TMPROOT/fakehome"

# ---------------------------------------------------------------------------

echo "defaults:"
assert_eq "CFG_ENABLED defaults true" "true" \
  "$(run_isolated "" 'echo "$CFG_ENABLED"')"
assert_eq "CFG_MIN_CHANGED_FILES defaults 3" "3" \
  "$(run_isolated "" 'echo "$CFG_MIN_CHANGED_FILES"')"
assert_eq "CFG_CLAUDE_MD_MIN_FILES defaults 2" "2" \
  "$(run_isolated "" 'echo "$CFG_CLAUDE_MD_MIN_FILES"')"
assert_eq "CFG_WIKI_SYNC_ENABLED defaults true" "true" \
  "$(run_isolated "" 'echo "$CFG_WIKI_SYNC_ENABLED"')"
assert_contains "code regex carries default extensions" "swift" \
  "$(run_isolated "" 'echo "$CFG_CODE_EXTENSIONS_REGEX"')"
assert_contains "arch regex carries r_pkg default" "r_pkg" \
  "$(run_isolated "" 'echo "$CFG_ARCH_PATTERNS_REGEX"')"

echo
echo "bash 3.2 compatibility (the nameref regression):"
NOISE=$(HOME="$TMPROOT/fakehome" /bin/bash -c "source '$SCRIPT_DIR/doc-update-config.sh' && load_doc_guardian_config '' >/dev/null" 2>&1)
assert_eq "no stderr under /bin/bash 3.2" "" "$NOISE"

echo
echo "per-project override ACTUALLY APPLIES (was silently dropped pre-fix):"
PROJ="$TMPROOT/proj"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/.claude/doc-guardian.json" <<'JSON'
{
  "min_changed_files": 7,
  "code_extensions": ["lean", "agda"],
  "doc_files": ["NOTES.md"],
  "claude_md": { "min_files": 5, "arch_patterns": ["^infra/", "flake\\.nix"] },
  "wiki_sync": { "enabled": false, "changelog_dir": "history/" }
}
JSON

assert_eq "min_changed_files overridden" "7" \
  "$(run_isolated "$PROJ" 'echo "$CFG_MIN_CHANGED_FILES"')"
assert_eq "code_extensions fully replaced" '\.(lean|agda)$' \
  "$(run_isolated "$PROJ" 'echo "$CFG_CODE_EXTENSIONS_REGEX"')"
assert_eq "default extensions gone after replace" "0" \
  "$(run_isolated "$PROJ" 'echo "$CFG_CODE_EXTENSIONS_REGEX" | grep -c swift')"
assert_eq "doc_files fully replaced" '(NOTES\.md)' \
  "$(run_isolated "$PROJ" 'echo "$CFG_DOC_FILES_REGEX"')"
assert_eq "claude_md.min_files overridden" "5" \
  "$(run_isolated "$PROJ" 'echo "$CFG_CLAUDE_MD_MIN_FILES"')"
assert_eq "claude_md.arch_patterns overridden" '^infra/|flake\.nix' \
  "$(run_isolated "$PROJ" 'echo "$CFG_ARCH_PATTERNS_REGEX"')"
assert_eq "wiki_sync.enabled=false survives (not swallowed as absent)" "false" \
  "$(run_isolated "$PROJ" 'echo "$CFG_WIKI_SYNC_ENABLED"')"
assert_eq "wiki_sync.changelog_dir overridden" "^history/" \
  "$(run_isolated "$PROJ" 'echo "$CFG_CHANGELOG_DIR_REGEX"')"

echo
echo "legacy doc-tools.json fallback:"
LEG="$TMPROOT/legacy"
mkdir -p "$LEG/.claude"
echo '{"min_changed_files": 9}' > "$LEG/.claude/doc-tools.json"
assert_eq "legacy filename still honored" "9" \
  "$(run_isolated "$LEG" 'echo "$CFG_MIN_CHANGED_FILES"')"

BOTH="$TMPROOT/both"
mkdir -p "$BOTH/.claude"
echo '{"min_changed_files": 9}'  > "$BOTH/.claude/doc-tools.json"
echo '{"min_changed_files": 11}' > "$BOTH/.claude/doc-guardian.json"
assert_eq "doc-guardian.json wins over doc-tools.json" "11" \
  "$(run_isolated "$BOTH" 'echo "$CFG_MIN_CHANGED_FILES"')"

echo
echo "kill switch:"
mkdir -p "$TMPROOT/fakehome/.cache/doc-guardian"
touch "$TMPROOT/fakehome/.cache/doc-guardian/disabled"
assert_eq "new-path disabled flag detected" "DISABLED" \
  "$(HOME="$TMPROOT/fakehome" /bin/bash -c "source '$SCRIPT_DIR/doc-update-config.sh'; is_doc_guardian_disabled && echo DISABLED || echo ACTIVE")"
rm "$TMPROOT/fakehome/.cache/doc-guardian/disabled"

mkdir -p "$TMPROOT/fakehome/.cache/doc-tools"
touch "$TMPROOT/fakehome/.cache/doc-tools/disabled"
assert_eq "legacy-path disabled flag still detected" "DISABLED" \
  "$(HOME="$TMPROOT/fakehome" /bin/bash -c "source '$SCRIPT_DIR/doc-update-config.sh'; is_doc_guardian_disabled && echo DISABLED || echo ACTIVE")"
rm "$TMPROOT/fakehome/.cache/doc-tools/disabled"

echo
echo "back-compat aliases:"
assert_eq "load_doc_tools_config still callable" "3" \
  "$(HOME="$TMPROOT/fakehome" /bin/bash -c "source '$SCRIPT_DIR/doc-update-config.sh'; load_doc_tools_config ''; echo \$CFG_MIN_CHANGED_FILES" 2>&1)"

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
