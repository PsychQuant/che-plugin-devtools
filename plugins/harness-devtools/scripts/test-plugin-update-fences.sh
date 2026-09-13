#!/bin/bash
# Smoke tests for the bash fences in skills/plugin-update/SKILL.md.
#
# Run: bash scripts/test-plugin-update-fences.sh
#
# The fences are executed by the agent through the Bash tool, which on this
# machine is zsh (nomatch on, eval'd). A glob that matches nothing is not a
# failed command there — it aborts the whole fence (#18 verify R7: gifthub and
# che-keychain, plugins without bin/*-wrapper.sh, never reached the line that
# prints IS_BINARY_BACKED / Case X). So every fence below is run under BOTH
# bash and zsh, against a fixture marketplace, and the assertion is on the
# fence's own decision line — not on "it did not crash".
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/plugin-update/SKILL.md"
PASS=0; FAIL=0
assert_contains() {   # desc needle haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then PASS=$((PASS+1)); echo "  ✓ $1"
  else FAIL=$((FAIL+1)); echo "  ✗ $1"; printf '%s\n' "$3" | sed 's/^/      | /' | head -20; fi
}

# ---- fixture: one marketplace, one CLI-style binary-backed plugin WITHOUT bin/ ----
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export MARKETPLACE_SEARCH_ROOT="$T/dev" XDG_STATE_HOME="$T/state" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
mkdir -p "$T/dev/fx-mp/.claude-plugin" "$T/dev/fx-mp/plugins/nobin/.claude-plugin" "$T/dev/fx-mp/plugins/nobin/hooks" "$T/dev/fx-mp/plugins/nobin/skills/s" "$T/dev/fx-mp/plugins/nobin/skills/t"
cat > "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fx-mp", "plugins": [ { "name": "nobin", "version": "1.0.0", "source": "./plugins/nobin" } ] }
JSON
printf '{ "name": "nobin", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/nobin/.claude-plugin/plugin.json"
printf '#!/bin/sh\ncurl -s https://api.github.com/repos/x/y/releases/latest\n' > "$T/dev/fx-mp/plugins/nobin/hooks/session-start.sh"
printf '# s\n' > "$T/dev/fx-mp/plugins/nobin/skills/s/SKILL.md"; printf '# t\n' > "$T/dev/fx-mp/plugins/nobin/skills/t/SKILL.md"   # TWO skills: zsh's non-splitting `for x in $VAR` only shows with a multi-line list
( cd "$T/dev/fx-mp" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init ) 2>/dev/null
# a PURE-SHELL plugin (no .mcp.json / bin / session-start / binary pin), committed with an OLD date so it is
# "dormant" (no commits in 30 days): #19 makes Phase 0.3 run for it too, and the clean-start / dirty / drift
# scenarios must resolve as the decision table says
mkdir -p "$T/dev/fx-mp/plugins/pure/.claude-plugin" "$T/dev/fx-mp/plugins/pure/skills/p"
printf '{ "name": "pure", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
printf '# p\n' > "$T/dev/fx-mp/plugins/pure/skills/p/SKILL.md"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"pure","version":"1.0.0","source":"./plugins/pure"}); json.dump(d,open(p,'w'))
PY
( cd "$T/dev/fx-mp" && git add -A && GIT_AUTHOR_DATE=2024-01-01T00:00:00 GIT_COMMITTER_DATE=2024-01-01T00:00:00 git -c user.name=t -c user.email=t@t commit -qm pure-old ) 2>/dev/null
# an upstream, so Phase 0.5 Step 5 (needs @{u}) can run: bare remote + one unpushed commit touching nobin
git init -q --bare "$T/remote.git" && ( cd "$T/dev/fx-mp" && git remote add origin "$T/remote.git" && git push -q -u origin HEAD 2>/dev/null \
  && printf '# more\n' >> plugins/nobin/skills/s/SKILL.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm touch-nobin ) 2>/dev/null

# ---- fence extraction: the Nth ```bash fence containing a marker ----
fence_with() {   # marker → fence body on stdout
  python3 - "$SKILL" "$1" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
for b in re.findall(r'```bash\n(.*?)```', s, re.S):
    if sys.argv[2] in b:
        sys.stdout.write(b); break
PY
}
prep() {   # marker plugin → script path
  fence_with "$1" | sed "s/^PLUGIN_NAME='<plugin-name>'/PLUGIN_NAME='$2'/; s/^MP_NAME='<marketplace-name-or-empty>'/MP_NAME=''/" > "$T/fence.sh"
  printf '%s\n' "$T/fence.sh"
}
run_both() {   # desc marker plugin needle
  local f; f=$(prep "$2" "$3")
  local out_b out_z
  out_b=$(cd "$T" && bash "$f" 2>&1); out_z=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)   # the Bash tool eval-s the fence text in zsh; a script file behaves differently on nomatch
  assert_contains "$1 (bash)" "$4" "$out_b"
  assert_contains "$1 (zsh)"  "$4" "$out_z"
  if printf "%s" "$out_z" | grep -q "no matches found"; then FAIL=$((FAIL+1)); echo "  ✗ $1: a glob matched nothing under zsh (fatal in the Bash tool)"; else PASS=$((PASS+1)); echo "  ✓ $1: no unmatched glob under zsh"; fi
}

echo "Step 0.1:"
run_both "Step 0.1 resolves the fixture plugin" 'plugin_holders "$PLUGIN_NAME" "$WANT_MP"' nobin "→ Step 0.1 OK: marketplace=fx-mp"
echo
echo "Phase 0.3 Step 1 (no bin/ directory — the glob must not abort the fence):"
run_both "Step 1 prints its decision" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' nobin "IS_BINARY_BACKED=true"
echo
echo "Phase 0.3 Step 2:"
run_both "Step 2 prints the Case line" 'BINARY_UNKNOWN_WHY' nobin "→ Phase 0.3 sync intent: Case "
run_both "Step 2 sees the session-start signal → unknown/no-pin" 'BINARY_UNKNOWN_WHY' nobin "why=no-pin"
echo
echo "Phase 1.5 Step 2 (no wrapper — the for-loop glob must not abort the fence):"
run_both "Step 2 reaches its end" 'for wrapper in' nobin "→ Phase 1.5 Step 2: wrappers checked"

echo
echo "Phase 0.5 Step 5 (cross-plugin gate must print a conclusion; runs before any push):"
run_both "Step 5 counts the unpushed commit touching nobin" 'UNRESOLVED_NAMES=' nobin "→ Phase 0.5 Step 5: 1 plugin(s) touched by 1 unpushed commit(s): nobin"
echo
echo "Phase 0.3 for a PURE-SHELL plugin (#19): clean + synced + dormant → Case A; dirty tree → Case C; drift → Case C"
run_both "pure: Step 0.1 resolves" 'plugin_holders "$PLUGIN_NAME" "$WANT_MP"' pure "→ Step 0.1 OK: marketplace=fx-mp"
run_both "pure: Step 1 says not binary-backed (all four signals miss)" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' pure "IS_BINARY_BACKED=false"
prep01() { fence_with 'plugin_holders "$PLUGIN_NAME" "$WANT_MP"' | sed "s/^PLUGIN_NAME='<plugin-name>'/PLUGIN_NAME='$1'/; s/^MP_NAME='<marketplace-name-or-empty>'/MP_NAME=''/" > "$T/fence01.sh"; (cd "$T" && bash "$T/fence01.sh" >/dev/null 2>&1); }   # Phase 0.3 Case A removes the context; re-arm it (own file: must not clobber $T/fence.sh)
prep01 pure; f=$(prep 'BINARY_UNKNOWN_WHY' pure); assert_contains "pure: clean + synced + dormant → Case A (bash)" "→ Phase 0.3 sync intent: Case A" "$(cd "$T" && bash "$f" 2>&1)"
prep01 pure; assert_contains "pure: clean + synced + dormant → Case A (zsh)" "→ Phase 0.3 sync intent: Case A" "$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)"
printf '# edited, not committed\n' >> "$T/dev/fx-mp/plugins/pure/skills/p/SKILL.md"
prep01 pure
run_both "pure: uncommitted edit under the plugin dir → Case C (not the false 'no changes' abort)" 'BINARY_UNKNOWN_WHY' pure "→ Phase 0.3 sync intent: Case C"
run_both "pure: …and the Case C summary names the uncommitted paths" 'BINARY_UNKNOWN_WHY' pure "uncommitted changes under the plugin dir / marketplace.json: 1 status entries"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/pure/skills/p/SKILL.md )
printf '{ "name": "pure", "version": "1.0.1" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
( cd "$T/dev/fx-mp" && git add -A && GIT_AUTHOR_DATE=2024-01-02T00:00:00 GIT_COMMITTER_DATE=2024-01-02T00:00:00 git -c user.name=t -c user.email=t@t commit -qm pure-bump-old ) 2>/dev/null
prep01 pure
run_both "pure: plugin.json bumped (old commit) but marketplace.json not mirrored → drift → Case C" 'BINARY_UNKNOWN_WHY' pure "drift=yes"
echo
echo "Phase 0.3 for pure: an unpushed commit touching the plugin (older than 30 days, tree clean, versions in sync) → Case C, not Case A"
printf '{ "name": "pure", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"   # back in sync with marketplace.json
( cd "$T/dev/fx-mp" && git add -A && GIT_AUTHOR_DATE=2024-01-03T00:00:00 GIT_COMMITTER_DATE=2024-01-03T00:00:00 git -c user.name=t -c user.email=t@t commit -qm pure-resync-old ) 2>/dev/null
prep01 pure
run_both "pure: dormant + clean + synced but UNPUSHED plugin commits → Case C (unpushed_here>0)" 'BINARY_UNKNOWN_WHY' pure "→ Phase 0.3 sync intent: Case C"
echo
echo "Phase 0.5 Case A (the fence VERIFIES clean + 0 unpushed; misclassification is refused):"
prep01 pure
f=$(prep 'nothing to gate; Phase 2 will mirror' pure)
assert_contains "Case A with unpushed commits present is refused (bash)" "這不是 Case A" "$(cd "$T" && bash "$f" 2>&1)"
assert_contains "Case A with unpushed commits present is refused (zsh)" "這不是 Case A" "$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)"
( cd "$T/dev/fx-mp" && git push -q 2>/dev/null )   # now genuinely clean + 0 unpushed
run_both "Case A on a truly clean tree prints the verified pass-through line" 'nothing to gate; Phase 2 will mirror' pure "0 pre-existing unpushed commits (verified)"
if [ -f "$T/state/harness-devtools/plugin-update-ctx-pure" ]; then PASS=$((PASS+1)); echo "  ✓ Case A keeps the context file"; else FAIL=$((FAIL+1)); echo "  ✗ Case A keeps the context file"; fi
echo
echo "Phase 2 Step 4 (version verified; mirror commit only when marketplace.json changed):"
run_both "Phase 2 Step 4 with an in-sync marketplace.json prints the skip line instead of failing" 'MP_NOW=$(python3 -c' nobin "→ Phase 2: marketplace.json 已與 plugin.json 同步"
printf '{ "name": "pure", "version": "1.0.2" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm pure-bump ) 2>/dev/null
prep01 pure
run_both "Phase 2 Step 4 with drift but the Edit NOT applied aborts instead of claiming sync" 'MP_NOW=$(python3 -c' pure "Step 2 / Step 3 的 Edit 沒落地"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for e in d['plugins']:
    if e['name']=='pure': e['version']='1.0.2'
json.dump(d,open(p,'w'))
PY
f=$(prep 'MP_NOW=$(python3 -c' pure)
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "Phase 2 Step 4 with the Edit applied commits and pushes to the upstream" "committed and pushed to origin/" "$OUT"
assert_contains "…and lists the extra commit that appeared after Phase 0.5 (pure-bump)" "pure-bump" "$OUT"
REMOTE_HEAD=$(cd "$T/dev/fx-mp" && git rev-parse '@{u}' 2>/dev/null); LOCAL_HEAD=$(cd "$T/dev/fx-mp" && git rev-parse HEAD)
if [ -n "$REMOTE_HEAD" ] && [ "$REMOTE_HEAD" = "$LOCAL_HEAD" ]; then PASS=$((PASS+1)); echo "  ✓ the tracked upstream ref now equals HEAD (pushed to the right ref)"; else FAIL=$((FAIL+1)); echo "  ✗ the tracked upstream ref now equals HEAD"; fi
echo
echo "Phase 1.5 Step 3 (CLI, hook present but no \$HOME/bin/<name> line → must say so, not stay silent):"
run_both "Step 3 reports what it could not extract" 'HOOK="$PLUGIN_DIR/hooks/session-start.sh"' nobin "判定不出"
echo
echo "Phase 2.5 (README missing a component → stale; complete README → fresh; loops must iterate under zsh):"
printf '# nobin\n\nv1.0.0 — `s`\n' > "$T/dev/fx-mp/plugins/nobin/README.md"   # mentions s, never t
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm readme ) 2>/dev/null
run_both "README that mentions s but never t is STALE (signal-4 must iterate both)" 'GIT_OK=true' nobin "signal-4: README missing 1 components: skill:t"
run_both "…and the conclusion line says stale" 'GIT_OK=true' nobin "→ Phase 2.5: README stale"
printf '# nobin\n\nv1.0.0 — `s` `t`\n' > "$T/dev/fx-mp/plugins/nobin/README.md"
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm readme2 ) 2>/dev/null
run_both "README mentioning every component and the version is FRESH (with the unevaluated signals named)" 'GIT_OK=true' nobin "✅ Phase 2.5: README fresh（已評估的信號通過；未評估： 3(無 CHANGELOG.md) 5(無 tool count 可比) 6(無 Version History 或無 git)）"
rm "$T/dev/fx-mp/plugins/nobin/README.md"
run_both "missing README is reported as its own state" 'GIT_OK=true' nobin "沒有 README.md"
echo
echo "plugin-debug version query (root-level manifest lookup):"
SKILL="$PLUGIN_ROOT/skills/plugin-debug/SKILL.md"
run_both "plugin-debug reads the version through plugin_manifest_path" 'plugin_manifest_path "$SRC"' nobin "1.0.0"

echo; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
