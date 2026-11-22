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
RELEASE_ASSET="CheKeychain"
DESIRED_VERSION=""
DESIRED_VERSION=$(grep -oE '"binaryVersion":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
[ -n "$DESIRED_VERSION" ] || DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
curl -sL "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" "https://api.github.com/repos/$REPO/releases/latest"
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
URL=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME")
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
export PLUGIN_BIN_DIR="$T/bin" PBM_TEST=1 PBM_TEST_ROOT="$T"; cd "$T"   # the seam is live only under PBM_TEST_ROOT

# gh stub: `release view --repo o/r --json tagName -q .tagName` → v9.9.9; PBM_STUB_FAIL=1 → rc 1
cat > "$T/gh-stub" <<'SH'
#!/bin/sh
[ -n "${PBM_STUB_FAIL:-}" ] && exit 1
case "$*" in
  "release view v0.2.0 --repo "*"--json assets"*) printf 'CheKeychain\n' ;;
  "release view 1.0.0 --repo Bare/only "*"--json assets"*) printf 'BareBin\n' ;;   # a repo whose tags carry no v
  "release view --repo "*"--json assets"*) printf 'XMCP\nweird name\nche-keychain\n' ;;   # no tag: latest
  "release view "*"--json assets"*) exit 1 ;;   # any other explicit tag: release not found (v9.9.9 / 0.3.0 / v1.0.0 on Bare/only)
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
printf 'BINARY_NAME="$binary_name"\ncurl https://api.github.com/repos/a/b/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/badfirst/bin/aa-test.sh"
printf 'BINARY_NAME="RealBin"\nGITHUB_REPO="a/b"\ncurl https://api.github.com/repos/a/b/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/badfirst/bin/zz-wrapper.sh"
# two: two wrappers, two binaries, one repo (che-telegram-mcp shape) + a test stub that is not a wrapper
mkdir -p "$T/two/bin"
printf 'BINARY_NAME="AllMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n# docs: https://github.com/PsychQuant/psychquant-claude-plugins/blob/main/README.md\n' > "$T/two/bin/all-wrapper.sh"
printf 'BINARY_NAME="BotMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/$GITHUB_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/two/bin/bot-wrapper.sh"
printf 'echo "helper, not a wrapper"\n' > "$T/two/bin/setup.sh"
printf 'BINARY_NAME="stubborn-binary.sh"\necho "test stub: declares a name, downloads nothing"\n' > "$T/two/bin/test-wrapper-pid.sh"
printf '1.0.0\n' > "$T/bin/.AllMCP.version"; printf '0.9.0\n' > "$T/bin/.BotMCP.version"
# split: asset name != install name (che-mcps full form)
mkdir -p "$T/split/bin"
printf 'BINARY_NAME="CheKeychainMCP"\nINSTALL_NAME="che-keychain"\nREPO="PsychQuant/che-keychain"\ncurl https://api.github.com/repos/$REPO/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/split/bin/w"
# verfb: no explicit pin, `version` is what the wrapper downloads (che-apple-notes-mcp shape)
mkdir -p "$T/verfb/.claude-plugin" "$T/verfb/bin"
printf '{ "name": "verfb", "version": "0.2.1" }\n' > "$T/verfb/.claude-plugin/plugin.json"
printf 'BINARY_NAME="NotesMCP"\nREPO="PsychQuant/notes"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON")\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"version\":[[:space:]]*\"[^\"]+\"'" > "$T/verfb/bin/w.sh"
# lit: literal DESIRED_VERSION in the wrapper, manifest version is a DIFFERENT number (che-telegram-mcp / che-latex-mcp shape)
mkdir -p "$T/lit/.claude-plugin" "$T/lit/bin"
printf '{ "name": "lit", "version": "1.3.2" }\n' > "$T/lit/.claude-plugin/plugin.json"
printf 'BINARY_NAME="AllMCP"\nGITHUB_REPO="PsychQuant/msg"\nDESIRED_VERSION="0.5.0"\ncurl "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$DESIRED_VERSION" | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/lit/bin/all-wrapper.sh"
# nopin: downloads latest, reads nothing → no pin at all
mkdir -p "$T/nopin/.claude-plugin" "$T/nopin/bin"
printf '{ "name": "nopin", "version": "2.0.0" }\n' > "$T/nopin/.claude-plugin/plugin.json"
printf 'BINARY_NAME="Fetch"\nREPO="a/fetch"\ncurl https://api.github.com/repos/$REPO/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/nopin/bin/fetch.sh"
# twodiff: two wrappers with DIFFERENT literal pins
mkdir -p "$T/twodiff/bin"
printf 'BINARY_NAME="A"\nREPO="a/x"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/twodiff/bin/a.sh"
printf 'BINARY_NAME="B"\nREPO="a/x"\nDESIRED_VERSION="2.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/twodiff/bin/b.sh"
# hijack: a NON-wrapper helper assigns REPO= — it must not re-point the plugin
mkdir -p "$T/hijack/bin"
printf 'BINARY_NAME="RealBin"\ncurl https://github.com/real/thing/releases/download/v1/RealBin\n' > "$T/hijack/bin/real-wrapper.sh"
printf 'REPO="attacker/evil"\necho helper\n' > "$T/hijack/bin/helper.sh"
# mixed: a bin wrapper AND a hook that also curls releases (both are wrapper rows; dir column tells them apart)
mkdir -p "$T/mixed/bin" "$T/mixed/hooks"
printf 'BINARY_NAME="M"\nREPO="a/m"\ncurl https://api.github.com/repos/$REPO/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/mixed/bin/m-wrapper.sh"
printf 'REPO="a/m"\ncurl https://api.github.com/repos/$REPO/releases/latest\n' > "$T/mixed/hooks/prefetch"
# emptymcp: .mcp.json is {} — not binary-backed (postgresql-guide)
mkdir -p "$T/emptymcp"; printf '{}\n' > "$T/emptymcp/.mcp.json"
# unsafe: wrapper whose FILENAME is shell-significant — must never be echoed
mkdir -p "$T/unsafe/bin"
printf 'curl https://api.github.com/repos/a/b/releases/latest\n' > "$T/unsafe/bin/kc; rm -rf x"
# R4 fixtures (#22 verify R3):
# spaced: macdoc-family wrapper — greps '"binary_version"[[:space:]]*:' (a `[` right after the closing quote), comment lines
#         mention ("version") BEFORE ("binary_version"); pin must be binary_version 4.0.10, not version 4.0.12
mkdir -p "$T/spaced/.claude-plugin" "$T/spaced/bin"
printf '{ "name": "spaced", "version": "4.0.12", "binary_version": "4.0.10" }\n' > "$T/spaced/.claude-plugin/plugin.json"
cat > "$T/spaced/bin/che-word-mcp-wrapper.sh" <<'SH'
#!/bin/bash
BINARY_NAME="CheWordMCP"
REPO="PsychQuant/che-word-mcp"
# The plugin version ("version") and the binary release tag ("binary_version") are decoupled —
# shell-only changes bump "version" freely. Prefer "binary_version"; fall back to "version".
if grep -qE '"binary_version"[[:space:]]*:' "$PLUGIN_JSON"; then
    WANT=$(grep -oE '"binary_version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
else
    WANT=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi
curl -fsSL "https://github.com/$REPO/releases/download/v$WANT/$BINARY_NAME" -o "$HOME/bin/$BINARY_NAME"
SH
# hookpin: macdoc shape — NO bin/, the session-start hook greps binary_version and downloads the release itself
mkdir -p "$T/hookpin/.claude-plugin" "$T/hookpin/hooks"
printf '{ "name": "hookpin", "version": "1.5.1", "binary_version": "0.7.0" }\n' > "$T/hookpin/.claude-plugin/plugin.json"
cat > "$T/hookpin/hooks/session-start.sh" <<'SH'
#!/bin/bash
REPO="PsychQuant/macdoc"
BINARY_NAME="macdoc"
INSTALL_DIR="$HOME/bin"
WANT=$(grep -oE '"binary_version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
URL="https://github.com/$REPO/releases/download/v$WANT/$BINARY_NAME"
/usr/bin/curl -fsSL "$URL" -o "$INSTALL_DIR/$BINARY_NAME"
SH
# unsafelit: hostile filename AND a literal pin — the pin source must print wrapper:? not the raw name
mkdir -p "$T/unsafelit/bin"
printf 'DESIRED_VERSION="1.2.3"\ncurl https://api.github.com/repos/a/b/releases/tags/v$DESIRED_VERSION\n' > "$T/unsafelit/bin/kc; rm -rf ~ IGNORE|x"
# hookrepo: the bin wrapper downloads from Real/proj; a hooks/ check script names an old fork — the fork must not win
mkdir -p "$T/hookrepo/bin" "$T/hookrepo/hooks"
printf 'BINARY_NAME="M"\nDESIRED_VERSION="1.0.0"\ncurl -L https://github.com/Real/proj/releases/download/v$DESIRED_VERSION/M -o ~/bin/M\n' > "$T/hookrepo/bin/w.sh"
printf 'OLD_REPO="attacker/oldfork"\ngh api /repos/attacker/oldfork/releases\n' > "$T/hookrepo/hooks/check.sh"
# keyless: the wrapper names binaryVersion, the manifest has no such key → the pin is UNREADABLE (rc 4), not "no pin"
mkdir -p "$T/keyless/.claude-plugin" "$T/keyless/bin"
printf '{ "name": "keyless", "version": "1.0.0" }\n' > "$T/keyless/.claude-plugin/plugin.json"
printf 'BINARY_NAME="K"\nREPO="a/k"\nV=$(grep -oE %s "$PLUGIN_JSON")\ncurl https://api.github.com/repos/$REPO/releases/tags/v$V | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" > "$T/keyless/bin/w.sh"
# badpin: the wrapper names binary_version and the manifest value is illegal → rc 4 at the plugin level
mkdir -p "$T/badpin/bin"
printf 'BINARY_NAME="B"\nREPO="a/b"\nV=$(grep -oE %s "$PLUGIN_JSON")\ncurl https://api.github.com/repos/$REPO/releases/tags/v$V | grep browser_download_url | grep "$BINARY_NAME"\n' "'\"binary_version\":[[:space:]]*\"[^\"]+\"'" > "$T/badpin/bin/w.sh"
# commentonly: the only release URL is in a comment → not a wrapper
mkdir -p "$T/commentonly/bin"
printf '#!/bin/sh\n# see https://github.com/a/b/releases/latest\necho helper\n' > "$T/commentonly/bin/doc.sh"
# cmtrepo: the only literal release URL is in a comment; the real download uses a dynamic repo → repo must be UNKNOWN (rc 1), not the comment's
mkdir -p "$T/cmtrepo/bin"
printf '#!/bin/sh\n# example: https://github.com/template/example/releases/latest\nREPO="${OWNER}/${PROJECT}"\ngh release download --repo "$REPO"\n' > "$T/cmtrepo/bin/w.sh"
# cmtbin: `$HOME/bin/<name>` appears only in a comment; the code installs elsewhere → install name must NOT come from the comment
mkdir -p "$T/cmtbin/hooks"
printf '#!/bin/sh\n# installs to $HOME/bin/evil-name\nREPO="a/b"\ncurl https://api.github.com/repos/$REPO/releases/latest -o "$TMP/x"\n' > "$T/cmtbin/hooks/session-start.sh"
# installonly: BINARY_NAME= is only the install target (downloads by a URL that does not use it) → asset undeclared
mkdir -p "$T/installonly/bin"
printf 'BINARY_NAME="che-latex-mcp"\nREPO="a/latex"\ncurl -L "https://github.com/$REPO/releases/download/v1.0.0/CheLatexMCP" -o "$HOME/bin/$BINARY_NAME"\n' > "$T/installonly/bin/w.sh"
# mixrepo: one wrapper names its repo by assignment, the other by URL literal — a DIFFERENT repo; the merge must see both (R5 HIGH)
mkdir -p "$T/mixrepo/bin"
printf 'REPO="a/one"\nDESIRED_VERSION="1.0.0"\ngh release download --repo "$REPO"\n' > "$T/mixrepo/bin/a.sh"
printf 'DESIRED_VERSION="1.0.0"\ncurl https://github.com/b/two/releases/download/v1.0.0/B\n' > "$T/mixrepo/bin/b.sh"
# unusedrepo: a *_REPO= assignment that nothing downloads through is not a candidate; the URL literal is the repo
mkdir -p "$T/unusedrepo/bin"
printf 'DOCS_REPO="docs/site"\nBINARY_NAME="R"\ncurl https://github.com/real/thing/releases/download/v1/R\n' > "$T/unusedrepo/bin/w.sh"
# override: a literal default followed by a manifest read — the manifest wins (R5 HIGH)
mkdir -p "$T/override/.claude-plugin" "$T/override/bin"
printf '{ "name": "override", "version": "2.0.0", "binaryVersion": "2.0.0" }\n' > "$T/override/.claude-plugin/plugin.json"
printf 'REPO="a/o"\nDESIRED_VERSION="1.0.0"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/override/bin/w.sh"
# overrideunk: a literal default followed by an override the helper cannot read → source known, value not (rc 4), never the stale default
mkdir -p "$T/overrideunk/bin"
printf 'REPO="a/o"\nDESIRED_VERSION="1.0.0"\nDESIRED_VERSION="${PIN_OVERRIDE:-$DESIRED_VERSION}"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION\n' > "$T/overrideunk/bin/w.sh"
# dotname: BINARY_NAME with a dot must not match a URL where the dot is some other character
mkdir -p "$T/dotname/bin"
printf 'BINARY_NAME="a.b"\nREPO="a/d"\ncurl https://github.com/$REPO/releases/download/v1/axb\n' > "$T/dotname/bin/w.sh"
# condover: a literal default overridden by a CONDITIONAL assignment later on the line — not readable → rc 4 (R6 MEDIUM)
mkdir -p "$T/condover/bin"
printf 'REPO="a/c"\nDESIRED_VERSION="1.0.0"\n[ -z "$PIN_OVERRIDE" ] || DESIRED_VERSION="$PIN_OVERRIDE"\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/Bin\n' > "$T/condover/bin/w.sh"
# jqpin: the wrapper reads binaryVersion through jq (no `"key":` shape) → the key is named but not followable → rc 4, not none
mkdir -p "$T/jqpin/.claude-plugin" "$T/jqpin/bin"
printf '{ "name": "jqpin", "version": "1.0.0", "binaryVersion": "2.0.0" }\n' > "$T/jqpin/.claude-plugin/plugin.json"
printf 'BINARY_NAME="J"\nREPO="a/j"\nV=$(jq -r .binaryVersion "$PLUGIN_JSON")\ncurl https://github.com/$REPO/releases/download/v$V/$BINARY_NAME\n' > "$T/jqpin/bin/j.sh"
# movingref: DESIRED_VERSION="latest" is not a pin → rc 4 (never a value Phase 5 would compare against)
mkdir -p "$T/movingref/bin"
printf 'BINARY_NAME="M"\nREPO="a/m"\nDESIRED_VERSION="latest"\ncurl https://github.com/$REPO/releases/download/$DESIRED_VERSION/$BINARY_NAME\n' > "$T/movingref/bin/w.sh"
# mfover: manifest read followed by an override the helper cannot follow → rc 4 (the manifest key is NOT what downloads) (R7 HIGH)
mkdir -p "$T/mfover/.claude-plugin" "$T/mfover/bin"
printf '{ "name": "mfover", "version": "1.0.0", "binaryVersion": "2.0.0" }\n' > "$T/mfover/.claude-plugin/plugin.json"
printf 'BINARY_NAME="F"\nREPO="a/f"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\nDESIRED_VERSION="${PIN_OVERRIDE:-$DESIRED_VERSION}"\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/mfover/bin/w.sh"
# twouncond: TWO unconditional manifest reads — the LAST one is what downloads; the earlier key must not win (R8 HIGH #1)
mkdir -p "$T/twouncond/.claude-plugin" "$T/twouncond/bin"
printf '{ "name": "twouncond", "version": "2.0.0", "binary_version": "1.0.0" }\n' > "$T/twouncond/.claude-plugin/plugin.json"
printf 'BINARY_NAME="U"\nREPO="a/u"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' "'\"binary_version\":[[:space:]]*\"[^\"]+\"'" "'\"'" "'\"version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/twouncond/bin/w.sh"
# indentfb: manifest read, then an INDENTED literal default inside `if [ -z … ]` — a fallback, not the pin (R8 MEDIUM #4)
mkdir -p "$T/indentfb/.claude-plugin" "$T/indentfb/bin" "$T/indentfb2/.claude-plugin" "$T/indentfb2/bin"
printf '{ "name": "indentfb", "version": "9.0.0", "binaryVersion": "0.3.0" }\n' > "$T/indentfb/.claude-plugin/plugin.json"
printf '{ "name": "indentfb2", "version": "9.0.0" }\n' > "$T/indentfb2/.claude-plugin/plugin.json"
for d in indentfb indentfb2; do printf 'BINARY_NAME="I"\nREPO="a/i"\nDESIRED_VERSION=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\nif [ -z "$DESIRED_VERSION" ]; then\n    DESIRED_VERSION="0.0.0"        # fallback default\nfi\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' "'\"binaryVersion\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/$d/bin/w.sh"; done
# mention: lines that merely MENTION `DESIRED_VERSION=` (echo / grep) are not assignments (R8 LOW #11)
mkdir -p "$T/mention/bin"
printf 'BINARY_NAME="N"\nREPO="a/n"\nDESIRED_VERSION="1.2.3"\necho "DESIRED_VERSION=$DESIRED_VERSION"\ngrep -q %s "$0"\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' "'DESIRED_VERSION='" > "$T/mention/bin/w.sh"
# tworepo1: ONE wrapper that downloads from two repos (primary || fallback) — a multi-repo plugin, not "a/one" (R8 HIGH #2)
mkdir -p "$T/tworepo1/bin"
printf 'BINARY_NAME="P"\nPRIMARY_REPO="a/one"\nFALLBACK_REPO="b/two"\nDESIRED_VERSION="1.0.0"\ncurl https://github.com/$PRIMARY_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME || curl https://github.com/$FALLBACK_REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/tworepo1/bin/w.sh"
# quotedrepo: the gh idiom with QUOTES — `--repo "o/q"` and `gh api "repos/o/q/…"` (R8 MEDIUM #9)
mkdir -p "$T/quotedrepo/bin"
printf 'BINARY_NAME="Q"\nDESIRED_VERSION="1.0.0"\ngh release download "v$DESIRED_VERSION" --repo "o/q" -p "$BINARY_NAME"\n' > "$T/quotedrepo/bin/a.sh"
printf 'DESIRED_VERSION="1.0.0"\ngh api "repos/o/q/releases/latest"\n' > "$T/quotedrepo/bin/b.sh"
# projvar: the repo lives in a variable NOT named *REPO, interpolated into the release URL (issue point 2; R8 LOW #10)
mkdir -p "$T/projvar/bin"
printf 'BINARY_NAME="V"\nPROJ="Owner/Repo"\nDESIRED_VERSION="1.0.0"\ncurl https://github.com/$PROJ/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/projvar/bin/w.sh"
# nothost: `notgithub.example/o/r/releases/download` — a release-shaped URL on another host names NO GitHub repo (R8 LOW #15)
mkdir -p "$T/nothost/bin"
printf 'DESIRED_VERSION="1.0.0"\ncurl -sL "https://notgithub.example/PsychQuant/che-keychain/releases/download/v$DESIRED_VERSION/B"\n' > "$T/nothost/bin/w.sh"
# unkmcp: .mcp.json that does not parse — "cannot answer", not "no" (R8 LOW #19)
mkdir -p "$T/unkmcp"; printf '{ not json\n' > "$T/unkmcp/.mcp.json"
mkdir -p "$T/unkmf"; printf '{ "name": "unkmf"\n' > "$T/unkmf/bad.json"
# R10 closed shapes — the R9 counter-examples (each must be rc 4, never a guess) and the real corpus shapes (each must resolve)
for d in fnindent sameline archover trailcmt mailshape pdfshape; do mkdir -p "$T/$d/bin" "$T/$d/.claude-plugin"
  printf '{ "name": "r", "version": "2.0.0", "binaryVersion": "0.3.0", "binary_version": "0.4.0" }\n' > "$T/$d/.claude-plugin/plugin.json"; done
printf '{ "name": "p", "version": "2.0.0" }\n' > "$T/pdfshape/.claude-plugin/plugin.json"
mkdir -p "$T/pdfempty/bin" "$T/pdfempty/.claude-plugin"; printf '{ "name": "p", "version": "2.0.0", "binary_version": "" }\n' > "$T/pdfempty/.claude-plugin/plugin.json"
cat > "$T/fnindent/bin/w.sh" <<'W'
REPO="a/f"
main() {
  DESIRED_VERSION="1.0.0"
  DESIRED_VERSION="2.0.0"
  curl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/F
}
W
cat > "$T/sameline/bin/w.sh" <<'W'
REPO="a/s"
DESIRED_VERSION=$(cat /etc/override) || DESIRED_VERSION="1.0.0"
curl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/S
W
cat > "$T/archover/bin/w.sh" <<'W'
REPO="a/u"
DESIRED_VERSION="1.0.0"
if [ "$(uname -m)" = x86_64 ]; then
  DESIRED_VERSION="0.9.0"
fi
curl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/U
W
cat > "$T/trailcmt/bin/w.sh" <<'W'
REPO="a/t"
DESIRED_VERSION="1.0.0" # bumped from the "version": field
curl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/T
W
cat > "$T/mailshape/bin/w.sh" <<'W'
REPO="a/m"
DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
    if [[ -z "$DESIRED_VERSION" ]]; then
        DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | cut -d'"' -f4 || true)
    fi
fi
curl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION
W
cat > "$T/pdfshape/bin/w.sh" <<'W'
REPO="a/p"
DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    if grep -qE '"binary_version"[[:space:]]*:' "$PLUGIN_JSON" 2>/dev/null; then
        DESIRED_VERSION=$(grep -oE '"binary_version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
        if [[ -z "$DESIRED_VERSION" ]]; then
            run_existing_or_die "binary_version present in plugin.json but empty/malformed"
        fi
    else
        DESIRED_VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    fi
fi
URL="https://github.com/$REPO/releases/download/v$DESIRED_VERSION/P"
W
cp "$T/pdfshape/bin/w.sh" "$T/pdfempty/bin/w.sh"
mkdir -p "$T/varlit/bin" "$T/supportlink/bin" "$T/shortR/bin" "$T/repoeq/bin" "$T/varhost/bin" "$T/flatmcp" "$T/emptymcp"
cat > "$T/varlit/bin/w.sh" <<'W'
REPO="a/one"
curl -L "https://github.com/$REPO/releases/download/v1.0.0/X" || curl -L "https://github.com/b/two/releases/download/v1.0.0/X"
W
cat > "$T/supportlink/bin/w.sh" <<'W'
SUPPORT="acme/support-forum"
curl -L https://github.com/acme/real-tool/releases/download/v1.0.0/Tool || echo "see https://github.com/$SUPPORT/issues"
W
printf 'gh release download v1.0.0 -R o/short -p X\n' > "$T/shortR/bin/w.sh"
cat > "$T/repoeq/bin/w.sh" <<'W'
R="o/eq"
gh release download v1.0.0 --repo="$R" -p X
W
cat > "$T/varhost/bin/w.sh" <<'W'
PROJ="PsychQuant/real"
curl https://notgithub.com/$PROJ/releases/download/v1.0.0/x
W
printf '{ "zotero": { "type": "stdio", "command": "${CLAUDE_PLUGIN_ROOT}/bin/w.sh" } }\n' > "$T/flatmcp/.mcp.json"
printf '{}\n' > "$T/emptymcp/.mcp.json"
# R11 — the R10 counter-examples: side paths the closed shapes did not cover yet
for d in wantover repoover firstif firstand firstcase ownername jsonwrite verlit urllit condrepo binhookpin onlyunk; do mkdir -p "$T/$d/bin" "$T/$d/.claude-plugin"
  printf '{ "name": "r", "version": "2.0.0", "binary_version": "0.3.0", "binaryVersion": "0.3.0" }\n' > "$T/$d/.claude-plugin/plugin.json"; done
cat > "$T/wantover/bin/w.sh" <<'W'
REPO="owner/tool"
WANT=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
WANT="1.0.0"
curl "https://github.com/$REPO/releases/download/v$WANT/Tool"
W
cat > "$T/repoover/bin/w.sh" <<'W'
REPO="owner/old"
REPO="${DOWNLOAD_REPO}"
DESIRED_VERSION="1.0.0"
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/Tool"
W
cat > "$T/firstif/bin/w.sh" <<'W'
REPO="o/f"
if [ "$(uname -m)" = x86_64 ]; then
  DESIRED_VERSION="1.0.0"
fi
[ -n "$DESIRED_VERSION" ] || DESIRED_VERSION=$(grep -o '"binaryVersion": *"[^"]*"' "$PJ" | cut -d'"' -f4)
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/T"
W
cat > "$T/firstand/bin/w.sh" <<'W'
REPO="o/f"
[ -n "$DEV" ] && DESIRED_VERSION="9.9.9"
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/T"
W
cat > "$T/firstcase/bin/w.sh" <<'W'
REPO="o/f"
case "$1" in --pin) DESIRED_VERSION="2.0.0" ;; esac
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/T"
W
cat > "$T/ownername/bin/w.sh" <<'W'
OWNER="o"; NAME="n"
DESIRED_VERSION="1.0.0"
curl -L "https://github.com/$OWNER/$NAME/releases/download/v$DESIRED_VERSION/x"
curl -s https://api.github.com/repos/PsychQuant/old-foo/releases/latest
W
cat > "$T/jsonwrite/bin/w.sh" <<'W'
REPO="o/j"
PIN="1.2.3"
curl -L "https://github.com/$REPO/releases/download/v$PIN/X"
printf '{"version": "%s"}\n' "$PIN" > "$HOME/bin/.x.json"
W
cat > "$T/verlit/bin/w.sh" <<'W'
REPO="o/v"
VERSION="1.2.3"
curl -L "https://github.com/$REPO/releases/download/v$VERSION/X"
W
cat > "$T/urllit/bin/w.sh" <<'W'
curl -L "https://github.com/o/u/releases/download/v1.2.3/X"
W
cat > "$T/condrepo/bin/w.sh" <<'W'
REPO="PsychQuant/foo"
[ -n "$FORK" ] && REPO="$FORK"
DESIRED_VERSION="1.0.0"
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/T"
W
mkdir -p "$T/binhookpin/hooks"
cat > "$T/binhookpin/bin/x-wrapper.sh" <<'W'
REPO="o/h"
DESIRED_VERSION="1.0.0"
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/x" -o "$HOME/bin/x"
W
cat > "$T/binhookpin/hooks/session-start.sh" <<'W'
REPO="o/h"
DESIRED_VERSION="0.9.0"
curl "https://github.com/$REPO/releases/download/v$DESIRED_VERSION/x" -o "$HOME/bin/x"
W
cat > "$T/onlyunk/bin/w.sh" <<'W'
R=$(cat repo.txt)
DESIRED_VERSION="1.0.0"
curl "https://github.com/$R/releases/download/v$DESIRED_VERSION/x"
W
mkdir -p "$T/urlmcp" "$T/npxmcp" "$T/pyiso"
printf '{ "remote": { "type": "http", "url": "https://example.com/mcp" } }\n' > "$T/urlmcp/.mcp.json"
printf '{ "tool": { "command": "npx", "args": ["-y", "some-mcp"] } }\n' > "$T/npxmcp/.mcp.json"
printf '{ "name": "iso", "binary_version": "1.0.0" }\n' > "$T/pyiso/plugin.json"
printf 'import os\nopen(os.path.join(os.path.dirname(os.path.abspath(__file__)), "PLANTED_RAN"), "w").close()\nfrom json import *\n' > "$T/pyiso/json.py"
# R12 — the R11 counter-examples
for d in iffalse nestedif otherjson postproc vertoken splitbase ghtag ghvar ghnotag dvunused dvlitpos; do mkdir -p "$T/$d/bin" "$T/$d/.claude-plugin"
  printf '{ "name": "r", "version": "2.0.0", "binaryVersion": "0.3.0" }\n' > "$T/$d/.claude-plugin/plugin.json"; done
cat > "$T/iffalse/bin/w.sh" <<'W'
if false; then
DESIRED_VERSION="1.0.0"
fi
curl "https://github.com/o/r/releases/download/v$DESIRED_VERSION/X"
W
cat > "$T/nestedif/bin/w.sh" <<'W'
if uname -m | grep -q arm; then
  if [ -f "$M" ]; then
    DESIRED_VERSION="1.2.3"
  fi
fi
curl "https://github.com/o/r/releases/download/v$DESIRED_VERSION/X"
W
cat > "$T/otherjson/bin/w.sh" <<'W'
OVERRIDE_JSON="$HOME/override.json"
DESIRED_VERSION=$(grep -oE '"binaryVersion": *"[^"]+"' "$OVERRIDE_JSON" | cut -d'"' -f4)
curl "https://github.com/o/r/releases/download/v$DESIRED_VERSION/X"
W
cat > "$T/postproc/bin/w.sh" <<'W'
DESIRED_VERSION=$(grep -oE '"binaryVersion": *"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4 | sed 's/^/1/')
curl "https://github.com/o/r/releases/download/v$DESIRED_VERSION/X"
W
cat > "$T/vertoken/bin/w.sh" <<'W'
VER="${1:-0.3.0}"
curl -L "https://github.com/o/r/releases/download/v${VER:-0.3.0}/X"
W
cat > "$T/splitbase/bin/w.sh" <<'W'
BASE="https://github.com/o/r/releases/download"
WANT=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
curl "$BASE/v$WANT/X"
W
printf 'gh release download --repo o/r v1.0.0 -p X\n' > "$T/ghtag/bin/w.sh"
cat > "$T/ghvar/bin/w.sh" <<'W'
VER=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" | cut -d'"' -f4)
gh release download "v$VER" --repo o/r -p X
W
printf 'gh release download --repo o/r -p X\n' > "$T/ghnotag/bin/w.sh"
cat > "$T/dvunused/bin/w.sh" <<'W'
DESIRED_VERSION="1.0.0"
curl -L "https://github.com/o/r/releases/latest/download/X"
W
cat > "$T/dvlitpos/bin/w.sh" <<'W'
DESIRED_VERSION="2.0.0"
curl -L "https://github.com/o/r/releases/download/v1.0.0/X"
W
mkdir -p "$T/mcpbad" "$T/symw/bin"; printf '{ "mcpServers": [] }\n' > "$T/mcpbad/.mcp.json"
printf 'curl https://github.com/o/r/releases/download/v1.0.0/X\n' > "$T/symtarget.sh"; ln -s "$T/symtarget.sh" "$T/symw/bin/w.sh"
# partial: one wrapper's pin is readable, the sibling's is not → the PLUGIN pin is unknown and no value is printed (R7 MEDIUM)
mkdir -p "$T/partial/.claude-plugin" "$T/partial/bin"
printf '{ "name": "partial", "version": "1.0.0", "binary_version": "0.3.0" }\n' > "$T/partial/.claude-plugin/plugin.json"
printf 'BINARY_NAME="Thing"\nREPO="o/r"\nV=$(grep -oE %s "$PLUGIN_JSON" | cut -d%s -f4)\ncurl https://github.com/$REPO/releases/download/v$V/$BINARY_NAME\n' "'\"binary_version\":[[:space:]]*\"[^\"]+\"'" "'\"'" > "$T/partial/bin/a.sh"
printf 'BINARY_NAME="Other"\nREPO="o/r"\nDESIRED_VERSION="${2:-}"\ncurl https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME\n' > "$T/partial/bin/b.sh"
# mixedpin: one wrapper pins a literal, its sibling reads nothing → the plugin pin is the literal (rc 0), the sibling is just unpinned
mkdir -p "$T/mixedpin/bin"
printf 'BINARY_NAME="A"\nREPO="a/x"\nDESIRED_VERSION="1.0.0"\ncurl https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/mixedpin/bin/a.sh"
printf 'BINARY_NAME="B"\nREPO="a/x"\ncurl https://api.github.com/repos/$REPO/releases/latest | grep browser_download_url | grep "$BINARY_NAME"\n' > "$T/mixedpin/bin/b.sh"

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
assert_rc "dyn: REPO=\"owner/tool\${FLAVOR}\" → cannot tell (rc 4, R11), no truncated prefix" 4 plugin_binary_repo "$T/dyn"
assert_eq "dyn: prints empty"                        "" "$(plugin_binary_repo "$T/dyn")"
assert_eq "indented: assignment inside a function / export form" "PsychQuant/che-keychain" "$(plugin_binary_repo "$T/indented")"
assert_eq "ghapi: repo from gh api repos/o/r/releases" "PsychQuant/ghapi" "$(plugin_binary_repo "$T/ghapi")"
assert_eq "two: same repo in both wrappers, docs link ignored → one value" "PsychQuant/msg" "$(plugin_binary_repo "$T/two")"
assert_rc "two: rc 0 (not a spurious multi-repo warning)" 0 plugin_binary_repo "$T/two"
assert_rc "badrepo: traversal segment rejected → cannot tell (rc 4, R11)" 4 plugin_binary_repo "$T/badrepo"
assert_eq "badrepo: prints empty"                    "" "$(plugin_binary_repo "$T/badrepo")"

echo
echo "plugin_binary_name:"
assert_eq "mcp: BINARY_NAME="                        "XMCP" "$(plugin_binary_name "$T/mcp")"
assert_eq "kc: RELEASE_ASSET= is the asset name (che-keychain's real wrapper)" "CheKeychain" "$(plugin_binary_name "$T/kc")"
assert_rc "hookonly: no declared asset name → rc 1 (never guessed from \$HOME/bin/gfh)" 1 plugin_binary_name "$T/hookonly"
assert_eq "hookonly: …prints empty"                   "" "$(plugin_binary_name "$T/hookonly")"
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
assert_eq "kc: row reads binaryVersion from the manifest" "bin|kc|CheKeychain|che-keychain|PsychQuant/che-keychain|0.2.0|binaryVersion" "$(plugin_binary_wrappers "$T/kc" "$T/kc/.claude-plugin/plugin.json")"
assert_eq "kc without manifest: the key is named, the value is unknown" "bin|kc|CheKeychain|che-keychain|PsychQuant/che-keychain||binaryVersion" "$(plugin_binary_wrappers "$T/kc")"
assert_eq "hookonly: hook row carries dir=hooks; install name from \$HOME/bin/gfh, asset undeclared" "hooks|session-start.sh||gfh|PsychQuant/GiftHub||none" "$(plugin_binary_wrappers "$T/hookonly")"
assert_eq "mixed: bin and hooks rows, both wrappers"  "bin|m-wrapper.sh|M|M|a/m||none
hooks|prefetch|||a/m||none" "$(plugin_binary_wrappers "$T/mixed")"
assert_rc "pure: no wrappers → rc 1"                  1 plugin_binary_wrappers "$T/pure"
assert_eq "unsafe: shell-significant filename is printed as ?" "bin|?|||a/b||none" "$(plugin_binary_wrappers "$T/unsafe")"
assert_eq "hijack: the non-wrapper helper is not a row (its URL pins a literal v1 → pin unreadable, R11)" "bin|real-wrapper.sh|RealBin|RealBin|real/thing||wrapper:real-wrapper.sh" "$(plugin_binary_wrappers "$T/hijack")"
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
assert_eq "verfb: a grep without the value extraction (no cut / sed) is not the corpus manifest read → cannot tell (R12)" "|wrapper:w.sh" "$(plugin_binary_pin "$T/verfb" "$T/verfb/.claude-plugin/plugin.json")"
assert_eq "lit: literal DESIRED_VERSION beats a different manifest version" "0.5.0|wrapper:all-wrapper.sh" "$(plugin_binary_pin "$T/lit" "$T/lit/.claude-plugin/plugin.json")"
assert_rc "nopin: wrapper reads nothing → rc 1, manifest version is NOT used" 1 plugin_binary_pin "$T/nopin" "$T/nopin/.claude-plugin/plugin.json"
assert_eq "nopin: prints |none"                       "|none" "$(plugin_binary_pin "$T/nopin" "$T/nopin/.claude-plugin/plugin.json")"
assert_eq "two: both literals agree — BOTH sources listed (the bump must touch both files)" "1.0.0|wrapper:all-wrapper.sh,wrapper:bot-wrapper.sh" "$(plugin_binary_pin "$T/two" /nonexistent)"
assert_rc "two: rc 0"                                 0 plugin_binary_pin "$T/two" /nonexistent
assert_rc "twodiff: wrappers disagree → rc 2"         2 plugin_binary_pin "$T/twodiff" /nonexistent
assert_eq "twodiff: first value printed, both sources" "1.0.0|wrapper:a.sh,wrapper:b.sh" "$(plugin_binary_pin "$T/twodiff" /nonexistent)"
assert_rc "pure: no wrappers → rc 1"                  1 plugin_binary_pin "$T/pure" "$T/pure/.claude-plugin/plugin.json"
assert_rc "hookonly: hook-only layout whose hook reads nothing → rc 1" 1 plugin_binary_pin "$T/hookonly" "$T/hookonly/.claude-plugin/plugin.json"
assert_eq "spaced: macdoc-family grep shape ('\"binary_version\"[[:space:]]*:') is recognised; comment lines do not reorder the keys" "4.0.10|binary_version" "$(plugin_binary_pin "$T/spaced" "$T/spaced/.claude-plugin/plugin.json")"
assert_rc "spaced: rc 0"                              0 plugin_binary_pin "$T/spaced" "$T/spaced/.claude-plugin/plugin.json"
assert_eq "hookpin: hook-only layout WITH a pin (macdoc) — the hook row is the downloading wrapper" "0.7.0|binary_version" "$(plugin_binary_pin "$T/hookpin" "$T/hookpin/.claude-plugin/plugin.json")"
assert_eq "hookpin: row"                              "hooks|session-start.sh|macdoc|macdoc|PsychQuant/macdoc|0.7.0|binary_version" "$(plugin_binary_wrappers "$T/hookpin" "$T/hookpin/.claude-plugin/plugin.json")"
assert_eq "hookpin: repo from the hook (no bin/ to outrank it)" "PsychQuant/macdoc" "$(plugin_binary_repo "$T/hookpin")"
assert_eq "unsafelit: pin source prints wrapper:? for a hostile filename" "1.2.3|wrapper:?" "$(plugin_binary_pin "$T/unsafelit" /nonexistent)"
assert_eq "unsafelit: row keeps 7 fields (no raw name, no stray |)" "bin|?|||a/b|1.2.3|wrapper:?" "$(plugin_binary_wrappers "$T/unsafelit")"
assert_eq "hookrepo: the bin wrapper's repo wins over a hooks/ check script's *_REPO=" "Real/proj" "$(plugin_binary_repo "$T/hookrepo")"
assert_rc "hookrepo: rc 0 — the hook is not a conflict, it is not consulted" 0 plugin_binary_repo "$T/hookrepo"
assert_rc "keyless: wrapper names binaryVersion, manifest lacks it → rc 4 (unreadable), not rc 1 (no pin)" 4 plugin_binary_pin "$T/keyless" "$T/keyless/.claude-plugin/plugin.json"
assert_eq "keyless: prints |binaryVersion so the consumer can name the key" "|binaryVersion" "$(plugin_binary_pin "$T/keyless" "$T/keyless/.claude-plugin/plugin.json")"
assert_rc "badpin: illegal manifest value → rc 4 at the plugin level" 4 plugin_binary_pin "$T/badpin" "$T/bad/.claude-plugin/plugin.json"
assert_rc "commentonly: a release URL in a # line is not a download → no wrapper rows" 1 plugin_binary_wrappers "$T/commentonly"
assert_eq "mixedpin: a literal-pinned wrapper next to an unpinned sibling → the literal, rc 0" "1.0.0|wrapper:a.sh" "$(plugin_binary_pin "$T/mixedpin" /nonexistent)"
assert_rc "mixedpin: rc 0"                            0 plugin_binary_pin "$T/mixedpin" /nonexistent
assert_rc "cmtrepo: a release URL in a # line is not a repo candidate; the real site is dynamic → cannot tell (rc 4, R11)" 4 plugin_binary_repo "$T/cmtrepo"
assert_eq "cmtrepo: prints empty (dynamic REPO= is not a literal either)" "" "$(plugin_binary_repo "$T/cmtrepo")"
assert_rc "cmtbin: \$HOME/bin/<name> in a comment is not an install name → rc 1" 1 plugin_install_names "$T/cmtbin"
assert_eq "installonly: BINARY_NAME= used only as the install target → asset undeclared, install name kept" "bin|w.sh||che-latex-mcp|a/latex||wrapper:w.sh" "$(plugin_binary_wrappers "$T/installonly")"
assert_eq "two: BINARY_NAME= used in the download URL IS the asset" "AllMCP" "$(plugin_binary_name "$T/two")"
assert_eq "hijack: the literal asset name in the download URL declares BINARY_NAME as the asset" "RealBin" "$(plugin_binary_name "$T/hijack")"
assert_rc "mixrepo: assignment in one file + a different URL literal in the other → rc 2 (per-file tiering, then merge)" 2 plugin_binary_repo "$T/mixrepo"
assert_eq "mixrepo: first printed"                    "a/one" "$(plugin_binary_repo "$T/mixrepo")"
assert_eq "unusedrepo: a *_REPO= nothing downloads through is ignored; the URL literal is the repo" "real/thing" "$(plugin_binary_repo "$T/unusedrepo")"
assert_rc "unusedrepo: rc 0"                          0 plugin_binary_repo "$T/unusedrepo"
assert_eq "override: literal then an UNGUARDED manifest read → not a recognised shape → rc 4, no value (R10 closed shapes)" "|wrapper:w.sh" "$(plugin_binary_pin "$T/override" "$T/override/.claude-plugin/plugin.json")"
assert_rc "overrideunk: literal default + unreadable override → rc 4, not the stale literal" 4 plugin_binary_pin "$T/overrideunk" /nonexistent
assert_eq "overrideunk: names the wrapper as the (unreadable) source" "|wrapper:w.sh" "$(plugin_binary_pin "$T/overrideunk" /nonexistent)"
assert_rc "dotname: BINARY_NAME=a.b vs URL …/axb → no declared asset (dot is not a wildcard)" 1 plugin_binary_name "$T/dotname"
assert_rc "condover: literal default + conditional override on the same line → rc 4, not the stale literal" 4 plugin_binary_pin "$T/condover" /nonexistent
assert_eq "condover: names the wrapper as the (unreadable) source" "|wrapper:w.sh" "$(plugin_binary_pin "$T/condover" /nonexistent)"
assert_rc "jqpin: key read through jq (no \"key\": shape) → rc 4 with the key, not 'reads nothing'" 4 plugin_binary_pin "$T/jqpin" "$T/jqpin/.claude-plugin/plugin.json"
assert_eq "jqpin: prints |binaryVersion"             "|binaryVersion" "$(plugin_binary_pin "$T/jqpin" "$T/jqpin/.claude-plugin/plugin.json")"
assert_rc "movingref: DESIRED_VERSION=\"latest\" is not a pin → rc 4" 4 plugin_binary_pin "$T/movingref" /nonexistent
assert_rc "mfover: manifest read then an unfollowable override → rc 4 (manifest key is not what downloads)" 4 plugin_binary_pin "$T/mfover" "$T/mfover/.claude-plugin/plugin.json"
assert_eq "mfover: names the wrapper, prints no value"  "|wrapper:w.sh" "$(plugin_binary_pin "$T/mfover" "$T/mfover/.claude-plugin/plugin.json")"
for d in iffalse nestedif postproc vertoken splitbase ghtag dvunused dvlitpos; do
  assert_rc "$d (R12): not a recognised shape → rc 4 (cannot tell), never a definite pin or 'no pin'" 4 plugin_binary_pin "$T/$d" "$T/$d/.claude-plugin/plugin.json"
done
assert_eq "otherjson (R12): a key grep over a non-manifest file is not a manifest read → rc 4 naming the key, not the manifest value" "|binaryVersion" "$(plugin_binary_pin "$T/otherjson" "$T/otherjson/.claude-plugin/plugin.json")"
assert_eq "ghvar (R12): gh release download \"v\$VER\" with VER read from the manifest → the manifest value" "2.0.0|version" "$(plugin_binary_pin "$T/ghvar" "$T/ghvar/.claude-plugin/plugin.json")"
assert_rc "ghnotag (R12): a tag-less gh release download is latest → no pin (rc 1)" 1 plugin_binary_pin "$T/ghnotag" "$T/ghnotag/.claude-plugin/plugin.json"
assert_rc "mcpbad (R12): mcpServers that is not an object → rc 4" 4 plugin_is_binary_backed "$T/mcpbad"
assert_rc "symw (R12): a symlinked wrapper is not scanned → rc 4 (cannot tell), not rc 1" 4 plugin_is_binary_backed "$T/symw"
assert_eq "wantover (R11): a pin variable not named DESIRED_VERSION gets the same closed shapes → an unguarded override is rc 4" "|wrapper:w.sh" "$(plugin_binary_pin "$T/wantover" "$T/wantover/.claude-plugin/plugin.json")"
assert_rc "repoover (R11): a repo variable later overwritten dynamically → the old literal is not definite (rc 2)" 2 plugin_binary_repo "$T/repoover"
assert_eq "firstif (R11): the FIRST value under \`if uname\` → rc 4, not its literal" "|wrapper:w.sh" "$(plugin_binary_pin "$T/firstif" "$T/firstif/.claude-plugin/plugin.json")"
assert_eq "firstand (R11): \`[ -n \"\$DEV\" ] && DESIRED_VERSION=…\` → rc 4" "|wrapper:w.sh" "$(plugin_binary_pin "$T/firstand" "$T/firstand/.claude-plugin/plugin.json")"
assert_eq "firstcase (R11): a value inside \`case\` → rc 4" "|wrapper:w.sh" "$(plugin_binary_pin "$T/firstcase" "$T/firstcase/.claude-plugin/plugin.json")"
assert_rc "ownername (R11): \$OWNER/\$NAME at the repo position is unknown, not skipped → rc 2 beside the other site" 2 plugin_binary_repo "$T/ownername"
assert_eq "jsonwrite (R11): a \"version\": text that is not a manifest read does not become the pin; PIN at the URL version position is" "1.2.3|wrapper:w.sh" "$(plugin_binary_pin "$T/jsonwrite" "$T/jsonwrite/.claude-plugin/plugin.json")"
assert_eq "verlit (R11): VERSION=\"1.2.3\" used at the version position is the pin, not 'no pin'" "1.2.3|wrapper:w.sh" "$(plugin_binary_pin "$T/verlit" "$T/verlit/.claude-plugin/plugin.json")"
assert_rc "urllit (R11): a literal version in the release URL is a pin we do not read → rc 4, not rc 1 no-pin" 4 plugin_binary_pin "$T/urllit" "$T/urllit/.claude-plugin/plugin.json"
assert_rc "condrepo (R11): a conditional reassignment of the repo variable → rc 2, not the default as certain" 2 plugin_binary_repo "$T/condrepo"
assert_rc "binhookpin (R11): a downloading hook with its own pin beside bin/ → plugin pin cannot tell (rc 4), not bin's value" 4 plugin_binary_pin "$T/binhookpin" "$T/binhookpin/.claude-plugin/plugin.json"
assert_rc "onlyunk (R11): only a download site with an unknown repo → rc 4 (cannot tell), not rc 1 (none)" 4 plugin_binary_repo "$T/onlyunk"
assert_rc "urlmcp (R11): a remote-url MCP server ships no release binary → .mcp.json does not count" 1 plugin_is_binary_backed "$T/urlmcp"
assert_rc "npxmcp (R11): an npx MCP server ships no release binary → .mcp.json does not count" 1 plugin_is_binary_backed "$T/npxmcp"
chmod 000 "$T/wantover/bin/w.sh"
assert_eq "unreadable wrapper (R11): the reader failing is cannot-tell, never |none" "|wrapper:w.sh" "$(_pbm_file_pin "$T/wantover/bin/w.sh" "$T/wantover/.claude-plugin/plugin.json")"
chmod 644 "$T/wantover/bin/w.sh"
assert_eq "pyiso (R11): JSON reads run python3 -I — a json.py in the cwd is not imported" "1.0.0|absent" "$( cd "$T/pyiso" && v=$(_pbm_json_field "$T/pyiso/plugin.json" binary_version); printf '%s|%s' "$v" "$([ -e "$T/pyiso/PLANTED_RAN" ] && echo ran || echo absent)" )"
assert_eq "fnindent: two unconditional literals inside a function (indented) → rc 4, not the first" "|wrapper:w.sh" "$(plugin_binary_pin "$T/fnindent" "$T/fnindent/.claude-plugin/plugin.json")"
assert_eq "sameline: \$(…) || \"1.0.0\" on one line → rc 4 (the opaque primary is not ignored)" "|wrapper:w.sh" "$(plugin_binary_pin "$T/sameline" "$T/sameline/.claude-plugin/plugin.json")"
assert_eq "archover: a readable override under \`if uname\` → rc 4 (not an only-if-empty guard)" "|wrapper:w.sh" "$(plugin_binary_pin "$T/archover" "$T/archover/.claude-plugin/plugin.json")"
assert_eq "trailcmt: a key shape in a trailing comment does not turn a literal into a manifest read" "1.0.0|wrapper:w.sh" "$(plugin_binary_pin "$T/trailcmt" "$T/trailcmt/.claude-plugin/plugin.json")"
assert_eq "mailshape (real corpus): \"\" + if-f + key + if -z guarded fallback key, continued lines → the first key" "0.4.0|binary_version" "$(plugin_binary_pin "$T/mailshape" "$T/mailshape/.claude-plugin/plugin.json")"
assert_eq "pdfshape (real corpus): if grep -q KEY … else <other key> → the else key when KEY is absent" "2.0.0|version" "$(plugin_binary_pin "$T/pdfshape" "$T/pdfshape/.claude-plugin/plugin.json")"
assert_eq "pdfempty: binary_version present but empty → the wrapper refuses; rc 4 naming the key, NOT the version fallback" "|binary_version" "$(plugin_binary_pin "$T/pdfempty" "$T/pdfempty/.claude-plugin/plugin.json")"
assert_rc "varlit: variable primary + literal fallback repo in one file → rc 2" 2 plugin_binary_repo "$T/varlit"
assert_eq "supportlink: a non-release github.com/\$X/issues link does not choose the repo" "acme/real-tool" "$(plugin_binary_repo "$T/supportlink")"
assert_eq "shortR: gh release download -R o/r" "o/short" "$(plugin_binary_repo "$T/shortR")"
assert_eq "repoeq: --repo=\"\$R\"" "o/eq" "$(plugin_binary_repo "$T/repoeq")"
assert_rc "varhost: notgithub.com/\$PROJ/releases names no GitHub repo → rc 1" 1 plugin_binary_repo "$T/varhost"
assert_eq "flatmcp: the flat plugin .mcp.json format (every real plugin) declares a server" "mcp.json" "$(plugin_is_binary_backed "$T/flatmcp")"
assert_rc "emptymcp: {} declares nothing → rc 1" 1 plugin_is_binary_backed "$T/emptymcp"
assert_eq "twouncond: two unguarded manifest reads → not a recognised shape → rc 4, no value (R10)" "|wrapper:w.sh" "$(plugin_binary_pin "$T/twouncond" "$T/twouncond/.claude-plugin/plugin.json")"
assert_eq "indentfb: manifest read + indented literal fallback → the manifest key (it has a value)" "0.3.0|binaryVersion" "$(plugin_binary_pin "$T/indentfb" "$T/indentfb/.claude-plugin/plugin.json")"
assert_eq "indentfb2: …and the literal only when the manifest key is empty" "0.0.0|wrapper:w.sh" "$(plugin_binary_pin "$T/indentfb2" "$T/indentfb2/.claude-plugin/plugin.json")"
assert_eq "mention: echo/grep lines mentioning DESIRED_VERSION= are not assignments" "1.2.3|wrapper:w.sh" "$(plugin_binary_pin "$T/mention" /nonexistent)"
assert_rc "tworepo1: one wrapper, two download repos → rc 2 (multi-repo)" 2 plugin_binary_repo "$T/tworepo1"
assert_eq "tworepo1: the wrapper row's repo column is empty (ambiguous), not the first repo" "bin|w.sh|P|P||1.0.0|wrapper:w.sh" "$(plugin_binary_wrappers "$T/tworepo1" /nonexistent)"
assert_eq "quotedrepo: --repo \"o/q\" and gh api \"repos/o/q/…\" both resolve" "o/q" "$(plugin_binary_repo "$T/quotedrepo")"
assert_rc "quotedrepo: …and agree (rc 0)" 0 plugin_binary_repo "$T/quotedrepo"
assert_eq "projvar: a variable not named *REPO, used in the release URL, is the repo" "Owner/Repo" "$(plugin_binary_repo "$T/projvar")"
assert_rc "nothost: release URL on another host names no repo → rc 1" 1 plugin_binary_repo "$T/nothost"
assert_rc "unkmcp: unparseable .mcp.json → rc 4 (cannot answer), not rc 1" 4 plugin_is_binary_backed "$T/unkmcp"
assert_eq "unkmcp: …and says which probe" "unknown:mcp.json" "$(plugin_is_binary_backed "$T/unkmcp")"
assert_rc "unkmf: unreadable manifest → rc 4" 4 plugin_is_binary_backed "$T/unkmf" "$T/unkmf/bad.json"
assert_eq "unkmf: …names the manifest probe" "unknown:manifest" "$(plugin_is_binary_backed "$T/unkmf" "$T/unkmf/bad.json")"
assert_eq "kc: a manifest read that IS the last assignment still resolves (rush / che-keychain shape)" "0.2.0|binaryVersion" "$(plugin_binary_pin "$T/kc" "$T/kc/.claude-plugin/plugin.json")"
assert_rc "partial: one readable pin + one unreadable sibling → rc 4" 4 plugin_binary_pin "$T/partial" "$T/partial/.claude-plugin/plugin.json"
assert_eq "partial: prints the sources and NO value (never a plausible default)" "|binary_version,wrapper:b.sh" "$(plugin_binary_pin "$T/partial" "$T/partial/.claude-plugin/plugin.json")"

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
lrv_noroot() { PBM_TEST_ROOT= PBM_GH="$T/gh-stub" latest_release_version "$@"; }   # PBM_TEST=1 alone is not enough
lrv_outside() { ( cd / && PBM_GH="$T/gh-stub" latest_release_version "$@" ); }   # …nor is it when $PWD is outside the test root
lrv_slashroot() { ( cd "$T" && PBM_TEST_ROOT=/ PBM_GH="$T/gh-stub" latest_release_version "$@" ); }   # PBM_TEST_ROOT=/ must not turn the prefix test into "everything"
lrv_homeroot() { ( cd "$T" && PBM_TEST_ROOT="$HOME" PBM_GH="$T/gh-stub" latest_release_version "$@" ); }
# the temp-tree arm must be exercised with a cwd UNDER the offending root (a cwd outside it is rejected by the cwd test alone)
PROBE="$HOME/.cache/pbm-seam-probe.$$"; mkdir -p "$PROBE"
lrv_homeroot_in() { ( cd "$PROBE" && TMPDIR=/nonexistent-pbm-xyz PBM_TEST_ROOT="$HOME" PBM_GH="$T/gh-stub" latest_release_version "$@" ); }   # stale TMPDIR + cwd under $HOME
lrv_homeroot_in2() { ( cd "$PROBE" && TMPDIR="$T" PBM_TEST_ROOT="$HOME" PBM_GH="$T/gh-stub" latest_release_version "$@" ); }   # valid TMPDIR, root still not under it
assert_rc "gh failure → rc 1"                        1 lrv_fail PsychQuant/che-keychain
assert_eq "gh failure → prints empty"                "" "$(lrv_fail PsychQuant/che-keychain)"
assert_rc "malformed repo arg → rc 1 without calling gh" 1 lrv_nogh 'bad repo'
assert_rc "relative PBM_GH → rc 1 (test seam takes absolute paths only)" 1 lrv_rel PsychQuant/che-keychain
assert_eq "PBM_GH is ignored without PBM_TEST=1 (stub never answers 9.9.9)" "" "$( [ "$(lrv_notest Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_GH is ignored without PBM_TEST_ROOT" "" "$( [ "$(lrv_noroot Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_GH is ignored when \$PWD is outside PBM_TEST_ROOT (a production fence cd's into the marketplace root)" "" "$( [ "$(lrv_outside Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_TEST_ROOT=/ does not open the seam" "" "$( [ "$(lrv_slashroot Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_TEST_ROOT=\$HOME does not open the seam (only system temp trees qualify)" "" "$( [ "$(lrv_homeroot Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_TEST_ROOT=\$HOME with cwd UNDER \$HOME and a stale TMPDIR: seam stays closed (no empty prefix)" "" "$( [ "$(lrv_homeroot_in Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
assert_eq "PBM_TEST_ROOT=\$HOME with cwd UNDER \$HOME and a valid TMPDIR: seam stays closed" "" "$( [ "$(lrv_homeroot_in2 Nonexistent/repo-xyz-0)" = 9.9.9 ] && echo LEAK )"
rmdir "$PROBE" 2>/dev/null
assert_eq "release_assets 0.2.0 queries tag v0.2.0 (pins are bare, tags are v-prefixed)" "CheKeychain" "$(PBM_GH="$T/gh-stub" release_assets PsychQuant/che-keychain 0.2.0)"
assert_eq "release_assets v0.2.0: a leading v is normalised, same release" "CheKeychain" "$(PBM_GH="$T/gh-stub" release_assets PsychQuant/che-keychain v0.2.0)"
ra_tag() { PBM_GH="$T/gh-stub" release_assets "$@"; }
assert_rc "release_assets 0.3.0: no such release (v0.3.0 nor 0.3.0) → rc 1" 1 ra_tag PsychQuant/che-keychain 0.3.0
assert_eq "release_assets: falls back to the bare tag when the repo tags without v" "BareBin" "$(PBM_GH="$T/gh-stub" release_assets Bare/only 1.0.0)"
assert_eq "plugin_bin_dir is public and honours the test seam" "$T/bin" "$(plugin_bin_dir)"
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
