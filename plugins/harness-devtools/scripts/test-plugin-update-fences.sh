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
mkdir -p "$T/dev/fx-mp/.claude-plugin" "$T/dev/fx-mp/plugins/nobin/.claude-plugin" "$T/dev/fx-mp/plugins/nobin/hooks" "$T/dev/fx-mp/plugins/nobin/skills/s"
cat > "$T/dev/fx-mp/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fx-mp", "plugins": [ { "name": "nobin", "version": "1.0.0", "source": "./plugins/nobin" } ] }
JSON
printf '{ "name": "nobin", "version": "1.0.0" }\n' > "$T/dev/fx-mp/plugins/nobin/.claude-plugin/plugin.json"
printf '#!/bin/sh\ncurl -s https://api.github.com/repos/x/y/releases/latest\n' > "$T/dev/fx-mp/plugins/nobin/hooks/session-start.sh"
printf '# s\n' > "$T/dev/fx-mp/plugins/nobin/skills/s/SKILL.md"
( cd "$T/dev/fx-mp" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init ) 2>/dev/null

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

echo; echo "─────────────────────────────"; echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
