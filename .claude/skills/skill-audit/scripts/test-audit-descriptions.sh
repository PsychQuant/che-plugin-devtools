#!/bin/bash
# Tests for audit-descriptions.sh
#
# Run: bash .claude/skills/skill-audit/scripts/test-audit-descriptions.sh
# Exit 0 = all pass, 1 = any failure.
#
# Two layers:
#   1. Fixture tests — synthetic skills with KNOWN description lengths. These pin
#      the classification boundaries and stay green forever (fixtures never change).
#   2. Smoke test — runs against this repo's real skills. Asserts the script
#      completes and emits well-formed output, but deliberately does NOT assert
#      specific counts: the whole point of this tool is that those counts should
#      drop to zero as #5 progresses. A test that asserts "12 undersized" would
#      have to be edited every time someone fixes a skill — it would punish the
#      exact work it is meant to support.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/audit-descriptions.sh"
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
       echo "      expected to contain: '$needle'" ;;
  esac
}

# Build a fixture skill with a description of an exact character count.
# $1 = skills root, $2 = skill name, $3 = desc char count, $4 = body line count
make_fixture() {
  local root="$1" name="$2" desc_len="$3" body_lines="$4"
  mkdir -p "$root/$name"
  local desc
  desc=$(head -c "$desc_len" < /dev/zero | tr '\0' 'x')
  {
    echo "---"
    echo "name: $name"
    echo "description: $desc"
    echo "---"
    echo
    local i=0
    while [ "$i" -lt "$body_lines" ]; do echo "body line $i"; i=$((i + 1)); done
  } > "$root/$name/SKILL.md"
}

# ---------------------------------------------------------------------------

echo "fixture classification:"
FIX="$TMPROOT/fixtures"
mkdir -p "$FIX"
make_fixture "$FIX" tiny-desc      29  50    # well under floor
make_fixture "$FIX" just-under     99  50    # boundary: floor is 100
make_fixture "$FIX" at-floor      100  50    # boundary: exactly at floor → ok
make_fixture "$FIX" healthy       400  50    # comfortably ok
make_fixture "$FIX" long-body     400 900    # ok desc, body over line ceiling
make_fixture "$FIX" over-cap     1600  50    # over the 1536 per-entry cap

OUT=$(bash "$AUDIT" --skills-root "$FIX" --format tsv 2>&1)

field() {  # $1 = skill name, $2 = column index (1-based)
  echo "$OUT" | awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c }'
}

assert_eq "tiny-desc (29) → undersized"    "undersized" "$(field tiny-desc 4)"
assert_eq "just-under (99) → undersized"   "undersized" "$(field just-under 4)"
assert_eq "at-floor (100) → ok"            "ok"         "$(field at-floor 4)"
assert_eq "healthy (400) → ok"             "ok"         "$(field healthy 4)"
assert_eq "over-cap (1600) → over-cap"     "over-cap"   "$(field over-cap 4)"
assert_eq "desc length reported verbatim"  "29"         "$(field tiny-desc 2)"
assert_eq "body lines reported"            "905"        "$(field long-body 3)"
assert_eq "long-body desc still ok"        "ok"         "$(field long-body 4)"
assert_eq "long-body flagged oversized"    "yes"        "$(field long-body 5)"
assert_eq "healthy body not flagged"       "no"         "$(field healthy 5)"

echo
echo "exit code signals actionable findings:"
bash "$AUDIT" --skills-root "$FIX" --format tsv >/dev/null 2>&1
assert_eq "non-zero when findings exist" "1" "$?"

CLEAN="$TMPROOT/clean"
mkdir -p "$CLEAN"
make_fixture "$CLEAN" fine-one 300 100
make_fixture "$CLEAN" fine-two 500 200
bash "$AUDIT" --skills-root "$CLEAN" --format tsv >/dev/null 2>&1
assert_eq "zero when everything passes" "0" "$?"

echo
echo "edge cases:"
EDGE="$TMPROOT/edge"
mkdir -p "$EDGE/no-frontmatter"
printf '# Just a heading\n\nno frontmatter here\n' > "$EDGE/no-frontmatter/SKILL.md"
mkdir -p "$EDGE/empty-dir"
OUT_EDGE=$(bash "$AUDIT" --skills-root "$EDGE" --format tsv 2>&1)
assert_contains "missing frontmatter → no-description" "no-description" "$OUT_EDGE"
assert_eq "dir without SKILL.md is skipped" "" \
  "$(echo "$OUT_EDGE" | awk -F'\t' '$1 == "empty-dir" { print $1 }')"

assert_eq "nonexistent root exits 2" "2" \
  "$(bash "$AUDIT" --skills-root "$TMPROOT/does-not-exist" >/dev/null 2>&1; echo $?)"

echo
echo "smoke test against this repo (no hardcoded counts — see header):"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
if [ -d "$REPO_ROOT/plugins" ]; then
  REAL=$(bash "$AUDIT" --repo "$REPO_ROOT" --format table 2>&1)
  assert_contains "report has a header row"      "description" "$REAL"
  assert_contains "finds devtools mcp-deploy"    "mcp-deploy"  "$REAL"
  assert_contains "finds doc-guardian skills"    "changelog-validate" "$REAL"
  assert_contains "emits a summary line"         "SUMMARY"     "$REAL"
  # Every emitted verdict must be one of the known enum values — guards against
  # a future refactor silently introducing an unhandled state.
  BAD=$(bash "$AUDIT" --repo "$REPO_ROOT" --format tsv 2>/dev/null \
        | awk -F'\t' 'NR>1 && $4 !~ /^(undersized|ok|over-cap|no-description)$/ { print $4 }' | sort -u)
  assert_eq "no unknown verdicts in real data" "" "$BAD"
else
  echo "  (skipped — repo layout not found)"
fi

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
