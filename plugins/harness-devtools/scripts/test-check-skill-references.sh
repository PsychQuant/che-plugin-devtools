#!/bin/bash
# Tests for check-skill-references.sh
#
# Run: bash plugins/harness-devtools/scripts/test-check-skill-references.sh
# Exit 0 = all pass, 1 = any failure.
#
# 每個 case 都建一個合成的迷你 repo。這比對真 repo 斷言重要 —— 對真 repo 只能
# 斷言「現在是乾淨的」，而那句話在修完之後恆真，證明不了偵測邏輯還活著。
# fixture 反過來 pin 住「壞的會被抓到」，那才是這支腳本存在的理由。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-skill-references.sh"
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
       echo "      actual: $haystack" ;;
  esac
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL + 1)); echo "  ✗ $desc"
                 echo "      should NOT contain: '$needle'" ;;
    *) PASS=$((PASS + 1)); echo "  ✓ $desc" ;;
  esac
}

# 建一個含單一 plugin + 單一 skill 的迷你 repo
make_repo() {
  local root="$1"
  mkdir -p "$root/plugins/demo/skills/real-skill"
  echo "# real" > "$root/plugins/demo/skills/real-skill/SKILL.md"
}

run_check() { bash "$CHECK" --repo "$1" --format tsv 2>&1; }

# ---------------------------------------------------------------------------

echo "detects broken references:"

R="$TMPROOT/missing"; make_repo "$R"
printf 'See /demo:no-such-skill for details.\n' > "$R/plugins/demo/README.md"
OUT=$(run_check "$R")
assert_contains "指向不存在的 skill → missing-skill" "missing-skill" "$OUT"
assert_contains "  並指出是哪一個" "/demo:no-such-skill" "$OUT"

R="$TMPROOT/retired"; make_repo "$R"
printf 'Run /mcp-tools:mcp-deploy to publish.\n' > "$R/plugins/demo/README.md"
OUT=$(run_check "$R")
assert_contains "退役前綴 → retired-prefix" "retired-prefix" "$OUT"

echo
echo "respects intentional references:"

R="$TMPROOT/phase2"; make_repo "$R"
printf '| /demo:future-skill | Phase 2 — not implemented |\n' > "$R/plugins/demo/README.md"
OUT=$(run_check "$R")
assert_not_contains "同行標 Phase 2 → 跳過" "future-skill" "$OUT"

R="$TMPROOT/historical"; make_repo "$R"
printf '此處刻意保留舊的 /mcp-tools:mcp-deploy 以說明合併前的失效情境。\n' \
  > "$R/plugins/demo/README.md"
OUT=$(run_check "$R")
assert_not_contains "同行標刻意保留 → 跳過" "retired-prefix" "$OUT"

R="$TMPROOT/changelog"; make_repo "$R"
printf '## [1.0.0]\n- 呼叫方式由 /changelog-tools:foo 改為 /demo:real-skill\n' \
  > "$R/plugins/demo/CHANGELOG.md"
OUT=$(run_check "$R")
assert_not_contains "CHANGELOG.md 整份跳過（歷史記錄不可竄改）" "changelog-tools" "$OUT"

R="$TMPROOT/external"; make_repo "$R"
printf 'First run /superpowers:brainstorming, then /spectra:propose.\n' \
  > "$R/plugins/demo/README.md"
OUT=$(run_check "$R")
assert_not_contains "外部 plugin 引用不誤報（本 repo 無從驗證）" "superpowers" "$OUT"

# 測試檔必然含壞引用當 fixture —— 而那無法用豁免字樣解決：驗證「沒有豁免字樣
# 就會被抓」的 case，本體必須是一個不帶豁免字樣的壞引用。所以掃描器排除 test-*。
R="$TMPROOT/testfile"; make_repo "$R"
printf 'fixture: /mcp-tools:mcp-deploy and /demo:ghost\n' > "$R/plugins/demo/test-thing.sh"
OUT=$(run_check "$R")
assert_not_contains "test-* 檔案跳過（fixture 是資料，不是引用）" "test-thing" "$OUT"

echo
echo "exit codes:"

R="$TMPROOT/clean"; make_repo "$R"
printf 'Use /demo:real-skill to do the thing.\n' > "$R/plugins/demo/README.md"
bash "$CHECK" --repo "$R" >/dev/null 2>&1
assert_eq "全部解析得到 → exit 0" "0" "$?"

R="$TMPROOT/dirty"; make_repo "$R"
printf 'Use /demo:ghost-skill.\n' > "$R/plugins/demo/README.md"
bash "$CHECK" --repo "$R" >/dev/null 2>&1
assert_eq "有失效引用 → exit 1" "1" "$?"

bash "$CHECK" --repo "$TMPROOT/does-not-exist" >/dev/null 2>&1
assert_eq "路徑不存在 → exit 2" "2" "$?"

echo
echo "scans all three file types:"
for ext in md sh py; do
  R="$TMPROOT/ext-$ext"; make_repo "$R"
  printf 'ref /demo:ghost-%s here\n' "$ext" > "$R/plugins/demo/thing.$ext"
  OUT=$(run_check "$R")
  assert_contains "  .$ext 被掃到" "ghost-$ext" "$OUT"
done

echo
echo "against this repo (must stay clean — that IS the deliverable of #1):"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ -d "$REPO_ROOT/plugins" ]; then
  bash "$CHECK" --repo "$REPO_ROOT" >/dev/null 2>&1
  assert_eq "本 repo 零失效引用" "0" "$?"
else
  echo "  (skipped — repo layout not found)"
fi

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
