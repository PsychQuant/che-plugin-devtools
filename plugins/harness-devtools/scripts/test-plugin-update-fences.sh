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
HARNESS_MISSING=$(mktemp "${TMPDIR:-/tmp}/pbm-harness-missing.XXXXXX")
# bash runs command_not_found_handle in a separate environment, so it records into a file the summary counts (#22 verify R9:
# a helper called before its definition skipped an assertion silently while the run still printed 358/358)
command_not_found_handle() { printf '%s\n' "$1" >> "$HARNESS_MISSING"; echo "  ✗ harness: command not found: $1" >&2; return 127; }
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
run_both "Step 2: hook-only, no bin/ wrapper → no pin (R3: no plugin-wide version fallback) → unknown/no-pin" 'BINARY_UNKNOWN_WHY' nobin "binary=none pinsrc=none unreleased=unknown why=no-pin"
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
run_both_ctx() {   # like run_both, but the fence ENDS the invocation (remove_plugin_ctx) — re-arm Step 0.1 before each shell
  local f; f=$(prep "$2" "$3"); local out_b out_z
  prep01 "$3"; out_b=$(cd "$T" && bash "$f" 2>&1); prep01 "$3"; out_z=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
  assert_contains "$1 (bash)" "$4" "$out_b"; assert_contains "$1 (zsh)" "$4" "$out_z"
  if printf "%s" "$out_z" | grep -q "no matches found"; then FAIL=$((FAIL+1)); echo "  ✗ $1: a glob matched nothing under zsh (fatal in the Bash tool)"; else PASS=$((PASS+1)); echo "  ✓ $1: no unmatched glob under zsh"; fi
}
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
run_both "Case A on a truly clean tree prints the verified pass-through line" 'nothing to gate; Phase 2 will mirror' pure "divergence 0 0 (verified)"
# pure BEHIND (upstream ahead by one): Case A must refuse (that is E')
( cd "$T/dev/fx-mp" && git reset -q --hard HEAD~1 )
f=$(prep 'nothing to gate; Phase 2 will mirror' pure)
assert_contains "Case A on a clean but BEHIND tree is refused (E', not A)" "behind: 1" "$(cd "$T" && bash "$f" 2>&1)"
( cd "$T/dev/fx-mp" && git pull -q --ff-only 2>/dev/null )
# a branch with no upstream: Phase 0.3 Step 2 must abort, not print 'no unpushed commit'
( cd "$T/dev/fx-mp" && git checkout -q -b no-upstream )
prep01 pure
run_both "Phase 0.3 Step 2 on a branch without upstream aborts instead of asserting 'no unpushed'" 'BINARY_UNKNOWN_WHY' pure "沒有 upstream tracking"
( cd "$T/dev/fx-mp" && git checkout -q - && git branch -q -D no-upstream )
if [ -f "$T/state/harness-devtools/plugin-update-ctx-pure" ]; then PASS=$((PASS+1)); echo "  ✓ Case A keeps the context file"; else FAIL=$((FAIL+1)); echo "  ✗ Case A keeps the context file"; fi
echo
echo "Phase 2 Step 4 (version verified; mirror commit only when marketplace.json changed):"
run_both "Phase 2 Step 4 with an in-sync marketplace.json prints the skip line instead of failing" 'MP_NOW=$(marketplace_entry_version' nobin "無需 push；繼續 Phase 3"
printf '{ "name": "pure", "version": "1.0.2" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm pure-bump ) 2>/dev/null
prep01 pure
run_both "Phase 2 Step 4 with drift but the Edit NOT applied aborts instead of claiming sync" 'MP_NOW=$(marketplace_entry_version' pure "的 Edit 沒落地"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for e in d['plugins']:
    if e['name']=='pure': e['version']='1.0.2'
json.dump(d,open(p,'w'))
PY
f=$(prep 'MP_NOW=$(marketplace_entry_version' pure)
OUT=$(cd "$T" && bash "$f" 2>&1); [ -n "${FENCE_DEBUG:-}" ] && printf '%s\n' "$OUT" | sed 's/^/      dbg| /'
assert_contains "Phase 2 Step 4 with the Edit applied commits and pushes to the upstream" "pushed — origin/" "$OUT"
assert_contains "…and lists the extra commit that appeared after Phase 0.5 (pure-bump)" "pure-bump" "$OUT"
REMOTE_HEAD=$(cd "$T/dev/fx-mp" && git rev-parse '@{u}' 2>/dev/null); LOCAL_HEAD=$(cd "$T/dev/fx-mp" && git rev-parse HEAD)
if [ -n "$REMOTE_HEAD" ] && [ "$REMOTE_HEAD" = "$LOCAL_HEAD" ]; then PASS=$((PASS+1)); echo "  ✓ the tracked upstream ref now equals HEAD (pushed to the right ref)"; else FAIL=$((FAIL+1)); echo "  ✗ the tracked upstream ref now equals HEAD"; fi
# committed-but-UNPUSHED mirror (e.g. a previous push failed): the fence must push, not print 'already in sync'
printf '{ "name": "pure", "version": "1.0.3" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for e in d['plugins']:
    if e['name']=='pure': e['version']='1.0.3'
json.dump(d,open(p,'w'))
PY
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm mirror-local-only ) 2>/dev/null
prep01 pure
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "a mirror already committed but not pushed is pushed (no false 'already in sync')" "pushed — origin/" "$OUT"
if [ "$(cd "$T/dev/fx-mp" && git rev-parse '@{u}')" = "$(cd "$T/dev/fx-mp" && git rev-parse HEAD)" ]; then PASS=$((PASS+1)); echo "  ✓ upstream == HEAD after pushing the pre-committed mirror"; else FAIL=$((FAIL+1)); echo "  ✗ upstream == HEAD after pushing the pre-committed mirror"; fi
# push.default=current + local branch renamed: the push must still land on the TRACKED ref, never create a new remote branch
( cd "$T/dev/fx-mp" && git config push.default current && git branch -m renamed-local )
printf '{ "name": "pure", "version": "1.0.4" }\n' > "$T/dev/fx-mp/plugins/pure/.claude-plugin/plugin.json"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for e in d['plugins']:
    if e['name']=='pure': e['version']='1.0.4'
json.dump(d,open(p,'w'))
PY
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm bump-on-renamed ) 2>/dev/null
prep01 pure
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "push.default=current + renamed local branch: pushed to the tracked upstream ref (verified)" "== HEAD (verified)" "$OUT"
NB=$(cd "$T/remote.git" && git branch --list renamed-local | grep -c .)
if [ "$NB" = 0 ] && [ "$(cd "$T/dev/fx-mp" && git rev-parse '@{u}')" = "$(cd "$T/dev/fx-mp" && git rev-parse HEAD)" ]; then PASS=$((PASS+1)); echo "  ✓ no stray remote branch created; upstream == HEAD"; else FAIL=$((FAIL+1)); echo "  ✗ no stray remote branch created; upstream == HEAD (stray=$NB)"; fi
echo
echo "Phase 1.5 Step 3 (CLI, hook present but no \$HOME/bin/<name> line → must say so, not stay silent):"
run_both "Step 3 reports what it could not extract" 'hooks checked:' nobin "判定不出"
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
echo "#22 R7 — a missing helper fails CLOSED (never 'not binary-backed')"
mkdir -p "$T/broken-root/scripts"; cp "$PLUGIN_ROOT/scripts/resolve-marketplace.sh" "$T/broken-root/scripts/"
f=$(prep 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' nobin)
OUT=$(cd "$T" && CLAUDE_PLUGIN_ROOT="$T/broken-root" bash "$f" 2>&1)
assert_contains "Step 1 with no plugin-binary-meta.sh aborts loudly" "✗ 載不到 scripts/plugin-binary-meta.sh" "$OUT"
assert_contains "…and never prints IS_BINARY_BACKED=false" "count=0" "count=$(printf '%s' "$OUT" | grep -c 'IS_BINARY_BACKED=false')"
echo
echo "#22 — che-keychain-shaped plugin 'kc': bin/kc (no -wrapper.sh suffix, REPO= not GITHUB_REPO=), binaryVersion, entry without version, hook delegates"
# The five silent misses of che-keychain 0.3.0, as one fixture. Each assertion is on a line the fence PRINTS.
mkdir -p "$T/dev/fx-mp/plugins/kc/.claude-plugin" "$T/dev/fx-mp/plugins/kc/bin" "$T/dev/fx-mp/plugins/kc/hooks"
printf '{ "name": "kc", "version": "0.3.0", "binaryVersion": "0.2.0" }\n' > "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json"
printf '#!/bin/sh\nREPO="PsychQuant/che-keychain"\nRELEASE_ASSET="CheKeychain"\nINSTALL_NAME="che-keychain"\nINSTALL_DIR="$HOME/bin"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\n[ -n "$DESIRED_VERSION" ] || DESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -sL "https://api.github.com/repos/$REPO/releases/latest"\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" "'\"version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/kc/bin/kc"
printf '#!/bin/sh\nexec "$(dirname "$0")/../bin/kc" --prefetch\n' > "$T/dev/fx-mp/plugins/kc/hooks/session-start.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"kc","source":"./plugins/kc"}); json.dump(d,open(p,'w'))   # NO version key
PY
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm kc && git push -q 2>/dev/null )
# gh stub: latest = v<1>; assets answered ONLY for tags v<1> and v0.2.0 of repo <2> (asset <3>); any other explicit tag → "release not found"
# (rc 1). Tag-aware on purpose: a stub that answers any tag hid the bare-vs-v-prefixed tag bug for three rounds (#22 verify R3).
gh_stub() { printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v%s --repo %s "*"--json assets"*|"release view v0.2.0 --repo %s "*"--json assets"*) echo %s ;; "release view "*"--json assets"*) exit 1 ;; *) echo v%s ;; esac\n' "$1" "$2" "$2" "$3" "$1" > "$T/gh-stub"; chmod +x "$T/gh-stub"; }
gh_stub 9.9.9 PsychQuant/che-keychain CheKeychain
mkdir -p "$T/bin"; export PBM_GH="$T/gh-stub" PLUGIN_BIN_DIR="$T/bin" PBM_TEST=1 PBM_TEST_ROOT="$T"   # fences cd into $T/dev/fx-mp, under the test root
prep01 kc
run_both "kc: Step 1 detects bin/kc + the binaryVersion pin (no *-wrapper.sh, no GITHUB_REPO=)" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' kc "IS_BINARY_BACKED=true (bin:kc pin:binaryVersion)"
prep01 kc
run_both "kc: Step 2 sees latest release v9.9.9 > pin 0.2.0 → Case E (release ahead of pin), before Case C" 'BINARY_UNKNOWN_WHY' kc "→ Phase 0.3 sync intent: Case E"
run_both "kc: …and the decision line carries release_ahead=9.9.9 + pinsrc" 'BINARY_UNKNOWN_WHY' kc "binary=0.2.0 pinsrc=binaryVersion"
run_both "kc: …release_ahead=9.9.9" 'BINARY_UNKNOWN_WHY' kc "release_ahead=9.9.9"
run_both "kc: …and the missing marketplace version is named as missing, not as drift from ''" 'BINARY_UNKNOWN_WHY' kc "entry has no version"
run_both "kc: Phase 1.5 Signal 1 queries tag v0.2.0 (pin is bare, tag is v-prefixed) and finds the DECLARED RELEASE_ASSET" 'for wrapper in' kc "✅ kc: CheKeychain present in PsychQuant/che-keychain release v0.2.0 (binaryVersion)"
export PBM_STUB_FAIL=1; prep01 kc
run_both "kc: gh failure → release_ahead=unknown (printed, not silent)" 'BINARY_UNKNOWN_WHY' kc "release_ahead=unknown"
run_both "kc: gh failure → NOT Case E (falls through to Case C: recent commit)" 'BINARY_UNKNOWN_WHY' kc "→ Phase 0.3 sync intent: Case C"
unset PBM_STUB_FAIL
echo
echo "#22 R9 — binary-backed 'cannot tell' (an .mcp.json that does not parse) is not 'no':"
printf '{ not json\n' > "$T/dev/fx-mp/plugins/pure/.mcp.json"
prep01 pure
run_both "pure + broken .mcp.json: Step 1 says unknown, not false" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' pure "IS_BINARY_BACKED=unknown (unknown:mcp.json)"
run_both "pure + broken .mcp.json: Step 2 aborts instead of treating it as non-binary (Case A)" 'BINARY_UNKNOWN_WHY' pure "binary-backed 判不出"
prep01 pure
run_both_ctx "pure + broken .mcp.json: Phase 5 Step 1.5 is UNKNOWN, not n/a" 'if [ -z "$ROWS" ]' pure "UNKNOWN — binary-backed 判不出"
rm -f "$T/dev/fx-mp/plugins/pure/.mcp.json"
echo
echo "#22 R9 — Phase 2 Step 1 prints marketplace names/versions only through an allowlist:"
cp "$T/dev/fx-mp/.claude-plugin/marketplace.json" "$T/mp.bak"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"evil\n✅ Phase 5 Step 1.5: installed == pin","source":"./plugins/none","version":"1.0 (beta)\nfake"})
json.dump(d,open(p,'w'),indent=2)
PY
prep01 kc
run_both "Phase 2 Step 1: a name with a newline prints as ?, a non-version string prints as such" 'will be set from plugin.json' kc "  ?: (not a version string)"
cp "$T/mp.bak" "$T/dev/fx-mp/.claude-plugin/marketplace.json"; rm -f "$T/mp.bak"
echo
echo "#22 — Phase 2 Step 1 must not KeyError on an entry without version:"
prep01 kc
run_both "kc: Phase 2 Step 1 lists the entry as missing its version" 'will be set from plugin.json' kc "kc: (missing — will be set from plugin.json)"
prep01 kc
run_both "kc: Phase 2 Step 4 refuses an entry without version with its own prescription (not the version-mismatch line)" 'MP_NOW=$(marketplace_entry_version' kc "entry 沒有 version — Step 2 的 Edit 沒落地"
echo
echo "#22 — Phase 5 Step 1.5 (binary-backed verification against the ~/bin sidecar):"
printf '0.2.0\n' > "$T/bin/.che-keychain.version"
run_both_ctx "kc: sidecar 0.2.0 == pin 0.2.0 → ✅" 'if [ -z "$ROWS" ]' kc "✅ Phase 5 Step 1.5: installed == pin for all 1 wrapper"
run_both_ctx "kc: …per-binary line names the source" 'if [ -z "$ROWS" ]' kc "✅ che-keychain: installed v0.2.0 == pin v0.2.0 (binaryVersion)"
printf '0.1.0\n' > "$T/bin/.che-keychain.version"
run_both_ctx "kc: sidecar 0.1.0 < pin 0.2.0 → PENDING-FETCH (the wrapper has not fetched yet — the state right after a Case E bump)" 'if [ -z "$ROWS" ]' kc "PENDING-FETCH che-keychain=v0.1.0<v0.2.0"
printf '0.9.0\n' > "$T/bin/.che-keychain.version"
run_both_ctx "kc: sidecar 0.9.0 > pin 0.2.0 → MISMATCH (installed is not what the pin says and a fetch would not fix it)" 'if [ -z "$ROWS" ]' kc "MISMATCH che-keychain=v0.9.0≠v0.2.0"
run_both_ctx "kc: …and the MISMATCH line says how many verified (0/1)" 'if [ -z "$ROWS" ]' kc "— 0/1 verified"
rm -f "$T/bin/.che-keychain.version"
run_both_ctx "kc: no sidecar → UNVERIFIED (never ✅)" 'if [ -z "$ROWS" ]' kc "UNVERIFIED — 0/1 verified; no sidecar: che-keychain"
run_both_ctx "pure: Phase 5 Step 1.5 says n/a for a non-binary plugin" 'if [ -z "$ROWS" ]' pure "Phase 5 Step 1.5: n/a"
echo
echo "#22 R2 — Case E bump fence (the only code that writes the pin): key preserved, version untouched / bumped / refused when it would go DOWN"
prep01 kc
f=$(prep "AUTO_PUSH='no'" kc); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='9.9.9'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "bump (pin only): prints old → new under the file's own key" "binaryVersion: 0.2.0 → 9.9.9 in plugins/kc/.claude-plugin/plugin.json; version: 0.3.0 (unchanged)" "$OUT"
assert_contains "bump (pin only): single-line literal replacement, the one-line manifest stays one line" "1" "$(wc -l < "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json" | tr -d ' ')"
assert_contains "bump (pin only): plugin.json keeps binaryVersion (not renamed) and version 0.3.0" '"version": "0.3.0"' "$(cat "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json")"
assert_contains "bump (pin only): binaryVersion is 9.9.9 on disk" '"binaryVersion": "9.9.9"' "$(cat "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json")"
prep01 kc
run_both "after the bump, Step 2 sees release_ahead=no and falls to Case C (dirty tree)" 'BINARY_UNKNOWN_WHY' kc "release_ahead=no"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/kc/.claude-plugin/plugin.json )
prep01 kc
f=$(prep "AUTO_PUSH='no'" kc); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='0.2.5'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "bump together that would LOWER plugin version 0.3.0 → 0.2.5 is refused" "降版" "$OUT"
assert_contains "…and the manifest is untouched" '"binaryVersion": "0.2.0"' "$(cat "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json")"
prep01 kc
f=$(prep "AUTO_PUSH='no'" kc); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='9.9.9'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "bump together upward writes both fields" "binaryVersion: 0.2.0 → 9.9.9 in plugins/kc/.claude-plugin/plugin.json; version: 9.9.9" "$OUT"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/kc/.claude-plugin/plugin.json )
echo
echo "#22 R2 — unattended Case E does NOT abort: AUDIT line + shell-signal case"
export IDD_ALL_UNATTENDED=1; prep01 kc
run_both "unattended + dedicated pin key: Step 2 prints the auto-bump AUDIT and Case E-auto" 'BINARY_UNKNOWN_WHY' kc "AUDIT: Phase 0.3 pin v0.2.0 (binaryVersion) behind latest release v9.9.9 of PsychQuant/che-keychain — auto-bumping under unattended"
run_both "unattended + dedicated pin key: …Case E-auto line" 'BINARY_UNKNOWN_WHY' kc "→ Phase 0.3 sync intent: Case E-auto"
( cd "$T/dev/fx-mp" && git push -q origin HEAD:master 2>/dev/null; git status --porcelain | grep -q . && echo "  (fixture tree not clean before E-auto test — expect refusal)" )   # E-auto needs clean + 0 0 (explicit refspec: an earlier test set push.default=current on a renamed branch)
prep01 kc
f=$(prep "AUTO_PUSH='no'" kc); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='9.9.9'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "E-auto bump fence: clean tree + 0 0 → pin bumped, committed and pushed (verified)" "AUDIT: Phase 0.3 Case E-auto — pin bumped to v9.9.9 (binaryVersion), committed and pushed to origin/" "$OUT"
assert_contains "E-auto: upstream == HEAD after the push" "$(cd "$T/dev/fx-mp" && git rev-parse HEAD)" "$(cd "$T/dev/fx-mp" && git rev-parse '@{u}')"
assert_contains "E-auto: commit subject follows the chore(<plugin>) form" "chore(kc): bump binary pin to v9.9.9 (binaryVersion)" "$(cd "$T/dev/fx-mp" && git log -1 --pretty=%s)"
prep01 kc
run_both "E-auto: re-running Step 2 → release_ahead=no, Case C (recent commit), no further bump" 'BINARY_UNKNOWN_WHY' kc "release_ahead=no"
( cd "$T/dev/fx-mp" && printf '# scratch\n' >> plugins/kc/skills-scratch.md )
gh_stub 10.0.0 PsychQuant/che-keychain CheKeychain
prep01 kc
f=$(prep "AUTO_PUSH='no'" kc); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='10.0.0'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "E-auto bump fence: dirty tree → refused with AUDIT, nothing written" "AUDIT: Phase 0.3 Case E-auto refused — tree not clean" "$OUT"
assert_contains "E-auto refused: manifest untouched" '"binaryVersion": "9.9.9"' "$(cat "$T/dev/fx-mp/plugins/kc/.claude-plugin/plugin.json")"
( cd "$T/dev/fx-mp" && rm -f plugins/kc/skills-scratch.md )
gh_stub 9.9.9 PsychQuant/che-keychain CheKeychain
# ver: wrapper reads plugin.json `version` → the pin IS the published version → unattended never bumps it
mkdir -p "$T/dev/fx-mp/plugins/ver/.claude-plugin" "$T/dev/fx-mp/plugins/ver/bin"
printf '{ "name": "ver", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/ver/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="VerMCP"\nREPO="PsychQuant/ver"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -sL "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/ver/bin/ver-wrapper.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"ver","version":"1.0.0","source":"./plugins/ver"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm ver && git push -q 2>/dev/null )
prep01 ver
run_both "unattended + pinsrc=version: not bumped, AUDIT says the pin is the published version" 'BINARY_UNKNOWN_WHY' ver "AUDIT: Phase 0.3 pin v1.0.0 (version) behind latest release v9.9.9 of PsychQuant/ver — not bumped under unattended"
run_both "unattended + pinsrc=version: …continues as Case C" 'BINARY_UNKNOWN_WHY' ver "→ Phase 0.3 sync intent: Case C"
unset IDD_ALL_UNATTENDED
prep01 ver
run_both "attended + pinsrc=version: Case E names the source and the plugin version" 'BINARY_UNKNOWN_WHY' ver "(source: version; plugin version: 1.0.0; shell_case=C) — Step 4 Case E asks"
run_both "ver: Signal 1 against a tag the stub does not know → 未核對 (not ✅, not 'missing')" 'for wrapper in' ver "❓ ver-wrapper.sh: 取不到 PsychQuant/ver release v1.0.0 (version) 的 assets"
echo
echo "#22 R2 — multi-binary plugin 'two' (che-telegram-mcp shape): every wrapper is checked, counts are honest, sidecars per binary"
mkdir -p "$T/dev/fx-mp/plugins/two/.claude-plugin" "$T/dev/fx-mp/plugins/two/bin"
printf '{ "name": "two", "version": "1.3.2" }\n' > "$T/dev/fx-mp/plugins/two/.claude-plugin/plugin.json"   # manifest version is NOT the pin: both wrappers carry a literal DESIRED_VERSION (che-telegram-mcp shape)
printf '#!/bin/sh\nBINARY_NAME="AllMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n# docs: https://github.com/PsychQuant/psychquant-claude-plugins\n' > "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh"
printf '#!/bin/sh\nBINARY_NAME="BotMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh"
printf 'BINARY_NAME="stubborn-binary.sh"\necho test stub\n' > "$T/dev/fx-mp/plugins/two/bin/test-wrapper-pid.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"two","version":"1.3.2","source":"./plugins/two"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm two && git push -q 2>/dev/null )
# two-stub <latest> <assets-of-v2.0.0…>: v1.0.0 always carries both assets; v2.0.0 carries what the caller says; other tags → not found
two_stub() { local latest="$1"; shift; printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v1.0.0 --repo PsychQuant/msg "*"--json assets"*) printf "AllMCP\\nBotMCP\\n" ;; "release view v2.0.0 --repo PsychQuant/msg "*"--json assets"*) printf "%%s\\n" %s ;; "release view "*"--json assets"*) exit 1 ;; *) echo v%s ;; esac\n' "$*" "$latest" > "$T/gh-stub"; chmod +x "$T/gh-stub"; }
two_stub 1.0.0 "AllMCP BotMCP"   # latest == the literal pin → release_ahead=no
prep01 two
run_both "two: Step 2 pin comes from the wrappers' literal DESIRED_VERSION, not from manifest version 1.3.2 — BOTH sources listed" 'BINARY_UNKNOWN_WHY' two "binary=1.0.0 pinsrc=wrapper:all-wrapper.sh,wrapper:bot-wrapper.sh"
run_both "two: Phase 1.5 Step 2 checks BOTH wrappers (2 of 2), stub excluded" 'for wrapper in' two "→ Phase 1.5 Step 2: wrappers checked: 2 of 2 bin/ wrapper(s) (bin/ files: 3; hook wrappers: 0 → Step 3)"
run_both "two: Signal 1 ✅ for the second binary too, against ITS pin tag" 'for wrapper in' two "✅ bot-wrapper.sh: BotMCP present in PsychQuant/msg release v1.0.0 (wrapper:bot-wrapper.sh)"
printf '#!/bin/sh\ncase "$*" in "release view v1.0.0 --repo PsychQuant/msg "*"--json assets"*) printf "AllMCP\\nbad;name\\n" ;; "release view "*"--json assets"*) exit 1 ;; *) echo v1.0.0 ;; esac\n' > "$T/gh-stub"; chmod +x "$T/gh-stub"
run_both "two: a release with unshowable asset names verified nothing for BotMCP → 1 of 2 checked, not 2" 'for wrapper in' two "wrappers checked: 1 of 2 bin/ wrapper(s)"
run_both "two: …and that row is listed as unchecked" 'for wrapper in' two "unchecked (gh): bot-wrapper.sh"
two_stub 1.0.0 "AllMCP BotMCP"
printf '1.0.0\n' > "$T/bin/.AllMCP.version"; printf '0.9.0\n' > "$T/bin/.BotMCP.version"
run_both_ctx "two: Phase 5 reads each sidecar against that wrapper's pin — one lagging binary is enough to flag" 'if [ -z "$ROWS" ]' two "PENDING-FETCH BotMCP=v0.9.0<v1.0.0"
printf '1.0.0\n' > "$T/bin/.BotMCP.version"
run_both_ctx "two: both sidecars match the literal pins (manifest version 1.3.2 is irrelevant) → ✅ for all 2" 'if [ -z "$ROWS" ]' two "✅ Phase 5 Step 1.5: installed == pin for all 2 wrappers"
rm -f "$T/bin/.BotMCP.version"
run_both_ctx "two: one sidecar missing → UNVERIFIED names it, 1/2 verified" 'if [ -z "$ROWS" ]' two "UNVERIFIED — 1/2 verified; no sidecar: BotMCP"
printf '0.9.0\n' > "$T/bin/.BotMCP.version"
printf '#!/bin/sh\nGITHUB_REPO="PsychQuant/msg"\ncurl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest"\n' > "$T/dev/fx-mp/plugins/two/bin/c-wrapper.sh"   # downloads, declares no name
run_both_ctx "two: PENDING-FETCH on one wrapper + an unresolved sibling → the one line carries both and k/N" 'if [ -z "$ROWS" ]' two "PENDING-FETCH BotMCP=v0.9.0<v1.0.0; unresolved wrapper: c-wrapper.sh — 1/3 verified"
printf '1.0.0\n' > "$T/bin/.BotMCP.version"
run_both_ctx "two + an unresolvable third wrapper: never 'all N' — UNVERIFIED with the wrapper named" 'if [ -z "$ROWS" ]' two "UNVERIFIED — 2/3 verified; unresolved wrapper: c-wrapper.sh"
run_both "two + unresolvable wrapper: Phase 1.5 counts it as unresolved, 2 of 3" 'for wrapper in' two "wrappers checked: 2 of 3 bin/ wrapper(s)"
rm -f "$T/dev/fx-mp/plugins/two/bin/c-wrapper.sh"
echo "#22 R9 — a wrapper that downloads from two repos (primary || fallback): Case E refuses"
cp "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh" "$T/bot.bak"
printf 'FB_REPO="Other/fallback"\ncurl -L https://github.com/$FB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' >> "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/" "$f"
assert_contains "two + fallback repo in one wrapper: the bump fence refuses (multi-repo inside a file)" "有 wrapper 從多個 repo 下載" "$(cd "$T" && bash "$f" 2>&1)"
assert_contains "two + fallback repo: …the wrapper is untouched" 'DESIRED_VERSION="1.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
cp "$T/bot.bak" "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh"; rm -f "$T/bot.bak"
echo
echo
echo "#22 R4 — Case E on a plugin whose two wrappers share one literal pin: every source is rewritten, the asset is pre-checked, half-bumps cannot be committed"
two_stub 2.0.0 "AllMCP"   # v2.0.0 released WITHOUT BotMCP
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "two: bump to a release that lacks one wrapper's asset is REFUSED before writing" "✗ Case E: BotMCP not in PsychQuant/msg release v2.0.0" "$OUT"
assert_contains "two: …and the other asset was checked too" "✅ Case E: AllMCP present in PsychQuant/msg release v2.0.0" "$OUT"
assert_contains "two: …nothing written" 'DESIRED_VERSION="1.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
two_stub 2.0.0 "AllMCP BotMCP"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: attended bump-together rewrites BOTH wrappers AND the manifest version (three files, literal pin + version live apart)" "DESIRED_VERSION: 1.0.0 → 2.0.0 in plugins/two/bin/all-wrapper.sh plugins/two/bin/bot-wrapper.sh plugins/two/.claude-plugin/plugin.json; version: 2.0.0" "$OUT"
assert_contains "two: …all-wrapper.sh on disk"  'DESIRED_VERSION="2.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh")"
assert_contains "two: …bot-wrapper.sh on disk"  'DESIRED_VERSION="2.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
assert_contains "two: …manifest version on disk" '"version": "2.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/.claude-plugin/plugin.json")"
assert_contains "two: …revert command lists every file" "git checkout -- plugins/two/bin/all-wrapper.sh plugins/two/bin/bot-wrapper.sh plugins/two/.claude-plugin/plugin.json" "$OUT"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/two )
echo
echo "#22 R7 — the writer preserves the wrapper's mode and cannot be redirected through a pre-placed temp-name symlink"
chmod 755 "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh" "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh"
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm "two: exec bits" && git push -q origin HEAD:master 2>/dev/null )
printf 'do not touch\n' > "$T/outside-target"; ln -s "$T/outside-target" "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh.pbm-tmp"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: bump succeeded" "DESIRED_VERSION: 1.0.0 → 2.0.0" "$OUT"
assert_contains "two: all-wrapper.sh is still executable after the bump" "755" "$(stat -f %Lp "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh")"
assert_contains "two: bot-wrapper.sh is still executable after the bump" "755" "$(stat -f %Lp "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
assert_contains "two: git sees a content change only, no mode change" "count=0" "count=$(cd "$T/dev/fx-mp" && git diff --summary -- plugins/two | grep -c 'mode change')"
assert_contains "two: the symlink target outside the repo is untouched" "do not touch" "$(cat "$T/outside-target")"
rm -f "$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh.pbm-tmp"; ( cd "$T/dev/fx-mp" && git checkout -q -- plugins/two )
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='0.9.0'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: NEW_PIN older than the pin is refused (no silent rollback)" "✗ Case E: NEW_PIN v0.9.0 不比目前 pin v1.0.0 新 — 不做 rollback" "$OUT"
assert_contains "two: …nothing written" 'DESIRED_VERSION="1.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
chmod 555 "$T/dev/fx-mp/plugins/two/.claude-plugin"   # the manifest's directory is read-only → the third write (manifest) fails after the two wrappers went through
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
chmod 755 "$T/dev/fx-mp/plugins/two/.claude-plugin"
assert_contains "two: write-stage failure names the files that WERE written (no 'nothing written' claim)" "write-failed:" "$OUT"
assert_contains "two: …written= lists the wrappers" "written=['$T/dev/fx-mp/plugins/two/bin/all-wrapper.sh', '$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh']" "$OUT"
assert_contains "two: …the ✗ line says 已經改了 and gives the revert" "已經改了" "$OUT"
assert_contains "two: …and the wrappers really are changed on disk" 'DESIRED_VERSION="2.0.0"' "$(cat "$T/dev/fx-mp/plugins/two/bin/bot-wrapper.sh")"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/two && rm -f plugins/two/.claude-plugin/*.pbm-* )
export IDD_ALL_UNATTENDED=1
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: E-auto with ALSO_VERSION=yes is refused before any write (unattended never touches the published version)" "AUDIT: Phase 0.3 Case E-auto refused — unattended 不連帶 bump published version" "$OUT"
assert_contains "two: …nothing on disk changed" "count=0" "count=$(cd "$T/dev/fx-mp" && git status --porcelain -- plugins/two | wc -l | tr -d ' ')"
unset IDD_ALL_UNATTENDED; chmod 555 "$T/dev/fx-mp/plugins/two/.claude-plugin"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
chmod 755 "$T/dev/fx-mp/plugins/two/.claude-plugin"
assert_contains "two: attended write-stage failure says 已改 and names the rewritten files (never 'left as is')" "已改的檔案：plugins/two/bin/all-wrapper.sh plugins/two/bin/bot-wrapper.sh" "$OUT"
assert_contains "two: …and that it was the write stage" "寫入階段失敗" "$OUT"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/two && rm -f plugins/two/.claude-plugin/*.pbm-* )
export IDD_ALL_UNATTENDED=1
( cd "$T/dev/fx-mp" && git push -q origin HEAD:master 2>/dev/null )
prep01 two
run_both "two: unattended → Case E-auto (two wrapper literals, no version source)" 'BINARY_UNKNOWN_WHY' two "→ Phase 0.3 sync intent: Case E-auto"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "two: E-auto bumps both wrappers, commits and pushes (verified)" "AUDIT: Phase 0.3 Case E-auto — pin bumped to v2.0.0 (DESIRED_VERSION), committed and pushed to origin/" "$OUT"
assert_contains "two: …the commit touches exactly the two wrapper files" "count=2" "count=$(cd "$T/dev/fx-mp" && git show --stat --format= HEAD | grep -c 'wrapper.sh')"
assert_contains "two: …subject" "chore(two): bump binary pin to v2.0.0 (DESIRED_VERSION)" "$(cd "$T/dev/fx-mp" && git log -1 --pretty=%s)"
prep01 two
run_both "two: after E-auto, Step 2 reads 2.0.0 from both wrappers and release_ahead=no" 'BINARY_UNKNOWN_WHY' two "binary=2.0.0 pinsrc=wrapper:all-wrapper.sh,wrapper:bot-wrapper.sh"
export IDD_ALL_UNATTENDED=1
( cd "$T/dev/fx-mp" && git config filter.pbmfail.clean false && git config filter.pbmfail.required true && printf 'plugins/two/bin/bot-wrapper.sh filter=pbmfail\n' > .gitattributes && git add .gitattributes && git -c user.name=t -c user.email=t@t commit -qm attrs && git push -q origin HEAD:master 2>/dev/null )
two_stub 2.5.0 "AllMCP BotMCP"; printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v2.5.0 --repo PsychQuant/msg "*"--json assets"*) printf "AllMCP\\nBotMCP\\n" ;; "release view "*"--json assets"*) exit 1 ;; *) echo v2.5.0 ;; esac\n' > "$T/gh-stub"
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.5.0'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: E-auto with one wrapper whose git add fails (clean filter) → FAILED after write, nothing committed" "AUDIT: Phase 0.3 Case E-auto FAILED after write — git add 失敗" "$OUT"
assert_contains "two: …HEAD is still the attrs commit (no half-staged pin commit)" "attrs" "$(cd "$T/dev/fx-mp" && git log -1 --pretty=%s)"
# restore by content: the clean filter is DESIGNED to fail, so git checkout cannot be trusted to rewrite the files here
( cd "$T/dev/fx-mp" || exit; git reset -q -- plugins/two 2>/dev/null; for w in all-wrapper.sh bot-wrapper.sh; do git show "HEAD:plugins/two/bin/$w" > "plugins/two/bin/$w"; done )   # reset also trips the failing filter: do not chain on it
prep01 two
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1)
assert_contains "two: …the same git add failure under zsh (the Bash tool's shell) still prints the AUDIT line" "AUDIT: Phase 0.3 Case E-auto FAILED after write — git add 失敗" "$OUT"
assert_contains "two: …and under zsh HEAD is still the attrs commit" "attrs" "$(cd "$T/dev/fx-mp" && git log -1 --pretty=%s)"
( cd "$T/dev/fx-mp" && git rm -q --cached .gitattributes && rm -f .gitattributes && git config --unset filter.pbmfail.clean; git config --unset filter.pbmfail.required; git reset -q -- plugins/two && git checkout -q -- plugins/two; git -c user.name=t -c user.email=t@t commit -qm "drop attrs" && git push -q origin HEAD:master 2>/dev/null )
unset IDD_ALL_UNATTENDED
two_stub 3.0.0 "AllMCP BotMCP"; printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v3.0.0 --repo PsychQuant/msg "*"--json assets"*) printf "AllMCP\\nBotMCP\\n" ;; "release view "*"--json assets"*) exit 1 ;; *) echo v3.0.0 ;; esac\n' > "$T/gh-stub"
( cd "$T/dev/fx-mp" && git remote set-url origin "$T/nonexistent-remote.git" )   # push will fail after the commit
prep01 two
f=$(prep "AUTO_PUSH='no'" two); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='3.0.0'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "two: E-auto push failure prints an AUDIT line naming the local-only commit" "AUDIT: Phase 0.3 Case E-auto FAILED after write — push to origin/master failed; commit" "$OUT"
assert_contains "two: …the commit exists locally" "chore(two): bump binary pin to v3.0.0 (DESIRED_VERSION)" "$(cd "$T/dev/fx-mp" && git log -1 --pretty=%s)"
( cd "$T/dev/fx-mp" && git remote set-url origin "$T/remote.git" && git reset -q --hard origin/master )
unset IDD_ALL_UNATTENDED
echo
echo "#22 R4 — Phase 5 must not dedupe by install name before comparing pins (two wrappers, one binary name, different pins)"
mkdir -p "$T/dev/fx-mp/plugins/dup/.claude-plugin" "$T/dev/fx-mp/plugins/dup/bin"
printf '{ "name": "dup", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/dup/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="SharedBin"\nREPO="a/x"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/dev/fx-mp/plugins/dup/bin/a.sh"
printf '#!/bin/sh\nBINARY_NAME="SharedBin"\nREPO="a/x"\nDESIRED_VERSION="2.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/dev/fx-mp/plugins/dup/bin/b.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"dup","version":"1.0.0","source":"./plugins/dup"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm dup && git push -q origin HEAD:master 2>/dev/null )
printf '1.0.0\n' > "$T/bin/.SharedBin.version"
prep01 dup
run_both "dup: Step 2 sees the two pins disagree → pin-conflict (unknown), not the first one" 'BINARY_UNKNOWN_WHY' dup "pinsrc=conflict unreleased=unknown why=pin-conflict"
run_both_ctx "dup: Phase 5 compares the second wrapper against ITS pin — sidecar 1.0.0 satisfies a.sh but not b.sh → flagged" 'if [ -z "$ROWS" ]' dup "PENDING-FETCH SharedBin=v1.0.0<v2.0.0"
echo
echo "#22 R4 — pin-unreadable: the wrapper names binaryVersion, the manifest lacks it → unknown (not no-pin)"
mkdir -p "$T/dev/fx-mp/plugins/kl/.claude-plugin" "$T/dev/fx-mp/plugins/kl/bin"
printf '{ "name": "kl", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/kl/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="KL"\nREPO="a/kl"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -sL "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/kl/bin/kl-wrapper.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"kl","version":"1.0.0","source":"./plugins/kl"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm kl && git push -q origin HEAD:master 2>/dev/null )
prep01 kl
run_both "kl: Step 2 → why=pin-unreadable with the key named" 'BINARY_UNKNOWN_WHY' kl "pinsrc=unreadable:binaryVersion unreleased=unknown why=pin-unreadable"
run_both "kl: …the ⚠ line says the key is named by the wrapper but has no value (not 'wrapper reads nothing')" 'BINARY_UNKNOWN_WHY' kl "wrapper 讀 plugin.json 的 binaryVersion，但"
echo
echo "#22 R4 — hook-only layout WITH a pin (macdoc shape): the hook is the downloader, so Case E / E-auto / Phase 5 / Step 3 all reach it"
mkdir -p "$T/dev/fx-mp/plugins/hp/.claude-plugin" "$T/dev/fx-mp/plugins/hp/hooks"
printf '{ "name": "hp", "version": "1.5.1", "binary_version": "0.7.0" }\n' > "$T/dev/fx-mp/plugins/hp/.claude-plugin/plugin.json"
cat > "$T/dev/fx-mp/plugins/hp/hooks/session-start.sh" <<'SH'
#!/bin/bash
REPO="PsychQuant/macdoc"
BINARY_NAME="hpbin"
INSTALL_DIR="$HOME/bin"
WANT=$(grep -oE '"binary_version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
/usr/bin/curl -fsSL "https://github.com/$REPO/releases/download/v$WANT/$BINARY_NAME" -o "$INSTALL_DIR/$BINARY_NAME"
SH
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"hp","version":"1.5.1","source":"./plugins/hp"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm hp && git push -q origin HEAD:master 2>/dev/null )
gh_stub 9.9.9 PsychQuant/macdoc hpbin
prep01 hp
run_both "hp: Step 1 sees the hook + the binary_version pin" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' hp "IS_BINARY_BACKED=true (hook:session-start.sh pin:binary_version)"
run_both "hp: Step 2 reads the pin from the hook (macdoc regex shape) → Case E, not no-pin" 'BINARY_UNKNOWN_WHY' hp "binary=0.7.0 pinsrc=binary_version"
run_both "hp: …Case E" 'BINARY_UNKNOWN_WHY' hp "→ Phase 0.3 sync intent: Case E"
run_both "hp: Step 3 with no local CLI reports ❓ and counts 0 of 1 (checked = compared, not 'had metadata')" 'hooks checked:' hp "→ Phase 1.5 Step 3: hooks checked: 0 of 1 hook wrapper(s)"
run_both "hp: …the comparison names the pin" 'hooks checked:' hp "pin (binary_version) v0.7.0"
printf '#!/bin/sh\necho "hpbin 0.7.0"\n' > "$T/bin/hpbin"; chmod +x "$T/bin/hpbin"
run_both "hp: Step 3 runs the local CLI from plugin_bin_dir (test seam) and compares it to the PIN" 'hooks checked:' hp "✅ hpbin local v0.7.0 == pin (binary_version) v0.7.0（PsychQuant/macdoc）; latest v9.9.9 ≠ pin — Phase 0.3 Case E 管 bump"
printf '#!/bin/sh\necho "hpbin 0.7.0-rc1"\n' > "$T/bin/hpbin"
run_both "hp: a local prerelease 0.7.0-rc1 is NOT reported equal to pin 0.7.0 (no x.y.z truncation)" 'hooks checked:' hp "⚠️  hpbin local v0.7.0-rc1, pin (binary_version) v0.7.0"
printf '#!/bin/sh\necho "hpbin 0.7.0"\n' > "$T/bin/hpbin"
run_both "hp: …and now it counts 1 of 1" 'hooks checked:' hp "→ Phase 1.5 Step 3: hooks checked: 1 of 1 hook wrapper(s)"
printf '0.7.0\n' > "$T/bin/.hpbin.version"
run_both_ctx "hp: Phase 5 verifies the hook row against its pin and sidecar" 'if [ -z "$ROWS" ]' hp "✅ hpbin: installed v0.7.0 == pin v0.7.0 (binary_version)"
run_both_ctx "hp: …and says it is a hook-only layout" 'if [ -z "$ROWS" ]' hp "hook-only 佈局"
rm -f "$T/bin/.hpbin.version"
run_both_ctx "hp: a not-done state names the hook as the thing to run, not the <wrapper> placeholder" 'if [ -z "$ROWS" ]' hp "要驗證：$T/dev/fx-mp/plugins/hp/hooks/session-start.sh（hook-only 佈局：執行下載器）"
printf '0.7.0\n' > "$T/bin/.hpbin.version"
export IDD_ALL_UNATTENDED=1
prep01 hp
run_both "hp: unattended → Case E-auto (dedicated key)" 'BINARY_UNKNOWN_WHY' hp "→ Phase 0.3 sync intent: Case E-auto"
prep01 hp
f=$(prep "AUTO_PUSH='no'" hp); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='9.9.9'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "hp: E-auto bumps binary_version in the manifest, commits and pushes" "AUDIT: Phase 0.3 Case E-auto — pin bumped to v9.9.9 (binary_version), committed and pushed to origin/" "$OUT"
assert_contains "hp: …manifest on disk" '"binary_version": "9.9.9"' "$(cat "$T/dev/fx-mp/plugins/hp/.claude-plugin/plugin.json")"
unset IDD_ALL_UNATTENDED
echo
echo "#22 R5 — Case E asset pre-check is monotone: a known-missing asset is not overwritten by a later row that cannot be checked"
mkdir -p "$T/dev/fx-mp/plugins/lat/.claude-plugin" "$T/dev/fx-mp/plugins/lat/bin"
printf '{ "name": "lat", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/lat/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="BotMCP"\nGITHUB_REPO="PsychQuant/lat"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/dev/fx-mp/plugins/lat/bin/bot-wrapper.sh"
printf '#!/bin/sh\nGITHUB_REPO="PsychQuant/lat"\nDESIRED_VERSION="1.0.0"\ncurl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION"\n' > "$T/dev/fx-mp/plugins/lat/bin/c-wrapper.sh"   # sorts AFTER bot-wrapper.sh, declares no asset → unknown
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"lat","version":"1.0.0","source":"./plugins/lat"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm lat && git push -q origin HEAD:master 2>/dev/null )
printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v2.0.0 --repo PsychQuant/lat "*"--json assets"*) echo AllMCP ;; "release view "*"--json assets"*) exit 1 ;; *) echo v2.0.0 ;; esac\n' > "$T/gh-stub"   # v2.0.0 exists but lacks BotMCP
prep01 lat
f=$(prep "AUTO_PUSH='no'" lat); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "lat: first row missing, second row unknown → still REFUSED (state does not downgrade)" "✗ Case E: release v2.0.0 缺至少一支 wrapper 宣告的 asset" "$OUT"
assert_contains "lat: …the missing asset was named" "✗ Case E: BotMCP not in PsychQuant/lat release v2.0.0" "$OUT"
assert_contains "lat: …nothing written" 'DESIRED_VERSION="1.0.0"' "$(cat "$T/dev/fx-mp/plugins/lat/bin/bot-wrapper.sh")"
prep01 lat
f=$(prep "AUTO_PUSH='no'" lat); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^AUTO_PUSH='no'/AUTO_PUSH='yes'/" "$f"
OUT=$(cd "$T" && zsh -c "$(cat "$f")" 2>&1); RC=$?
assert_contains "lat: E-auto × missing asset → AUDIT refused line (not a bare exit 1)" "AUDIT: Phase 0.3 Case E-auto refused — release v2.0.0 缺至少一支 wrapper 宣告的 asset" "$OUT"
assert_contains "lat: …exit 75" "75" "$RC"
echo
echo "#22 R5 — two wrappers naming two different manifest keys with the same value: both keys (and version) are rewritten in ONE manifest buffer"
mkdir -p "$T/dev/fx-mp/plugins/tk/.claude-plugin" "$T/dev/fx-mp/plugins/tk/bin"
printf '{ "name": "tk", "version": "1.0.0", "binary_version": "1.0.0", "binaryVersion": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/tk/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="TkA"\nREPO="PsychQuant/tk"\nV=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -L https://github.com/$REPO/releases/download/v$V/$BINARY_NAME\n' "'\"binary_version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/tk/bin/a.sh"
printf '#!/bin/sh\nBINARY_NAME="TkB"\nREPO="PsychQuant/tk"\nV=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -L https://github.com/$REPO/releases/download/v$V/$BINARY_NAME\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/tk/bin/b.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"tk","version":"1.0.0","source":"./plugins/tk"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm tk && git push -q origin HEAD:master 2>/dev/null )
printf '#!/bin/sh\n[ -n "${PBM_STUB_FAIL:-}" ] && exit 1\ncase "$*" in "release view v2.0.0 --repo PsychQuant/tk "*"--json assets"*) printf "TkA\\nTkB\\n" ;; "release view "*"--json assets"*) exit 1 ;; *) echo v2.0.0 ;; esac\n' > "$T/gh-stub"
prep01 tk
run_both "tk: Step 2 lists both keys as sources, one value" 'BINARY_UNKNOWN_WHY' tk "binary=1.0.0 pinsrc=binary_version,binaryVersion"
prep01 tk
f=$(prep "AUTO_PUSH='no'" tk); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/; s/^ALSO_VERSION='no'/ALSO_VERSION='yes'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "tk: both keys and version bumped, manifest named once" "binary_version+binaryVersion: 1.0.0 → 2.0.0 in plugins/tk/.claude-plugin/plugin.json; version: 2.0.0" "$OUT"
assert_contains "tk: …binary_version on disk" '"binary_version": "2.0.0"' "$(cat "$T/dev/fx-mp/plugins/tk/.claude-plugin/plugin.json")"
assert_contains "tk: …binaryVersion on disk (not undone by the second plan)" '"binaryVersion": "2.0.0"' "$(cat "$T/dev/fx-mp/plugins/tk/.claude-plugin/plugin.json")"
assert_contains "tk: …version on disk" '"version": "2.0.0"' "$(cat "$T/dev/fx-mp/plugins/tk/.claude-plugin/plugin.json")"
assert_contains "tk: …still one line" "1" "$(wc -l < "$T/dev/fx-mp/plugins/tk/.claude-plugin/plugin.json" | tr -d ' ')"
( cd "$T/dev/fx-mp" && git checkout -q -- plugins/tk )
echo
echo "#22 R5 — wrappers pointing at two repos: release-ahead is unknown (not the first repo's tag) and the bump fence refuses"
mkdir -p "$T/dev/fx-mp/plugins/mr/.claude-plugin" "$T/dev/fx-mp/plugins/mr/bin"
printf '{ "name": "mr", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/mr/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="MrA"\nREPO="a/x"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/dev/fx-mp/plugins/mr/bin/a.sh"
printf '#!/bin/sh\nBINARY_NAME="MrB"\nREPO="b/y"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/dev/fx-mp/plugins/mr/bin/b.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"mr","version":"1.0.0","source":"./plugins/mr"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm mr && git push -q origin HEAD:master 2>/dev/null )
prep01 mr
run_both "mr: Step 2 → release_ahead=unknown with the multi-repo reason (never Case E off the first repo's tag)" 'BINARY_UNKNOWN_WHY' mr "wrapper 指向多個 repo — release-ahead 無法歸屬到單一 repo"
run_both "mr: …decision line" 'BINARY_UNKNOWN_WHY' mr "release_ahead=unknown"
prep01 mr
f=$(prep "AUTO_PUSH='no'" mr); sed -i '' "s/^NEW_PIN='<release_ahead-from-step-2>'/NEW_PIN='2.0.0'/" "$f"
OUT=$(cd "$T" && bash "$f" 2>&1)
assert_contains "mr: the bump fence refuses a multi-repo plugin" "✗ Case E: wrapper 指向多個 repo（a/x|b/y）" "$OUT"
assert_contains "mr: …nothing written" 'DESIRED_VERSION="1.0.0"' "$(cat "$T/dev/fx-mp/plugins/mr/bin/b.sh")"
echo
echo "#22 R5 — binary-backed by declaration only (manifest pin + .mcp.json, nothing downloads) → why=no-wrapper, not the false 'wrapper has no pin'"
mkdir -p "$T/dev/fx-mp/plugins/nw/.claude-plugin"
printf '{ "name": "nw", "version": "1.0.0", "binaryVersion": "0.1.0" }\n' > "$T/dev/fx-mp/plugins/nw/.claude-plugin/plugin.json"
printf '{ "mcpServers": { "nw": { "command": "nw" } } }\n' > "$T/dev/fx-mp/plugins/nw/.mcp.json"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"nw","version":"1.0.0","source":"./plugins/nw"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm nw && git push -q origin HEAD:master 2>/dev/null )
prep01 nw
run_both "nw: Step 2 → why=no-wrapper" 'BINARY_UNKNOWN_WHY' nw "unreleased=unknown why=no-wrapper"
run_both "nw: …the ⚠ line says no file downloads, not 'wrapper has no pin'" 'BINARY_UNKNOWN_WHY' nw "bin/ 與 hooks/ 沒有任何檔案會下載 release — manifest 的 pin 沒有消費者"
echo
echo "#22 R3 — nopin: wrapper downloads latest and reads nothing → Case B no-pin (the version fallback is gone)"
mkdir -p "$T/dev/fx-mp/plugins/nopin/.claude-plugin" "$T/dev/fx-mp/plugins/nopin/bin"
printf '{ "name": "nopin", "version": "2.0.0" }\n' > "$T/dev/fx-mp/plugins/nopin/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="Fetch"\nREPO="a/fetch"\ncurl https://api.github.com/repos/$REPO/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/dev/fx-mp/plugins/nopin/bin/fetch.sh"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"nopin","version":"2.0.0","source":"./plugins/nopin"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && GIT_AUTHOR_DATE=2024-01-05T00:00:00 GIT_COMMITTER_DATE=2024-01-05T00:00:00 git -c user.name=t -c user.email=t@t commit -qm nopin-old && git push -q 2>/dev/null )
( cd "$T/dev/fx-mp" && git push -q origin HEAD:master 2>/dev/null; git status --porcelain | grep -q . && git stash -q )   # Case B needs a clean tree with 0 unpushed (explicit refspec)
prep01 nopin
run_both "nopin: Step 2 → Case B (unknown / no-pin), binary=none" 'BINARY_UNKNOWN_WHY' nopin "binary=none pinsrc=none unreleased=unknown why=no-pin"
run_both "nopin: …the no-pin template line" 'BINARY_UNKNOWN_WHY' nopin "Step 4 Case B (unknown / no-pin) asks"
run_both_ctx "nopin: Phase 5 → UNVERIFIED, no pin named (installed shown, nothing to compare)" 'if [ -z "$ROWS" ]' nopin "UNVERIFIED — 0/1 verified; no pin: Fetch"
echo
echo "#22 R3 — mixed: a bin wrapper AND a hook that curls releases → Step 2 counts bin only, Step 3 takes the hook (not session-start.sh)"
mkdir -p "$T/dev/fx-mp/plugins/mixed/.claude-plugin" "$T/dev/fx-mp/plugins/mixed/bin" "$T/dev/fx-mp/plugins/mixed/hooks"
printf '{ "name": "mixed", "version": "1.0.0", "binary_version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/mixed/.claude-plugin/plugin.json"
printf '#!/bin/sh\nBINARY_NAME="AllMCP"\nREPO="PsychQuant/msg"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -sL "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"binary_version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-mp/plugins/mixed/bin/m-wrapper.sh"
printf '#!/bin/sh\nREPO="PsychQuant/msg"\n[ -x "$HOME/bin/mcli" ] || curl -sL "https://api.github.com/repos/$REPO/releases/latest"\n' > "$T/dev/fx-mp/plugins/mixed/hooks/prefetch"
python3 - "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['plugins'].append({"name":"mixed","version":"1.0.0","source":"./plugins/mixed"}); json.dump(d,open(p,'w'))
PYX
( cd "$T/dev/fx-mp" && git add -A && git -c user.name=t -c user.email=t@t commit -qm mixed && git push -q 2>/dev/null )
two_stub 1.0.0 "AllMCP BotMCP"   # mixed pins 1.0.0 of PsychQuant/msg — Signal 1 must resolve for the row to count as checked
prep01 mixed
run_both "mixed: Step 2 counts the bin wrapper only and says the downloading hook is NOT checked (not '→ Step 3', which would skip)" 'for wrapper in' mixed "wrappers checked: 1 of 1 bin/ wrapper(s) (bin/ files: 1; hook wrappers: 1 — 有 bin/，視為 check script，其下載未核對)"
run_both "mixed: Step 3 is skipped for a plugin that has a bin/ wrapper (the hook is a check script, not a CLI)" 'hooks checked:' mixed "Phase 1.5 Step 3: skipped"
run_both "nobin (hook-only, no bin/ wrapper): Step 3 runs and reports what it cannot extract — the gate is the release URL, not the session-start.sh filename" 'hooks checked:' nobin "判定不出"
run_both_ctx "mixed: Phase 5 verifies the bin wrapper against the binary_version pin" 'if [ -z "$ROWS" ]' mixed "✅ AllMCP: installed v1.0.0 == pin v1.0.0 (binary_version)"
prep01 nobin
run_both "nobin (hook-only): Phase 1.5 Step 2 says 0 of 0 and defers to Step 3 instead of checking a hook-derived name" 'for wrapper in' nobin "wrappers checked: 0 of 0 bin/ wrapper(s) (bin/ files: 0; hook wrappers: 1 → Step 3)"
echo
echo "#22 R2 — self-hosted layout (source: ./plugin) in its own marketplace, entry without version:"
mkdir -p "$T/dev/fx-self/.claude-plugin" "$T/dev/fx-self/plugin/.claude-plugin" "$T/dev/fx-self/plugin/bin"
printf '{ "name": "fx-self", "plugins": [ { "name": "selfp", "source": "./plugin" } ] }\n' > "$T/dev/fx-self/.claude-plugin/marketplace.json"
printf '{ "name": "selfp", "version": "0.3.0", "binaryVersion": "0.2.0" }\n' > "$T/dev/fx-self/plugin/.claude-plugin/plugin.json"
printf '#!/bin/sh\nREPO="PsychQuant/selfp"\nINSTALL_NAME="selfp"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl -sL "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION"\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/dev/fx-self/plugin/bin/selfp"
git init -q --bare "$T/remote-self.git" && ( cd "$T/dev/fx-self" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init && git remote add origin "$T/remote-self.git" && git push -q -u origin HEAD 2>/dev/null )
gh_stub 9.9.9 PsychQuant/selfp selfp
prep01 selfp
run_both "selfp: Step 0.1 resolves the ./plugin layout" 'plugin_holders "$PLUGIN_NAME" "$WANT_MP"' selfp "→ Step 0.1 OK: marketplace=fx-self"
run_both "selfp: Step 1 sees bin/selfp + binaryVersion" 'echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=' selfp "IS_BINARY_BACKED=true (bin:selfp pin:binaryVersion)"
run_both "selfp: Step 2 → Case E with entry has no version" 'BINARY_UNKNOWN_WHY' selfp "→ Phase 0.3 sync intent: Case E"
run_both "selfp: …entry has no version is named" 'BINARY_UNKNOWN_WHY' selfp "entry has no version"
unset PBM_GH PLUGIN_BIN_DIR

echo
echo "plugin-debug version query (root-level manifest lookup):"
SKILL="$PLUGIN_ROOT/skills/plugin-debug/SKILL.md"
run_both "plugin-debug reads the version through plugin_manifest_path" 'plugin_manifest_path "$SRC"' nobin "1.0.0"

MISSING_N=$(grep -c . "$HARNESS_MISSING" 2>/dev/null); MISSING_N=${MISSING_N:-0}; rm -f "$HARNESS_MISSING"
if [ "$MISSING_N" -gt 0 ]; then FAIL=$((FAIL + MISSING_N)); echo "  ✗ harness: ${MISSING_N} command(s) not found — an assertion did not run"; fi
echo; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
