#!/bin/bash
# Unit tests for plugin-binary-meta.sh (#22)
#
# Run: bash scripts/test-plugin-binary-meta.sh
# Exit 0 = all pass, 1 = any failure.
#
# Runs under /bin/bash (3.2 on macOS) on purpose — the helper is sourced by the
# agent's Bash tool, which is zsh, and by /bin/bash; it must not use bash 4+
# features. Every fixture lives under mktemp; nothing touches the network
# (latest_release_version is exercised through the PBM_GH stub).
#
# WHY THESE TESTS EXIST (#22): che-keychain 0.3.0 went through plugin-update
# with every binary-related phase silently doing nothing — `binaryVersion`
# instead of `binary_version`, a wrapper called `bin/che-keychain` (no
# -wrapper.sh suffix, `REPO=` not `GITHUB_REPO=`), a marketplace entry with no
# `version`, a session-start hook that delegates instead of curling. Each of
# those shapes is a fixture here, and the assertion is on what the helper
# SAYS — a value, an empty line, or a distinct rc — never on "it did not crash".

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ✗ $desc"
    echo "      expected: '$expected'"; echo "      actual:   '$actual'"
  fi
}
assert_rc() {   # desc expected_rc cmd...
  local desc="$1" expected="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$expected" ]; then PASS=$((PASS + 1)); echo "  ✓ $desc"
  else FAIL=$((FAIL + 1)); echo "  ✗ $desc (expected rc $expected, got $rc)"; fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
echo "Loading plugin-binary-meta.sh ..."
# shellcheck source=./plugin-binary-meta.sh
source "$SCRIPT_DIR/plugin-binary-meta.sh" || { echo "  ✗ cannot source helper"; exit 1; }

# ---- fixtures ---------------------------------------------------------------
# kc: che-keychain shape — bin/kc (no suffix), REPO=, INSTALL_NAME=, manifest binaryVersion,
#     session-start hook delegates (no curl), marketplace entry WITHOUT version
mkdir -p "$T/kc/.claude-plugin" "$T/kc/bin" "$T/kc/hooks"
cat > "$T/kc/.claude-plugin/plugin.json" <<'JSON'
{ "name": "kc", "version": "0.3.0", "binaryVersion": "0.2.0" }
JSON
cat > "$T/kc/bin/kc" <<'SH'
#!/bin/sh
REPO="PsychQuant/che-keychain"
INSTALL_NAME="che-keychain"
INSTALL_DIR="$HOME/bin"
DESIRED_VERSION=""
DESIRED_VERSION=$(grep -oE '"binaryVersion":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
[ -n "$DESIRED_VERSION" ] || DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
curl -sL "https://api.github.com/repos/$REPO/releases/latest"
SH
printf '#!/bin/sh\nexec "$(dirname "$0")/../bin/kc" --prefetch\n' > "$T/kc/hooks/session-start.sh"

# mcp: #77 schema — bin/x-wrapper.sh, GITHUB_REPO=, BINARY_NAME=, binary_version, .mcp.json
mkdir -p "$T/mcp/.claude-plugin" "$T/mcp/bin"
cat > "$T/mcp/.claude-plugin/plugin.json" <<'JSON'
{ "name": "mcp", "version": "1.4.0", "binary_version": "1.3.0" }
JSON
printf '{ "mcpServers": { "x": { "command": "bin/x-wrapper.sh" } } }\n' > "$T/mcp/.mcp.json"
cat > "$T/mcp/bin/x-wrapper.sh" <<'SH'
#!/bin/bash
GITHUB_REPO="PsychQuant/x-mcp"
BINARY_NAME="XMCP"
DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
URL=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest")
SH

# hookonly: gifthub shape — no bin/, hook curls releases, GFH_REPO=, $HOME/bin/gfh
mkdir -p "$T/hookonly/.claude-plugin" "$T/hookonly/hooks"
printf '{ "name": "hookonly", "version": "2.0.0" }\n' > "$T/hookonly/.claude-plugin/plugin.json"
cat > "$T/hookonly/hooks/session-start.sh" <<'SH'
#!/bin/sh
GFH_REPO="PsychQuant/GiftHub"
[ -x "$HOME/bin/gfh" ] || curl -sL "https://api.github.com/repos/$GFH_REPO/releases/latest"
SH

# pure: nothing binary about it
mkdir -p "$T/pure/.claude-plugin" "$T/pure/skills/p"
printf '{ "name": "pure", "version": "1.0.0" }\n' > "$T/pure/.claude-plugin/plugin.json"
printf '# p — mentions ~/bin/foo in prose only\n' > "$T/pure/skills/p/SKILL.md"

# both: manifest declares both keys (binary_version wins)
mkdir -p "$T/both/.claude-plugin"
printf '{ "name": "both", "version": "1.0.0", "binary_version": "1.0.0", "binaryVersion": "0.9.0" }\n' > "$T/both/.claude-plugin/plugin.json"

# tworepos: two wrappers pointing at different repos
mkdir -p "$T/tworepos/bin"
printf 'REPO="a/one"\ncurl https://api.github.com/repos/a/one/releases/latest\n' > "$T/tworepos/bin/w1.sh"
printf 'REPO="b/two"\ncurl https://github.com/b/two/releases/download/v1/x\n' > "$T/tworepos/bin/w2.sh"

# ghdl: wrapper that uses `gh release download` and a bare github.com/o/r/releases/tags URL
mkdir -p "$T/ghdl/bin"
printf '#!/bin/sh\ngh release download --repo PsychQuant/ghdl v1.0.0\n# see https://github.com/PsychQuant/ghdl/releases/tags/v1.0.0\n' > "$T/ghdl/bin/fetch"

# bad: illegal binary_version value; badrepo: repo with a path-traversal segment
mkdir -p "$T/bad/.claude-plugin" "$T/badrepo/bin"
printf '{ "name": "bad", "version": "1.0.0", "binary_version": "1.0.0; rm -rf x" }\n' > "$T/bad/.claude-plugin/plugin.json"
printf 'REPO="../etc/passwd"\ncurl https://api.github.com/repos/../etc/releases/latest\n' > "$T/badrepo/bin/w.sh"

# marketplace: kc entry without version, mcp entry with version, no entry for pure
mkdir -p "$T/mp/.claude-plugin"
cat > "$T/mp/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "mp", "plugins": [
  { "name": "kc", "source": "./kc" },
  { "name": "mcp", "version": "1.4.0", "source": "./mcp" }
] }
JSON
mkdir -p "$T/mpbad/.claude-plugin"; printf '{ not json\n' > "$T/mpbad/.claude-plugin/marketplace.json"

# sidecars for the installed-version query
mkdir -p "$T/bin"
printf '0.2.0\n' > "$T/bin/.che-keychain.version"
printf '1.2.0\n' > "$T/bin/.XMCP.version"
export PLUGIN_BIN_DIR="$T/bin" PBM_TEST=1

# gh stub: `release view --repo o/r --json tagName -q .tagName` → v9.9.9; PBM_STUB_FAIL=1 → rc 1
cat > "$T/gh-stub" <<'SH'
#!/bin/sh
[ -n "${PBM_STUB_FAIL:-}" ] && exit 1
case "$*" in
  "release view 0.2.0 --repo "*"--json assets"*) printf 'che-keychain\n' ;;
  *"--json assets"*) printf 'XMCP\nweird name\nche-keychain\n' ;;
  *"--repo NoV/plain"*) echo "9.9.9" ;;
  *) echo "v9.9.9" ;;
esac
SH
chmod +x "$T/gh-stub"

# R2 fixtures (#22 verify R1):
# docslink: a docs link BEFORE the assignment — the assignment must win, the link must not even be a candidate
mkdir -p "$T/docslink/bin"
printf '#!/bin/sh\n# Based on https://github.com/upstream/template — see docs\nGITHUB_REPO="PsychQuant/real-thing"\ncurl "https://api.github.com/repos/$GITHUB_REPO/releases/latest"\n' > "$T/docslink/bin/w.sh"
# dyn: assignment with a variable expansion → not a literal repo → rc 1 (never a truncated prefix)
mkdir -p "$T/dyn/bin"
printf 'REPO="owner/tool${FLAVOR}"\ncurl "https://api.github.com/repos/$REPO/releases/latest"\n' > "$T/dyn/bin/w.sh"
# indented: assignment inside a function + `export` form
mkdir -p "$T/indented/bin"
printf 'main() {\n  export REPO="PsychQuant/che-keychain"\n  curl -sL "https://api.github.com/repos/$REPO/releases/latest"\n}\nmain\n' > "$T/indented/bin/w"
# ghapi: `gh api repos/o/r/releases/latest` form (idd-close parity)
mkdir -p "$T/ghapi/bin"
printf '#!/bin/sh\ngh api repos/PsychQuant/ghapi/releases/latest\n' > "$T/ghapi/bin/fetch.sh"
# badfirst: an invalid BINARY_NAME in an alphabetically-earlier file must not blank out the real one
mkdir -p "$T/badfirst/bin"
printf 'BINARY_NAME="$binary_name"\ncurl https://api.github.com/repos/a/b/releases/latest\n' > "$T/badfirst/bin/aa-test.sh"
printf 'BINARY_NAME="RealBin"\nGITHUB_REPO="a/b"\ncurl https://api.github.com/repos/a/b/releases/latest\n' > "$T/badfirst/bin/zz-wrapper.sh"
# two: two wrappers, two binaries, one repo (che-telegram-mcp shape) + a test stub that is not a wrapper
mkdir -p "$T/two/bin"
printf 'BINARY_NAME="AllMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$GITHUB_REPO/releases/latest\n# docs: https://github.com/PsychQuant/psychquant-claude-plugins/blob/main/README.md\n' > "$T/two/bin/all-wrapper.sh"
printf 'BINARY_NAME="BotMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$GITHUB_REPO/releases/latest\n' > "$T/two/bin/bot-wrapper.sh"
printf 'echo "helper, not a wrapper"\n' > "$T/two/bin/setup.sh"
printf 'BINARY_NAME="stubborn-binary.sh"\necho "test stub: declares a name, downloads nothing"\n' > "$T/two/bin/test-wrapper-pid.sh"
printf '1.0.0\n' > "$T/bin/.AllMCP.version"; printf '0.9.0\n' > "$T/bin/.BotMCP.version"
# split: asset name != install name (che-mcps full form)
mkdir -p "$T/split/bin"
printf 'BINARY_NAME="CheKeychainMCP"\nINSTALL_NAME="che-keychain"\nREPO="PsychQuant/che-keychain"\ncurl https://api.github.com/repos/$REPO/releases/latest\n' > "$T/split/bin/w"
# verfb: no explicit pin, `version` is what the wrapper downloads (che-apple-notes-mcp shape)
mkdir -p "$T/verfb/.claude-plugin" "$T/verfb/bin"
printf '{ "name": "verfb", "version": "0.2.1" }\n' > "$T/verfb/.claude-plugin/plugin.json"
printf 'BINARY_NAME="NotesMCP"\nREPO="PsychQuant/notes"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON")\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION\n' "'\"version\":[[:space:]]*\"[^\"]+\"'" > "$T/verfb/bin/w.sh"
# lit: literal DESIRED_VERSION in the wrapper, manifest version is a DIFFERENT number (che-telegram-mcp / che-latex-mcp shape)
mkdir -p "$T/lit/.claude-plugin" "$T/lit/bin"
printf '{ "name": "lit", "version": "1.3.2" }\n' > "$T/lit/.claude-plugin/plugin.json"
printf 'BINARY_NAME="AllMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="0.5.0"\ncurl "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION"\n' > "$T/lit/bin/all-wrapper.sh"
# nopin: downloads latest, reads nothing → no pin at all
mkdir -p "$T/nopin/.claude-plugin" "$T/nopin/bin"
printf '{ "name": "nopin", "version": "2.0.0" }\n' > "$T/nopin/.claude-plugin/plugin.json"
printf 'BINARY_NAME="Fetch"\nREPO="a/fetch"\ncurl https://api.github.com/repos/$REPO/releases/latest\n' > "$T/nopin/bin/fetch.sh"
# twodiff: two wrappers with DIFFERENT literal pins
mkdir -p "$T/twodiff/bin"
printf 'BINARY_NAME="A"\nREPO="a/x"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION\n' > "$T/twodiff/bin/a.sh"
printf 'BINARY_NAME="B"\nREPO="a/x"\nDESIRED_VERSION="2.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION\n' > "$T/twodiff/bin/b.sh"
# hijack: a NON-wrapper helper assigns REPO= — it must not re-point the plugin
mkdir -p "$T/hijack/bin"
printf 'BINARY_NAME="RealBin"\ncurl https://github.com/real/thing/releases/download/v1/RealBin\n' > "$T/hijack/bin/real-wrapper.sh"
printf 'REPO="attacker/evil"\necho helper\n' > "$T/hijack/bin/helper.sh"
# mixed: a bin wrapper AND a hook that also curls releases (both are wrapper rows; dir column tells them apart)
mkdir -p "$T/mixed/bin" "$T/mixed/hooks"
printf 'BINARY_NAME="M"\nREPO="a/m"\ncurl https://api.github.com/repos/$REPO/releases/latest\n' > "$T/mixed/bin/m-wrapper.sh"
printf 'REPO="a/m"\ncurl https://api.github.com/repos/$REPO/releases/latest\n' > "$T/mixed/hooks/prefetch"
# emptymcp: .mcp.json is {} — not binary-backed (postgresql-guide)
mkdir -p "$T/emptymcp"; printf '{}\n' > "$T/emptymcp/.mcp.json"
# unsafe: wrapper whose FILENAME is shell-significant — must never be echoed
mkdir -p "$T/unsafe/bin"
printf 'curl https://api.github.com/repos/a/b/releases/latest\n' > "$T/unsafe/bin/kc; rm -rf x"

# ---------------------------------------------------------------------------
echo
echo "plugin_binary_version / plugin_binary_version_key:"
assert_eq "binaryVersion (camelCase) is read"        "0.2.0" "$(plugin_binary_version "$T/kc/.claude-plugin/plugin.json")"
assert_eq "binary_version (snake_case) is read"      "1.3.0" "$(plugin_binary_version "$T/mcp/.claude-plugin/plugin.json")"
assert_eq "no pin → empty (never falls back to version)" "" "$(plugin_binary_version "$T/pure/.claude-plugin/plugin.json")"
assert_rc "no pin → rc 0 (empty is an answer)"       0 plugin_binary_version "$T/pure/.claude-plugin/plugin.json"
assert_eq "both keys → binary_version wins"          "1.0.0" "$(plugin_binary_version "$T/both/.claude-plugin/plugin.json")"
assert_rc "unreadable manifest → rc 4"               4 plugin_binary_version "$T/nope/plugin.json"
assert_rc "illegal value → rc 3"                     3 plugin_binary_version "$T/bad/.claude-plugin/plugin.json"
assert_eq "illegal value → prints empty"             "" "$(plugin_binary_version "$T/bad/.claude-plugin/plugin.json")"
assert_eq "key: binaryVersion"                       "binaryVersion"  "$(plugin_binary_version_key "$T/kc/.claude-plugin/plugin.json")"
assert_eq "key: binary_version"                      "binary_version" "$(plugin_binary_version_key "$T/mcp/.claude-plugin/plugin.json")"
assert_rc "key: none → rc 1"                         1 plugin_binary_version_key "$T/pure/.claude-plugin/plugin.json"
assert_rc "key: both → rc 2"                         2 plugin_binary_version_key "$T/both/.claude-plugin/plugin.json"
assert_eq "key: both → prints binary_version"        "binary_version" "$(plugin_binary_version_key "$T/both/.claude-plugin/plugin.json")"
assert_rc "key: unreadable → rc 4"                   4 plugin_binary_version_key "$T/nope/plugin.json"

echo
echo "plugin_is_binary_backed:"
assert_eq "kc: bin/kc (no suffix) + pin are hits"    "bin:kc pin:binaryVersion" "$(plugin_is_binary_backed "$T/kc" "$T/kc/.claude-plugin/plugin.json")"
assert_rc "kc: rc 0"                                 0 plugin_is_binary_backed "$T/kc" "$T/kc/.claude-plugin/plugin.json"
assert_eq "mcp: .mcp.json + wrapper + pin"           "mcp.json bin:x-wrapper.sh pin:binary_version" "$(plugin_is_binary_backed "$T/mcp" "$T/mcp/.claude-plugin/plugin.json")"
assert_eq "hookonly: hook curl is a hit"             "hook:session-start.sh" "$(plugin_is_binary_backed "$T/hookonly" "$T/hookonly/.claude-plugin/plugin.json")"
assert_eq "pure: prose ~/bin/ is NOT a signal"       "" "$(plugin_is_binary_backed "$T/pure" "$T/pure/.claude-plugin/plugin.json")"
assert_rc "pure: rc 1"                               1 plugin_is_binary_backed "$T/pure" "$T/pure/.claude-plugin/plugin.json"
assert_eq "ghdl: gh release download counts"         "bin:fetch" "$(plugin_is_binary_backed "$T/ghdl")"
assert_eq "ghapi: gh api …/releases counts (idd-close parity)" "bin:fetch.sh" "$(plugin_is_binary_backed "$T/ghapi")"
assert_eq "manifest arg optional (kc without manifest → bin only)" "bin:kc" "$(plugin_is_binary_backed "$T/kc")"
assert_rc "missing dir → rc 1"                       1 plugin_is_binary_backed "$T/nope"

echo
echo "plugin_binary_repo:"
assert_eq "kc: REPO= assignment"                     "PsychQuant/che-keychain" "$(plugin_binary_repo "$T/kc")"
assert_eq "mcp: GITHUB_REPO= assignment"             "PsychQuant/x-mcp" "$(plugin_binary_repo "$T/mcp")"
assert_eq "hookonly: GFH_REPO= in hooks/"            "PsychQuant/GiftHub" "$(plugin_binary_repo "$T/hookonly")"
assert_eq "ghdl: from gh release download --repo / URL literal" "PsychQuant/ghdl" "$(plugin_binary_repo "$T/ghdl")"
assert_rc "pure: rc 1"                               1 plugin_binary_repo "$T/pure"
assert_eq "tworepos: first one printed"              "a/one" "$(plugin_binary_repo "$T/tworepos")"
assert_rc "tworepos: two ASSIGNMENTS → rc 2"         2 plugin_binary_repo "$T/tworepos"
assert_eq "docslink: assignment beats an earlier docs link" "PsychQuant/real-thing" "$(plugin_binary_repo "$T/docslink")"
assert_rc "docslink: the docs link is not a candidate → rc 0, not 2" 0 plugin_binary_repo "$T/docslink"
assert_rc "dyn: REPO=\"owner/tool\${FLAVOR}\" → rc 1 (no truncated prefix)" 1 plugin_binary_repo "$T/dyn"
assert_eq "dyn: prints empty"                        "" "$(plugin_binary_repo "$T/dyn")"
assert_eq "indented: assignment inside a function / export form" "PsychQuant/che-keychain" "$(plugin_binary_repo "$T/indented")"
assert_eq "ghapi: repo from gh api repos/o/r/releases" "PsychQuant/ghapi" "$(plugin_binary_repo "$T/ghapi")"
assert_eq "two: same repo in both wrappers, docs link ignored → one value" "PsychQuant/msg" "$(plugin_binary_repo "$T/two")"
assert_rc "two: rc 0 (not a spurious multi-repo warning)" 0 plugin_binary_repo "$T/two"
assert_rc "badrepo: traversal segment rejected → rc 1" 1 plugin_binary_repo "$T/badrepo"
assert_eq "badrepo: prints empty"                    "" "$(plugin_binary_repo "$T/badrepo")"

echo
echo "plugin_binary_name:"
assert_eq "mcp: BINARY_NAME="                        "XMCP" "$(plugin_binary_name "$T/mcp")"
assert_eq "kc: INSTALL_NAME="                        "che-keychain" "$(plugin_binary_name "$T/kc")"
assert_eq "hookonly: \$HOME/bin/<name> in hook"      "gfh" "$(plugin_binary_name "$T/hookonly")"
assert_rc "pure: rc 1"                               1 plugin_binary_name "$T/pure"
assert_eq "badfirst: invalid BINARY_NAME in an earlier file is skipped, real one found" "RealBin" "$(plugin_binary_name "$T/badfirst")"
assert_eq "split: asset name is BINARY_NAME"          "CheKeychainMCP" "$(plugin_binary_name "$T/split")"
key=SENTINEL; plugin_binary_name "$T/mcp" >/dev/null; assert_eq "plugin_binary_name leaves no \$key behind" "SENTINEL" "$key"

echo
echo "plugin_install_names / plugin_binary_wrappers:"
assert_eq "split: install name is INSTALL_NAME (sidecar key)" "che-keychain" "$(plugin_install_names "$T/split")"
assert_eq "two: both binaries listed, stub excluded"  "AllMCP
BotMCP" "$(plugin_install_names "$T/two")"
assert_eq "two: one row per wrapper file, dir|file|asset|install|repo|pin|pinsrc" "bin|all-wrapper.sh|AllMCP|AllMCP|PsychQuant/msg|1.0.0|wrapper:all-wrapper.sh
bin|bot-wrapper.sh|BotMCP|BotMCP|PsychQuant/msg|1.0.0|wrapper:bot-wrapper.sh" "$(plugin_binary_wrappers "$T/two")"
assert_eq "kc: row reads binaryVersion from the manifest" "bin|kc|che-keychain|che-keychain|PsychQuant/che-keychain|0.2.0|binaryVersion" "$(plugin_binary_wrappers "$T/kc" "$T/kc/.claude-plugin/plugin.json")"
assert_eq "kc without manifest: the key is named, the value is unknown" "bin|kc|che-keychain|che-keychain|PsychQuant/che-keychain||binaryVersion" "$(plugin_binary_wrappers "$T/kc")"
assert_eq "hookonly: hook row carries dir=hooks"     "hooks|session-start.sh|gfh|gfh|PsychQuant/GiftHub||none" "$(plugin_binary_wrappers "$T/hookonly")"
assert_eq "mixed: bin and hooks rows, both wrappers"  "bin|m-wrapper.sh|M|M|a/m||none
hooks|prefetch|||a/m||none" "$(plugin_binary_wrappers "$T/mixed")"
assert_rc "pure: no wrappers → rc 1"                  1 plugin_binary_wrappers "$T/pure"
assert_eq "unsafe: shell-significant filename is printed as ?" "bin|?|||a/b||none" "$(plugin_binary_wrappers "$T/unsafe")"
assert_eq "hijack: the non-wrapper helper is not a row" "bin|real-wrapper.sh|RealBin|RealBin|real/thing||none" "$(plugin_binary_wrappers "$T/hijack")"
assert_eq "hijack: plugin_binary_repo ignores REPO= in a non-wrapper file" "real/thing" "$(plugin_binary_repo "$T/hijack")"
assert_rc "hijack: rc 0 (no spurious conflict)"      0 plugin_binary_repo "$T/hijack"
assert_eq "emptymcp: .mcp.json {} is not a signal"    "" "$(plugin_is_binary_backed "$T/emptymcp")"
assert_eq "unsafe: hit list shows bin:? not the raw name" "bin:?" "$(plugin_is_binary_backed "$T/unsafe")"

env_notest_installed() { PBM_TEST= plugin_installed_binary_version "$T/mcp"; }
echo
echo "plugin_installed_binary_version:"
assert_eq "kc: reads \$PLUGIN_BIN_DIR/.che-keychain.version" "0.2.0" "$(plugin_installed_binary_version "$T/kc")"
assert_eq "mcp: reads .XMCP.version"                 "1.2.0" "$(plugin_installed_binary_version "$T/mcp")"
assert_rc "hookonly: name known, sidecar missing → rc 1" 1 plugin_installed_binary_version "$T/hookonly"
assert_rc "PLUGIN_BIN_DIR is ignored without PBM_TEST=1 → real ~/bin has no .XMCP.version → rc 1" 1 env_notest_installed
assert_rc "pure: no name → rc 2 (UNKNOWN, not 'not installed')" 2 plugin_installed_binary_version "$T/pure"
assert_eq "two: explicit name reads that binary's sidecar" "0.9.0" "$(plugin_installed_binary_version "$T/two" BotMCP)"
assert_rc "explicit unsafe name → rc 2"               2 plugin_installed_binary_version "$T/two" 'x; rm'

echo
echo "plugin_binary_pin (value|pinsrc — what the wrapper downloads; three closed sources, no plugin-wide fallback):"
assert_eq "kc: wrapper greps binaryVersion → manifest binaryVersion" "0.2.0|binaryVersion" "$(plugin_binary_pin "$T/kc" "$T/kc/.claude-plugin/plugin.json")"
assert_eq "mcp: wrapper greps binary_version"          "1.3.0|binary_version" "$(plugin_binary_pin "$T/mcp" "$T/mcp/.claude-plugin/plugin.json")"
assert_eq "verfb: wrapper greps version → manifest version is the pin" "0.2.1|version" "$(plugin_binary_pin "$T/verfb" "$T/verfb/.claude-plugin/plugin.json")"
assert_eq "lit: literal DESIRED_VERSION beats a different manifest version" "0.5.0|wrapper:all-wrapper.sh" "$(plugin_binary_pin "$T/lit" "$T/lit/.claude-plugin/plugin.json")"
assert_rc "nopin: wrapper reads nothing → rc 1, manifest version is NOT used" 1 plugin_binary_pin "$T/nopin" "$T/nopin/.claude-plugin/plugin.json"
assert_eq "nopin: prints |none"                       "|none" "$(plugin_binary_pin "$T/nopin" "$T/nopin/.claude-plugin/plugin.json")"
assert_eq "two: both literals agree"                  "1.0.0|wrapper:all-wrapper.sh" "$(plugin_binary_pin "$T/two" /nonexistent)"
assert_rc "two: rc 0"                                 0 plugin_binary_pin "$T/two" /nonexistent
assert_rc "twodiff: wrappers disagree → rc 2"         2 plugin_binary_pin "$T/twodiff" /nonexistent
assert_eq "twodiff: first printed"                    "1.0.0|wrapper:a.sh" "$(plugin_binary_pin "$T/twodiff" /nonexistent)"
assert_rc "pure: no wrappers → rc 1"                  1 plugin_binary_pin "$T/pure" "$T/pure/.claude-plugin/plugin.json"
assert_rc "hookonly: hooks rows do not count as the plugin pin → rc 1" 1 plugin_binary_pin "$T/hookonly" "$T/hookonly/.claude-plugin/plugin.json"

echo
echo "marketplace_entry_version:"
assert_eq "entry with version"                       "1.4.0" "$(marketplace_entry_version "$T/mp" mcp)"
assert_eq "entry without version → empty"            "" "$(marketplace_entry_version "$T/mp" kc)"
assert_rc "entry without version → rc 0"             0 marketplace_entry_version "$T/mp" kc
assert_rc "no entry → rc 1"                          1 marketplace_entry_version "$T/mp" pure
assert_rc "unparsable manifest → rc 4"               4 marketplace_entry_version "$T/mpbad" kc
assert_rc "missing manifest → rc 4"                  4 marketplace_entry_version "$T/nope" kc

echo
echo "latest_release_version (PBM_GH stub, no network):"
assert_eq "tag v9.9.9 → 9.9.9"                       "9.9.9" "$(PBM_GH="$T/gh-stub" latest_release_version PsychQuant/che-keychain)"
assert_eq "tag without v prefix passes through"      "9.9.9" "$(PBM_GH="$T/gh-stub" latest_release_version NoV/plain)"
lrv_fail() { PBM_GH="$T/gh-stub" PBM_STUB_FAIL=1 latest_release_version "$@"; }   # `env` cannot run a shell function
lrv_nogh() { PBM_GH=/nonexistent latest_release_version "$@"; }
lrv_rel()  { PBM_GH=gh-stub latest_release_version "$@"; }   # relative PBM_GH must be refused, not searched on PATH
lrv_notest() { PBM_TEST= PBM_GH="$T/gh-stub" latest_release_version "$@"; }   # without PBM_TEST=1 the seam is ignored → real gh (unreachable repo → rc 1)
assert_rc "gh failure → rc 1"                        1 lrv_fail PsychQuant/che-keychain
assert_eq "gh failure → prints empty"                "" "$(lrv_fail PsychQuant/che-keychain)"
assert_rc "malformed repo arg → rc 1 without calling gh" 1 lrv_nogh 'bad repo'
assert_rc "relative PBM_GH → rc 1 (test seam takes absolute paths only)" 1 lrv_rel PsychQuant/che-keychain
assert_eq "PBM_GH is ignored without PBM_TEST=1 (stub never answers 9.9.9)" "" "$( [ "$(lrv_notest Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "release_assets with a tag queries that release" "che-keychain" "$(PBM_GH="$T/gh-stub" release_assets PsychQuant/che-keychain 0.2.0)"
assert_eq "release_assets: unprintable name shows as ? (absent ≠ unprintable)" "XMCP
?
che-keychain" "$(PBM_GH="$T/gh-stub" release_assets PsychQuant/x-mcp)"
ra_fail() { PBM_GH="$T/gh-stub" PBM_STUB_FAIL=1 release_assets "$@"; }
assert_rc "release_assets: gh failure → rc 1 (UNKNOWN, not 'missing')" 1 ra_fail PsychQuant/x-mcp

echo
echo "version_gt:"
assert_rc "0.3.0 > 0.2.0"                            0 version_gt 0.3.0 0.2.0
assert_rc "0.2.0 > 0.3.0 is false"                   1 version_gt 0.2.0 0.3.0
assert_rc "equal is not greater"                     1 version_gt 1.0.0 1.0.0
assert_rc "10.0.0 > 9.9.9 (numeric, not lexical)"    0 version_gt 10.0.0 9.9.9
assert_rc "1.0.0-beta → rc 2 (not comparable)"       2 version_gt 1.0.0-beta 1.0.0
assert_rc "empty → rc 2"                             2 version_gt "" 1.0.0

# ---------------------------------------------------------------------------
echo
echo "zsh compatibility (the Bash tool is zsh; no word-split, nomatch on):"
if command -v zsh >/dev/null 2>&1; then
  ZSH_HITS=$(PBM_TEST=1 PLUGIN_BIN_DIR="$T/bin" zsh -c "source '$SCRIPT_DIR/plugin-binary-meta.sh' && plugin_is_binary_backed '$T/mcp' '$T/mcp/.claude-plugin/plugin.json'" 2>/dev/null)
  assert_eq "zsh: same hit list as bash" "mcp.json bin:x-wrapper.sh pin:binary_version" "$ZSH_HITS"
  ZSH_REPO=$(zsh -c "source '$SCRIPT_DIR/plugin-binary-meta.sh' && plugin_binary_repo '$T/tworepos'; echo \"rc=\$?\"" 2>/dev/null)
  assert_eq "zsh: tworepos first + rc 2" "a/one
rc=2" "$ZSH_REPO"
  ZSH_NOISE=$(zsh -c "source '$SCRIPT_DIR/plugin-binary-meta.sh' && plugin_binary_version '$T/nope/x.json'; plugin_binary_repo '$T/pure'; plugin_is_binary_backed '$T/nope'; marketplace_entry_version '$T/mpbad' kc; version_gt a b; PBM_GH=/nonexistent latest_release_version a/b" 2>&1 >/dev/null)
  assert_eq "zsh: lookups emit no stderr" "" "$ZSH_NOISE"
else
  echo "  ⊘ zsh not on PATH — skipped"
fi
BASH_NOISE=$( { plugin_binary_version "$T/nope/x.json"; plugin_binary_repo "$T/pure"; plugin_is_binary_backed "$T/nope"; marketplace_entry_version "$T/mpbad" kc; version_gt a b; PBM_GH=/nonexistent latest_release_version a/b; } 2>&1 >/dev/null )
assert_eq "bash: lookups emit no stderr" "" "$BASH_NOISE"

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
