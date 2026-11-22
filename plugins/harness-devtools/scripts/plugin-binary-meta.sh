#!/bin/bash
# plugin-binary-meta.sh — single reading point for a binary-backed plugin's metadata (#22).
#
# Usage (sourced by skills; sits NEXT TO resolve-marketplace.sh, neither sources the other —
# consumers source both):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/plugin-binary-meta.sh"
#
#   plugin_binary_version <manifest>            # explicit manifest pin: binary_version → binaryVersion → "" (never `version`)
#                                               # rc 0 (value or empty) / 3 illegal value / 4 manifest unreadable
#                                               # DETECTION-ONLY (with _key below): says whether the manifest declares a pin. The pin a phase
#                                               # acts on comes from plugin_binary_pin — the key the WRAPPER names, no cross-spelling alias,
#                                               # because the wrapper itself would not find the other spelling (#22 point 1; verify R4)
#   plugin_binary_version_key <manifest>        # which explicit pin key the file uses; rc 1 none / 2 both (binary_version printed) / 4
#   plugin_is_binary_backed <dir> [manifest]    # rc 0 + hit list "mcp.json bin:<f> hook:<f> pin:<key>" / rc 1 empty / rc 4 nothing hit
#                                               #   but a probe cannot answer ("unknown:mcp.json" / "unknown:manifest"). .mcp.json counts when a
#                                               #   server (mcpServers or the flat plugin format) has a plugin-local `command` (${CLAUDE_PLUGIN_ROOT}/…,
#                                               #   ./…, bin/…); `{}`, a remote `url`, npx / uvx do not
#   plugin_binary_wrappers <dir> [manifest]     # one row per file that DOWNLOADS a release:
#                                               #   "dir|file|asset|install|repo|pin|pinsrc"   dir ∈ bin|hooks; empty field = unknown
#                                               #   pinsrc ∈ wrapper:<file> | binary_version | binaryVersion | version | none
#   plugin_binary_pin <dir> <manifest>          # the pin the plugin's DOWNLOADING wrappers use — bin/ rows when any exist, else
#                                               #   hooks/ rows (hook-only layouts such as macdoc / gifthub) — "value|pinsrc[,pinsrc…]":
#                                               #   every distinct source in row order (two wrappers sharing one literal pin → two sources);
#                                               #   rc 0 every pinned wrapper agrees / 1 no wrapper has a pin / 2 wrappers disagree (first printed)
#                                               #   / 4 some downloading wrapper's pin cannot be read (an unrecognised shape, missing / illegal key
#                                               #     value, moving ref), or a hooks/ row next to bin/ carries a pin of its own — prints
#                                               #     "|src[,src…]" with NO value, even if a sibling wrapper's pin is readable
#   plugin_binary_repo <dir>                    # owner/repo from the DOWNLOADING wrapper files (bin/ when any exist, else hooks/ — a
#                                               #   check hook can never re-point a plugin that has a bin/ wrapper). PER DOWNLOAD SITE: the
#                                               #   value at the repo position of each release line — a literal o/r, or a variable (any name)
#                                               #   whose EVERY assignment is a literal o/r; anything else is "?" — merged over all files:
#                                               #   rc 0 exactly one known repo / 1 no download site / 2 several, or a known one beside "?"
#                                               #   (first printed) / 4 only "?" sites (cannot tell, not "none")
#   plugin_binary_name <dir>                    # first DECLARED asset name: RELEASE_ASSET= → ASSET_NAME= → BINARY_NAME= (the last only when a
#                                               #   non-comment line downloads BY that name); rc 1 none — never guessed from the install name,
#                                               #   a guess would turn into a false "asset missing" that now BLOCKS the Case E bump
#   plugin_install_names <dir>                  # unique INSTALLED names (INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>), one/line
#   plugin_installed_binary_version <dir> [name]  # <bin dir>/.<name>.version; rc 1 no sidecar / 2 no name / 3 sidecar not a version
#   plugin_bin_dir                              # the sidecar directory (~/bin; PLUGIN_BIN_DIR when the test seam is live)
#   marketplace_entry_version <mp_root> <p>     # rc 0 (value, or EMPTY when the entry has no version) / 1 no entry / 3 illegal / 4 unreadable
#   latest_release_version <owner/repo>         # gh release view … tagName, leading v stripped; rc 1 on failure
#   release_assets <owner/repo> [x.y.z]         # asset names of that release (latest when no version), one per line; the release is
#                                               #   looked up as tag v<x.y.z> first, bare <x.y.z> second (real tags are v-prefixed; pins are
#                                               #   stored bare); a name that fails the allowlist is printed as "?" so "absent" and
#                                               #   "unprintable" stay distinguishable; rc 1 on failure
#   version_gt <a> <b>                          # rc 0 a>b / 1 not / 2 not comparable (non x.y.z)
#
# WHY THIS EXISTS
#   Before #22 every phase of plugin-update guessed this metadata with its own literal
#   assumptions — the field is spelled `binary_version`, the wrapper is `bin/*-wrapper.sh`
#   and assigns `GITHUB_REPO=`, the marketplace entry always has `version`, `claude plugin
#   list` showing the new version means the binary is there. che-keychain 0.3.0
#   (2026-09-12) missed every one of them: `binaryVersion`, `bin/che-keychain`, `REPO=`,
#   an entry with no `version`, a hook that delegates instead of curling. Each miss came
#   out as "no" rather than "don't know", so nothing was reported.
#
#   The rule here: a lookup that cannot answer returns a DISTINCT rc and prints nothing —
#   it never prints a plausible default. Consumers turn rc 1/2/4 into "UNKNOWN" lines.
#
# WHERE THE PIN LIVES (#22 verify R1/R2 — both rounds guessed it from the manifest and were wrong)
#   The pin is whatever the WRAPPER downloads, and only the wrapper knows. Surveying the 26 real
#   wrappers/hooks on this machine (psychquant-claude-plugins, the four self-hosted ./plugin
#   marketplaces and the macdoc marketplace): 4 carry a literal `DESIRED_VERSION="x.y.z"` and never
#   read plugin.json (agent-cacher, che-latex-mcp, che-telegram-mcp ×2); 8 grep `"version"` out of
#   plugin.json; 6 grep `binaryVersion`/`binary_version` first and fall back to `version`
#   (che-keychain, che-apple-mail-mcp, rush, che-word-mcp, che-pdf-mcp, che-pptx-mcp); 1 hook greps
#   `binary_version` only and downloads itself (macdoc — a hook-only layout WITH a pin); 1 reads
#   nothing (omlx); the remaining hooks are check scripts that read no version. So the pin is
#   resolved PER WRAPPER from a closed list of three sources — (1) a literal DESIRED_VERSION= in the
#   file, (2) the manifest key(s) the file names, in the order it names them, (3) none — and there
#   is NO plugin-wide fallback to `version`: a wrapper that does not read it does not use it.
#   "Names a key" is matched on NON-comment lines as `"<key>"` followed by anything up to a `:` —
#   the macdoc family writes `'"binary_version"[[:space:]]*:'`, che-keychain writes
#   `'"binaryVersion":[[:space:]]*"'`; a regex that demanded whitespace-or-colon right after the
#   closing quote missed the first shape on four real plugins (#22 verify R3).
#
# CONTRACT
#   - bash 3.2 (no arrays needed; no nameref, no associative arrays); zsh-safe when sourced
#     (no unquoted `$VAR` word-splitting, no globs — `find` only; nomatch would abort a fence).
#   - Lookup paths write NOTHING to stderr and leave no variables behind (everything `local`).
#     Callers decide what to say.
#   - Values that will be echoed / used in URLs / used as paths pass an allowlist before being
#     printed — including the basenames of wrapper files (a file called `kc; rm -rf ~` must not
#     reach an agent-facing line).
#   - Only files that actually download a release are wrappers. Names, repos and pins are read
#     from wrapper files only — a helper script that merely assigns `REPO=` cannot re-point the
#     plugin, and a test stub that declares `BINARY_NAME=` is not a third binary.
#   - ONE binary per plugin is NOT assumed (che-telegram-mcp: two wrappers, two sidecars). A
#     wrapper whose install name cannot be resolved (agent-cacher's `ensure_binary <name>` calls)
#     is an UNRESOLVED row — consumers must count it, never report "all N verified" past it.
#   - ASSET name ≠ INSTALL name. che-keychain's wrapper declares `RELEASE_ASSET="CheKeychain"` (the
#     release asset) and `INSTALL_NAME="che-keychain"` (the file on disk; the sidecar
#     `.che-keychain.version` is keyed by it). Signal 1 wants the former, Phase 5 the latter. The
#     asset name is DECLARED or unknown (RELEASE_ASSET= / ASSET_NAME= / BINARY_NAME= — the four
#     spellings in the real corpus); it is never guessed from the install name, because a guessed
#     name that is not in the release reads as "asset missing → mcp-deploy", which is a false alarm
#     (#22 verify R3). The install name may fall back to BINARY_NAME= / `$HOME/bin/<name>`.
#   - Wrapper filenames are third-party content: every place that prints one runs it through the
#     allowlist and prints `?` instead — including the `wrapper:<file>` pin source.
#   - Field names are read in BOTH spellings; writers preserve the file's own key.
#   - Detection pattern for "this file downloads a release" is, verbatim, the one idd-close's
#     has_binary_wrapper uses (PsychQuant/issue-driven-development: plugins/issue-driven-dev/references/distribution-detection.md). Detection is URL shape only;
#     the literal owner/repo is plugin_binary_repo's job (assignment beats URL; a bare
#     `github.com/o/r` docs link is never a candidate).
#   - PBM_GH / PLUGIN_BIN_DIR are TEST seams and are honoured only when PBM_TEST=1 AND PBM_TEST_ROOT is a real directory under
#     a system temp tree (never / or $HOME) AND the real $PWD is under it (production fences cd into the marketplace root, which
#     is not under a temp tree). This keeps the SEAM from opening on a normally-placed marketplace; it is not a claim that the
#     environment cannot redirect gh at all — PATH can always do that, and a marketplace checked out under /tmp is inside the tree;
#     the production path has exactly one way to reach gh and one sidecar directory.

_PBM_RELEASE_RE='gh release download|gh api[[:space:]]+.*/releases|api\.github\.com/.*/releases|github\.com/.*/releases/(download|tags|latest)'

# ---- internal ---------------------------------------------------------------

# _pbm_json_field <file> <key>  → value (empty if absent / not a string); rc 4 unreadable
_pbm_json_field() {
  local file="$1" key="$2" out rc
  [ -f "$file" ] && [ -r "$file" ] || return 4
  out=$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(4)
if not isinstance(d, dict):
    sys.exit(4)
v = d.get(sys.argv[2])
print(v if isinstance(v, str) else "")
' "$file" "$key" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 4
  printf '%s\n' "$out"
}

_pbm_version_ok() { case "$1" in ''|.*|-*|*[!A-Za-z0-9.+-]*) return 1 ;; esac; return 0; }
_pbm_pin_ok() { _pbm_version_ok "$1" && case "$1" in [0-9]*) return 0 ;; esac; return 1; }   # a PIN starts with a digit: `latest` / `main` are moving refs, not pins (#22 verify R6)
_pbm_repo_ok() {
  case "$1" in
    [A-Za-z0-9]*/[A-Za-z0-9]*) case "$1" in *[!A-Za-z0-9._/-]*|*/*/*) return 1 ;; esac; return 0 ;;
    *) return 1 ;;
  esac
}
_pbm_name_ok() { case "$1" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# _pbm_test_on → the test seam is live only when PBM_TEST=1 AND PBM_TEST_ROOT names a real directory under a system temp tree
# (/tmp, /private/tmp, /var/folders, $TMPDIR — what mktemp -d hands out; never / or $HOME) AND the real current directory is
# under it. Production fences `cd "$MP_ROOT"`, which is never under a temp tree, so an ambient PBM_TEST/PBM_GH/PBM_TEST_ROOT
# in the environment does not open THIS seam for a normally-placed marketplace. It narrows the seam; it is not a sandbox and
# not the only way an environment can redirect gh (PATH is) — a marketplace checked out under /tmp is inside the tree (#22 R5–R7)
_pbm_test_on() {
  local root here tmpreal
  [ "${PBM_TEST:-}" = 1 ] && [ -n "${PBM_TEST_ROOT:-}" ] || return 1
  root=$(cd "$PBM_TEST_ROOT" 2>/dev/null && pwd -P) || return 1
  # `PBM_TEST_ROOT=/` (or $HOME, or any ancestor of the marketplace) would make the prefix test match every production cwd
  # (#22 verify R6): the root must be a directory under one of the system temp trees mktemp -d uses, compared by real path.
  # $TMPDIR is resolved FIRST and the arm is skipped when it does not resolve — an unresolvable TMPDIR must never become an
  # empty prefix that matches everything (#22 verify R7). This narrows the seam so tests can stub gh; it is not a sandbox.
  case "$root" in
    /tmp/?*|/private/tmp/?*|/var/folders/?*|/private/var/folders/?*) ;;
    *) [ -n "${TMPDIR:-}" ] || return 1
       tmpreal=$(cd "$TMPDIR" 2>/dev/null && pwd -P) || return 1
       [ -n "$tmpreal" ] && [ "$tmpreal" != / ] || return 1
       case "$root" in "$tmpreal"/?*) ;; *) return 1 ;; esac ;;
  esac
  here=$(pwd -P 2>/dev/null) || return 1
  case "$here/" in "$root"/*) return 0 ;; esac
  return 1
}
# _pbm_gh → the gh to run: PBM_GH only when the test seam is live and only as an absolute executable; rc 1 refuses
_pbm_gh() {
  if [ -n "${PBM_GH:-}" ] && _pbm_test_on; then
    case "$PBM_GH" in /*) [ -x "$PBM_GH" ] && { printf '%s\n' "$PBM_GH"; return 0; } ;; esac
    return 1
  fi
  printf 'gh\n'
}
# _pbm_bin_dir → sidecar directory: PLUGIN_BIN_DIR only when the test seam is live
_pbm_bin_dir() {
  if [ -n "${PLUGIN_BIN_DIR:-}" ] && _pbm_test_on; then printf '%s\n' "$PLUGIN_BIN_DIR"; else printf '%s\n' "$HOME/bin"; fi
}
plugin_bin_dir() { _pbm_bin_dir; }   # public — consumers print it; the underscore form is internal

# _pbm_scan_files <dir> → regular files under bin/ and hooks/ (depth 1), one per line, sorted
_pbm_scan_files() {
  local dir="$1"
  { [ -d "$dir/bin" ]   && find "$dir/bin"   -maxdepth 1 -type f 2>/dev/null
    [ -d "$dir/hooks" ] && find "$dir/hooks" -maxdepth 1 -type f 2>/dev/null
  } | sort
}
# _pbm_file_is_wrapper <file>: DOWNLOADS a release — matched on non-comment lines (a docs link in a `#` line is not a download)
_pbm_file_is_wrapper() { LC_ALL=C grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | LC_ALL=C grep -qE "$_PBM_RELEASE_RE"; }
# _pbm_wrapper_files <dir> → wrapper files only
_pbm_wrapper_files() {
  local f
  while IFS= read -r f; do [ -n "$f" ] && _pbm_file_is_wrapper "$f" && printf '%s\n' "$f"; done <<EOF
$(_pbm_scan_files "$1")
EOF
  return 0
}

# _pbm_assign <file> <VAR> → first VALID literal value of `VAR=…` (indented / export / local OK); the value must end at a
# quote, whitespace, `;` or EOL — `VAR="a/b${X}"` and `VAR=""` do not qualify
_pbm_assign() {
  local file="$1" var="$2" v
  while IFS= read -r v; do
    v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*=["'"'"']?//; s/["'"'"']?[[:space:]]*(;.*|#.*)?$//')
    [ -n "$v" ] || continue
    printf '%s\n' "$v"; return 0
  done <<EOF
$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?${var}=[\"']?[A-Za-z0-9][A-Za-z0-9_./+-]*[\"']?([[:space:]]*(;|#).*)?[[:space:]]*\$" "$file" 2>/dev/null)
EOF
  return 1
}

_pbm_file_home_bin_name() {   # first `$HOME/bin/<name>` / `~/bin/<name>` / `$INSTALL_DIR/<name>` literal (validated)
  local file="$1" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    v=${v##*/}
    _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  done <<EOF
$(LC_ALL=C grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | LC_ALL=C grep -oE '(\$HOME|~|\$INSTALL_DIR)/bin/[A-Za-z0-9_.-]+')
EOF
  return 1
}
_pbm_file_asset_name() {    # DECLARED release asset only: RELEASE_ASSET= → ASSET_NAME= → BINARY_NAME= when the file downloads BY that name
  local file="$1" v ve
  v=$(_pbm_assign "$file" RELEASE_ASSET) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" ASSET_NAME)    && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  # BINARY_NAME is also the install-name fallback; it is the ASSET only when a non-comment line fetches by it —
  # `releases/download/<tag>/$BINARY_NAME` (or the literal value there), `gh release download … --pattern "$BINARY_NAME"`,
  # or a browser_download_url match (every real wrapper that declares it does one of these). A wrapper that only installs
  # TO $BINARY_NAME has no declared asset — a guessed asset would now BLOCK the Case E bump, not just warn (#22 verify R4).
  if v=$(_pbm_assign "$file" BINARY_NAME) && _pbm_name_ok "$v"; then
    ve=$(printf '%s' "$v" | sed 's/\./\\./g')   # `.` is an ERE wildcard; the allowlist permits it in names (#22 verify R5)
    if LC_ALL=C grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | LC_ALL=C grep -qE "releases/download/[^[:space:]]*(\\\$\\{?BINARY_NAME|/${ve}([[:space:]\"']|\$))|(--pattern|-p)[[:space:]]+[\"']?\\\$\\{?BINARY_NAME|browser_download_url.*BINARY_NAME"; then
      printf '%s\n' "$v"; return 0
    fi
  fi
  return 1
}
_pbm_file_install_name() {  # INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>
  local file="$1" v
  v=$(_pbm_assign "$file" INSTALL_NAME) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" BINARY_NAME)  && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  _pbm_file_home_bin_name "$file"
}
_pbm_file_repo() {          # every repo this file downloads from, one per line; "?" = a download site whose repo is unknown
  local file="$1" v out rc    # (per release line, the value at the repo position of api.github.com/repos/… · github.com/…/releases/… ·
  out=$(_pbm_core repo "$file" "$_PBM_RELEASE_RE"); rc=$?   # gh api repos/… · --repo / --repo= / -R: a literal o/r, or a variable
  [ "$rc" = 0 ] || { printf '?\n'; return 0; }              # whose EVERY assignment is a literal o/r; anything else is "?")
  while IFS= read -r v; do    # a reader crash is "?" (cannot tell), never "no repo" (#22 verify R10)
    [ -n "$v" ] || continue
    if [ "$v" = '?' ] || _pbm_repo_ok "$v"; then printf '%s\n' "$v"; else printf '?\n'; fi
  done <<EOF
$out
EOF
  return 0
}

# _pbm_file_pin <file> [manifest] → "value|pinsrc" — what THIS wrapper downloads; the closed shapes are in the function body.
#   a literal pin                  → value|wrapper:<basename> rc 0   (basename through the allowlist, else ?)
#   a manifest read                → value|<key>              rc 0   (first key with a non-empty manifest value)
#   no pin variable, no literal version in the release URL → |none rc 1 (downloads latest)
#   key named, no usable value     → |<first key> rc 4  ·  first present value illegal → |<key> rc 3
#   any unrecognised shape / opaque value / non-x.y.z literal / literal version in the URL → |wrapper:<basename> rc 4
#   an opaque read that names a pin key (jq -r .binaryVersion) → |<key> rc 4  ·  the reader failing → |wrapper:<basename> rc 4
# _pbm_core <mode> <args…> → the closed-shape readers (pin / repo / mcp). #22 verify R9: R5–R9 emulated shell control flow
# with sed/grep and every round produced a counter-example; R10 RECOGNISES a closed set of shapes and answers "cannot tell" for
# everything else. Run with `python3 -I` (isolated: no cwd / script-dir imports — wrapper dirs are third-party content).
_pbm_core() {
  python3 -I - "$@" 2>/dev/null <<'PBM_CORE_PY'
# pbm_core — closed-shape readers for plugin-binary-meta.sh (#22 verify R9 → R10 → R11 → R12).
# Modes:  pin <wrapper> <manifest> <release-ERE> → prints "value|src" / "|src" ; exit 0 / 1 / 3 / 4
#         repo <wrapper> <release-ERE>            → prints one repo per line, "?" for a download site whose repo is unknown ; exit 0
#         mcp <.mcp.json>                        → exit 0 declares a plugin-local server / 1 does not / 4 cannot tell
# The readers RECOGNISE a closed set of shapes and answer "cannot tell" (4) for everything else. They do not emulate shell
# control flow: R5–R9 tried, and every round produced a counter-example; R10 left side paths open (a pin variable not named
# DESIRED_VERSION, a repo variable overwritten later) and R11 closes them with the same rule. R12 replaces indentation with a
# keyword block stack, accepts a manifest read only as the exact corpus pipeline over the plugin manifest, and treats every
# version position it cannot read (an unknown token, a `gh release download <tag>`, a URL split over lines) as "cannot tell".
import json, re, sys

KEY_RE = re.compile(r'"(binary_version|binaryVersion|version)"[^"]*:')
VER_OK = re.compile(r'^[0-9A-Za-z.+-]+$')
LIT_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_./+-]*$')
REPO_FULL = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')
VAR_FULL = re.compile(r'^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$')
NAME = r'[A-Za-z_][A-Za-z0-9_]*'


def logical_lines(path):
    raw = open(path, encoding='utf-8', errors='replace').read().split('\n')
    out, buf = [], ''
    for l in raw:
        if buf == '' and re.match(r'\s*#', l):
            out.append('')
            continue
        if l.endswith('\\'):
            buf += l[:-1] + ' '
            continue
        out.append(buf + l)
        buf = ''
    if buf:
        out.append(buf)
    return out


def pin_ok(v):
    return bool(v) and bool(VER_OK.match(v)) and v[0].isdigit()


def value_at(s, i):
    """the shell word starting at s[i] (quotes, $( ) balanced); returns (text, end)."""
    j, depth, q = i, 0, None
    while j < len(s):
        c = s[j]
        if q:
            if c == q:
                q = None
        elif c in '\'"':
            q = c
        elif s.startswith('$(', j):
            depth += 1
            j += 2
            continue
        elif c == '(' and depth:
            depth += 1
        elif c == ')' and depth:
            depth -= 1
        elif depth == 0 and (c.isspace() or c in ';|&)'):
            break
        j += 1
    return s[i:j], j


MANIFEST_OK = set()      # filled per file: variables whose every assignment ends in /.claude-plugin/plugin.json (+ an unassigned PLUGIN_JSON)
STAGE_OK = [re.compile(r'^head\s+(-1|-n\s*1)$'), re.compile(r'^cut\s+-d\s*(\'"\'|\\")\s*-f\s*4$'),
            re.compile(r'^sed\s+-E\s+\'s/\.\*"\(\[\^"\]\+\)"\$/\\1/\'$')]


def split_pipe(t):
    """split on unquoted `|` (not `||`)."""
    out, cur, q, i = [], '', None, 0
    while i < len(t):
        c = t[i]
        if q:
            if c == q:
                q = None
        elif c in '\'"':
            q = c
        elif c == '|' and t[i:i + 2] != '||' and (i == 0 or t[i - 1] != '|'):
            out.append(cur); cur = ''; i += 1; continue
        cur += c; i += 1
    out.append(cur)
    return [x.strip() for x in out]


def manifest_read(text):
    """the exact corpus shape `$(grep -o[E] '<…"KEY"…>' "$MANIFEST" [2>/dev/null] [| head -1] [| cut -d'"' -f4 | sed …] [|| true])`
    over a manifest variable → KEY; anything else → None (#22 verify R11: a key string in an assignment is not a manifest read)."""
    if not (text.startswith('$(') and text.endswith(')')):
        return None
    body = re.sub(r'\s*\|\|\s*true\s*$', '', text[2:-1].strip())
    stages = split_pipe(body)
    m = re.match(r'^grep\s+-oE?\s+\'([^\']*)\'\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?(\s+2>/dev/null)?$', stages[0])
    if not m or m.group(2) not in MANIFEST_OK:
        return None
    k = KEY_RE.search(m.group(1))
    if not k or not stages[1:] or not all(any(rx.match(st) for rx in STAGE_OK) for st in stages[1:]):
        return None
    return k.group(1)


def classify(text):
    key = manifest_read(text)
    if key:
        return ('key', key)
    inner = text
    if len(inner) >= 2 and inner[0] == inner[-1] and inner[0] in '\'"':
        inner = inner[1:-1]
    if inner == '':
        return ('empty', '')
    if LIT_RE.match(inner):
        return ('lit', inner) if pin_ok(inner) else ('bad', inner)
    return ('opaque', inner)


def prev_code(lines, k):
    k -= 1
    while k >= 0 and lines[k].strip() == '':
        k -= 1
    return k


def block_stacks(lines):
    """for every logical line, the stack of enclosing blocks BEFORE that line, from shell keywords — never from indentation
    (#22 verify R11: `if false; then` + an unindented assignment is not top level). Frames: ('func',) ('if', cond) ('elif', cond)
    ('else', cond-of-its-if) ('case',) ('loop',) ('brace',)."""
    stacks, st = [], []
    for l in lines:
        stacks.append(list(st))
        t = l.strip()
        if not t:
            continue
        if FUNC_DEF.match(t):
            st.append(('func',)); continue
        m = re.match(r'^if\s+(.*?)(\s*;\s*then)?\s*$', t)
        if m and not re.search(r'(^|[;\s])fi\s*$', t):
            st.append(('if', m.group(1))); continue
        if re.match(r'^elif\b', t):
            if st: st[-1] = ('elif', t)
            continue
        if t == 'else' or t.startswith('else '):
            if st and st[-1][0] in ('if', 'elif'):
                st[-1] = ('else', st[-1][1] if st[-1][0] == 'if' else '')
            continue
        if re.match(r'^fi\b', t):
            if st: st.pop()
            continue
        if re.match(r'^case\b.*\bin$', t):
            st.append(('case',)); continue
        if re.match(r'^esac\b', t):
            if st: st.pop()
            continue
        if re.match(r'^(for|while|until)\b', t) and not re.search(r'\bdone\b', t):
            st.append(('loop',)); continue
        if re.match(r'^done\b', t):
            if st: st.pop()
            continue
        if t in ('{', '('):
            st.append(('brace',)); continue
        if t in ('}', ')') or t.startswith('} ') or t.startswith('};'):
            if st: st.pop()
            continue
    return stacks


def guard_res(var):
    dv = r'"?\$\{?' + var + r'\}?"?'
    return (re.compile(r'(\[\[?\s+-n\s+' + dv + r'\s+\]\]?\s*\|\||\[\[?\s+-z\s+' + dv + r'\s+\]\]?\s*&&)\s*$'),
            re.compile(r'^\[\[?\s+-z\s+' + dv + r'\s+\]\]?$'))


MANIFEST_EXISTS = re.compile(r'^\[\[?\s+-[fr]\s+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?\s+\]\]?$')
FUNC_DEF = re.compile(r'^(function\s+' + NAME + r'(\s*\(\))?|' + NAME + r'\s*\(\))\s*\{\s*$')


def frame_ok(fr, zcond):
    """a block we recognise: a function body · `if [[ -f "$X" ]]` (manifest exists) · `if grep -q '"KEY"…'` · the only-if-empty
    `if [[ -z "$VAR" ]]` · the `else` of `if grep -q '"KEY"…'`. if uname / case / loops / elif / braces are not."""
    if fr[0] == 'func':
        return True
    if fr[0] in ('if', 'else'):
        c = fr[1]
        if fr[0] == 'if' and (MANIFEST_EXISTS.match(c) or zcond.match(c)):
            return True
        if c.startswith('grep -q') and KEY_RE.search(c.replace("'", '')):
            return True
    return False


def grep_key(cond):
    m = KEY_RE.search(cond.replace("'", '')) if cond.startswith('grep -q') else None
    return m.group(1) if m else None


GH_ARG_FLAGS = {'--repo', '-R', '-p', '--pattern', '-D', '--dir', '-O', '--output', '-A', '--archive'}


def version_token(tok):
    t = tok.strip('"\'')
    t = t[1:] if t.startswith('v') and len(t) > 1 and (t[1].isdigit() or t[1] == '$') else t
    m = re.match(r'^(\$\{?' + NAME + r'\}?|[0-9][A-Za-z0-9_.+-]*)$', t)
    if not m:
        return ('unknown',)
    v = VAR_FULL.match(t)
    return ('var', v.group(1)) if v else ('lit', t)


def version_positions(lines, rel):
    """every VERSION position on a release-download line: ('var', NAME) · ('lit', x.y.z) · ('latest',) · ('unknown',).
    A position we cannot read — an unknown token, `/releases/download` with nothing after it (a URL split over lines),
    `gh release download <tag>` with an unrecognised tag — is ('unknown',), never skipped (#22 verify R11)."""
    out = []
    for l in lines:
        if not l.strip() or not rel.search(l):
            continue
        for m in re.finditer(r'/releases/(latest|download|tags)\b(/?)', l):
            if m.group(1) == 'latest':
                out.append(('latest',)); continue
            if not m.group(2):
                out.append(('unknown',)); continue
            rest = l[m.end():]
            if rest.startswith('latest/') or rest.startswith('latest"'):
                out.append(('latest',)); continue
            t = re.match(r'v?(\$\{?' + NAME + r'\}?|[0-9][A-Za-z0-9_.+-]*)(?=[/"\'\s}]|$)', rest)
            if not t:
                out.append(('unknown',)); continue
            out.append(version_token(t.group(1)))
        for m in re.finditer(r'\bgh\s+release\s+download\b(.*)', l):
            args = re.split(r'[;|&]', m.group(1))[0].split()
            tag, skip = None, False
            for a in args:
                if skip:
                    skip = False; continue
                if a in GH_ARG_FLAGS:
                    skip = True; continue
                if a.startswith('-'):
                    continue
                tag = a; break
            out.append(('latest',) if tag is None else version_token(tag))
    return out


def manifest_vars(lines):
    """variables that name the plugin manifest: every assignment ends in `/.claude-plugin/plugin.json`; an unassigned
    `PLUGIN_JSON` is the corpus convention and counts too (accepted trade-off, #22 verify R11)."""
    seen = {}
    AS = re.compile(r'(?<![^\s;&|{(])(?:export\s+|local\s+|readonly\s+)?(' + NAME + r')=')
    for l in lines:
        for m in AS.finditer(l):
            text, _ = value_at(l, m.end())
            inner = text.strip('"\'')
            seen.setdefault(m.group(1), []).append(inner.endswith('/.claude-plugin/plugin.json'))
    ok = {v for v, flags in seen.items() if flags and all(flags)}
    if 'PLUGIN_JSON' not in seen:
        ok.add('PLUGIN_JSON')
    return ok


def mode_pin(path, manifest, rel_re):
    base = path.rsplit('/', 1)[-1]
    if not re.match(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$', base):
        base = '?'
    U = '|wrapper:%s' % base
    lines = logical_lines(path)
    rel = re.compile(rel_re.replace('[[:space:]]', r'\s'))
    MANIFEST_OK.clear(); MANIFEST_OK.update(manifest_vars(lines))
    pos = version_positions(lines, rel)
    if any(p[0] == 'unknown' for p in pos) or any(p[0] == 'lit' for p in pos):
        print(U); return 4                      # a version position we cannot read, or a literal version in the URL
    pvars = []
    for p in pos:
        if p[0] == 'var' and p[1] not in pvars:
            pvars.append(p[1])
    has_dv = any(re.search(r'(?<![^\s;&|{(])(?:export\s+|local\s+)?DESIRED_VERSION=', l) for l in lines)
    if has_dv:
        # DESIRED_VERSION must be what the URL uses: directly, or through a variable every assignment of which is built from it
        # (`TAG="v$DESIRED_VERSION"`); assigned but unused (only /releases/latest), or another variable there → rc 4 (#22 verify R11)
        derived = set()
        for vname in pvars:
            vals = []
            for l in lines:
                for m in re.finditer(r'(?<![^\s;&|{(])(?:export\s+|local\s+)?' + vname + r'=', l):
                    vals.append(value_at(l, m.end())[0])
            if vals and all(re.search(r'\$\{?DESIRED_VERSION\}?', v) for v in vals):
                derived.add(vname)
        if not pvars or any(v != 'DESIRED_VERSION' and v not in derived for v in pvars):
            print(U); return 4
        var = 'DESIRED_VERSION'
    else:
        if len(pvars) > 1:
            print(U); return 4
        if not pvars:
            m = re.search(r'(?<![A-Za-z0-9_])(binary_version|binaryVersion)(?![A-Za-z0-9_])', '\n'.join(lines))
            if m and not pos:                   # names a pin key but has no version position at all: cannot tell
                print('|%s' % m.group(1)); return 4
            print('|none'); return 1            # every download is /releases/latest (or a tag-less gh download): no pin
        var = pvars[0]
    g_same, g_cond = guard_res(var)
    ASSIGN = re.compile(r'(?<![^\s;&|{(])(?:export\s+|local\s+)?' + var + r'=')
    stacks = block_stacks(lines)
    elems, seen = [], False
    for k, l in enumerate(lines):
        for m in ASSIGN.finditer(l):
            seen = True
            frames = stacks[k]
            if not all(frame_ok(fr, g_cond) for fr in frames):
                print(U); return 4              # inside a block we do not recognise, at ANY level (keyword stack, not indentation)
            text, _ = value_at(l, m.end())
            kind, val = classify(text)
            pre = l[:m.start()]
            inner = frames[-1] if frames else None
            if kind == 'empty':
                if elems or pre.strip():
                    print(U); return 4
                continue
            if not elems:
                if pre.strip():
                    print(U); return 4
                gk = grep_key(inner[1]) if inner and inner[0] in ('if', 'else') else None
                if inner and inner[0] == 'else':
                    print(U); return 4          # a FIRST value only in an else branch
                if gk and (kind != 'key' or val != gk):
                    print(U); return 4          # `if grep -q KEY` around something other than a read of KEY
                g = 'first'
            elif g_same.search(pre):
                g = 'empty'
            elif pre.strip():
                print(U); return 4
            elif inner and inner[0] == 'if' and g_cond.match(inner[1]):
                g = 'empty'
            elif inner and inner[0] == 'else' and elems[-1][0] == 'key' and grep_key(inner[1]) == elems[-1][1]:
                g = ('absent', elems[-1][1])
            else:
                print(U); return 4              # a second value with no recognised only-if-empty guard
            elems.append((kind, val, g))
    if not seen or not elems:
        print(U); return 4
    for e in elems:
        if e[0] in ('opaque', 'bad'):
            m = re.search(r'(?<![A-Za-z0-9_])(binary_version|binaryVersion)(?![A-Za-z0-9_])', e[1])
            print('|%s' % m.group(1) if m else U); return 4
    first_key = next((e[1] for e in elems if e[0] == 'key'), '')
    data = None
    for kind, val, g in elems:
        if isinstance(g, tuple) and isinstance(data, dict) and g[1] in data:
            print('|%s' % g[1]); return 4       # `else` taken only when KEY is absent; KEY present but empty → wrapper refuses
        if kind == 'lit':
            print('%s|wrapper:%s' % (val, base)); return 0
        if not manifest:
            print('|%s' % first_key); return 4
        if data is None:
            try:
                data = json.load(open(manifest, encoding='utf-8'))
            except Exception:
                print('|%s' % first_key); return 4
            if not isinstance(data, dict):
                print('|%s' % first_key); return 4
        v = data.get(val)
        v = v if isinstance(v, str) else ''
        if v:
            if not pin_ok(v):
                print('|%s' % val); return 3
            print('%s|%s' % (v, val)); return 0
    print('|%s' % first_key); return 4


def mode_repo(path, rel_re):
    lines = logical_lines(path)
    rel = re.compile(rel_re.replace('[[:space:]]', r'\s'))   # the shell ERE uses POSIX classes; python's re does not
    # EVERY assignment to every variable: a readable `o/r` literal, or "?" (`${X:-…}`, `$F`, `$(…)`) — a later dynamic
    # overwrite must not leave the earlier literal looking definite (#22 verify R10)
    assigns = {}
    AS = re.compile(r'(?<![^\s;&|{(])(?:export\s+|local\s+|readonly\s+)?(' + NAME + r')=')
    for l in lines:
        for m in AS.finditer(l):
            text, _ = value_at(l, m.end())
            inner = text[1:-1] if len(text) >= 2 and text[0] == text[-1] and text[0] in '\'"' else text
            assigns.setdefault(m.group(1), []).append(inner if REPO_FULL.match(inner) else '?')
    sites = [
        re.compile(r'(?<![A-Za-z0-9.-])api\.github\.com/repos/([^\s"\'<>]+?)/releases'),
        re.compile(r'(?<![A-Za-z0-9.-])github\.com/([^\s"\'<>]+?)/releases/(?:download|tags|latest)'),
        re.compile(r'\bgh\s+api\s+["\']?/?repos/([^\s"\'<>]+?)/releases'),
        re.compile(r'(?:--repo(?:=|\s+)|(?<![A-Za-z0-9-])-R\s+)["\']?([^\s"\';|&)]+)'),
    ]
    out = []
    def add(v):
        if v not in out:
            out.append(v)
    for l in lines:
        if not l.strip() or not rel.search(l):
            continue
        for rx in sites:
            for m in rx.finditer(l):
                seg = m.group(1)
                if REPO_FULL.match(seg):
                    add(seg)
                    continue
                v = VAR_FULL.match(seg)
                if v:                           # one variable: every value it is ever assigned ("?" if any is not a literal)
                    for val in assigns.get(v.group(1), ['?']):
                        add(val)
                else:                           # `$OWNER/$NAME`, `${REPO:-x}`, anything else: unknown, never silently skipped
                    add('?')
    for v in out:
        print(v)
    return 0


def mode_mcp(path):
    try:
        d = json.load(open(path, encoding='utf-8'))
    except Exception:
        return 4
    if not isinstance(d, dict):
        return 4
    if 'mcpServers' in d and not isinstance(d['mcpServers'], dict):
        return 4                                # a malformed mcpServers is "cannot tell", not "no server" (#22 verify R11)
    servers = d['mcpServers'] if 'mcpServers' in d else d
    # a server BACKED BY A PLUGIN-LOCAL EXECUTABLE: its command lives under the plugin (`${CLAUDE_PLUGIN_ROOT}/…`, `./…`,
    # `bin/…`). A remote `url`, or `npx` / `uvx` / any PATH command, ships no release binary (#22 verify R10)
    for v in servers.values():
        if isinstance(v, dict) and isinstance(v.get('command'), str):
            c = v['command']
            if 'CLAUDE_PLUGIN_ROOT' in c or c.startswith('./') or c.startswith('bin/'):
                return 0
    return 1


try:
    mode = sys.argv[1]
    if mode == 'pin':
        rc = mode_pin(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == 'repo':
        rc = mode_repo(sys.argv[2], sys.argv[3])
    elif mode == 'mcp':
        rc = mode_mcp(sys.argv[2])
    else:
        rc = 2
except Exception:
    rc = 9
sys.exit(rc)
PBM_CORE_PY
}

_pbm_file_pin() {
  # Pin of ONE wrapper file, from a closed set of shapes (anything else → rc 4 `|wrapper:<file>`, never a guess). The pin VARIABLE
  # is DESIRED_VERSION when the file assigns it, otherwise the one variable the release URL puts at the version position
  # (`/releases/download/v$WANT/`, macdoc); none there and no literal version → `|none` rc 1 (downloads latest).
  #   (1) exactly one value assignment — an x.y.z literal, or a manifest read (the `"key"…:` shape);
  #   (2) an optional `VAR=""`, then values where EVERY value after the first carries a recognised only-if-still-empty guard:
  #       same line `[ -n "$VAR" ] ||` / `[ -z … ] &&`, previous line `if [[ -z "$VAR" ]]; then`, or the `else` at the same
  #       indentation as `if grep -q '"KEY"…'` right after reading KEY (only when KEY is absent; present-but-empty → rc 4).
  # Every value — the FIRST one included — must sit with nothing before it on its line and inside a recognised block: top level,
  # a function body, `if [[ -f "$X" ]]; then`, `if grep -q '"KEY"'` around a read of KEY, the -z guard, that `else`.
  # Anything else (an `if uname` / `case` / `[ -n "$X" ] &&` value, two unguarded values, `$(…) || "1.0.0"`, an opaque value,
  # a non-x.y.z literal, a reset to "" after a value, a literal version in the URL) → rc 4. Indentation alone means nothing.
  local file="$1" manifest="${2:-}" out rc
  out=$(_pbm_core pin "$file" "$manifest" "$_PBM_RELEASE_RE"); rc=$?
  case "$rc" in
    0|1|3|4) [ -n "$out" ] || { out="|wrapper:${file##*/}"; rc=4; } ;;
    *) out="|wrapper:${file##*/}"; rc=4 ;;  # the reader crashed or python3 is missing: cannot tell — never "no pin" (#22 verify R10)
  esac
  case "$out" in "|wrapper:"*) _pbm_name_ok "${out#|wrapper:}" || out="|wrapper:?" ;; esac
  printf '%s\n' "$out"
  return "$rc"
}

# ---- manifest -----------------------------------------------------------------

plugin_binary_version() {
  local manifest="$1" v
  v=$(_pbm_json_field "$manifest" binary_version) || return 4
  if [ -z "$v" ]; then v=$(_pbm_json_field "$manifest" binaryVersion) || return 4; fi
  [ -n "$v" ] || { printf '\n'; return 0; }
  _pbm_version_ok "$v" || { printf '\n'; return 3; }
  printf '%s\n' "$v"
}

plugin_binary_version_key() {
  local manifest="$1" a b
  a=$(_pbm_json_field "$manifest" binary_version) || return 4
  b=$(_pbm_json_field "$manifest" binaryVersion)  || return 4
  if [ -n "$a" ] && [ -n "$b" ]; then printf 'binary_version\n'; return 2; fi
  if [ -n "$a" ]; then printf 'binary_version\n'; return 0; fi
  if [ -n "$b" ]; then printf 'binaryVersion\n'; return 0; fi
  printf '\n'; return 1
}

# ---- structure ----------------------------------------------------------------

plugin_is_binary_backed() {
  local dir="$1" manifest="${2:-}" hits="" unknown="" f base key rc
  [ -d "$dir" ] || { printf '\n'; return 1; }
  # each probe answers yes / no / CANNOT TELL — an .mcp.json that does not parse or a manifest that cannot be read is not "no"
  # (#22 verify R8): rc 4 with `unknown:<probe>` when nothing hit and some probe could not answer
  if [ -f "$dir/.mcp.json" ]; then
    # declares a plugin-local server: `mcpServers` or the flat plugin format every real plugin uses, with a `command` under the
    # plugin (#22 verify R9 / R10); `{}`, remote `url`, npx / uvx declare no release binary; unparseable → cannot tell
    _pbm_core mcp "$dir/.mcp.json"; rc=$?
    case "$rc" in 0) hits="mcp.json" ;; 1) ;; *) unknown="unknown:mcp.json" ;; esac
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f##*/}; _pbm_name_ok "$base" || base='?'
    case "$f" in "$dir/bin/"*) hits="${hits:+$hits }bin:$base" ;; *) hits="${hits:+$hits }hook:$base" ;; esac
  done <<EOF
$(_pbm_wrapper_files "$dir")
EOF
  if [ -n "$manifest" ]; then
    key=$(plugin_binary_version_key "$manifest" 2>/dev/null); rc=$?
    if [ -n "$key" ]; then hits="${hits:+$hits }pin:$key"
    elif [ "$rc" = 4 ]; then unknown="${unknown:+$unknown }unknown:manifest"; fi
  fi
  # a symlink in bin/ or hooks/ is not scanned (it may point outside the plugin); with nothing else to go on that is "cannot tell"
  if [ -z "$hits" ] && [ -n "$(find "$dir/bin" "$dir/hooks" -maxdepth 1 -type l 2>/dev/null | head -1)" ]; then
    unknown="${unknown:+$unknown }unknown:symlink"
  fi
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; return 0; fi
  if [ -n "$unknown" ]; then printf '%s\n' "$unknown"; return 4; fi
  printf '\n'; return 1
}

plugin_binary_wrappers() {
  local dir="$1" manifest="${2:-}" f base where asset inst repo pin n=0
  [ -d "$dir" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f##*/}; _pbm_name_ok "$base" || base='?'
    case "$f" in "$dir/bin/"*) where=bin ;; *) where=hooks ;; esac
    asset=$(_pbm_file_asset_name "$f") || asset=""
    inst=$(_pbm_file_install_name "$f") || inst=""
    repo=$(_pbm_file_repo "$f"); case "$repo" in *"
"*|'?') repo="" ;; esac                                   # several repos, or a site whose repo is unknown: empty (plugin level says rc 2 / 1)
    pin=$(_pbm_file_pin "$f" "$manifest") || pin="${pin:-|none}"
    printf '%s|%s|%s|%s|%s|%s\n' "$where" "$base" "$asset" "$inst" "$repo" "$pin"; n=$((n + 1))
  done <<EOF
$(_pbm_wrapper_files "$dir")
EOF
  [ "$n" -ge 1 ]
}

plugin_binary_pin() {
  local dir="$1" manifest="$2" rows eff=hooks where pin src first="" srcs="" n=0 seen="" unread=""
  rows=$(plugin_binary_wrappers "$dir" "$manifest") || rows=""
  # the DOWNLOADING rows: bin/ when the plugin has any (its hooks are check scripts), else hooks/ (hook-only layout: macdoc, gifthub)
  while IFS='|' read -r where _; do [ "$where" = bin ] && { eff=bin; break; }; done <<EOF
$rows
EOF
  while IFS='|' read -r where _ _ _ _ pin src; do
    # a hooks/ row next to bin/ is normally a check script (src none). One that carries a pin downloads a pinned binary of its
    # own: the plugin pin then spans bin/ and hooks/, which no single bump can keep in step → cannot tell (#22 verify R10)
    [ -n "$where" ] || continue
    if [ "$where" != "$eff" ]; then [ "$src" = none ] || unread="${unread:-hooks:$src}"; [ "$src" = none ] || srcs="${srcs:+$srcs,}hooks:$src"; continue; fi
    [ "$src" = none ] || case ",$srcs," in *",$src,"*) ;; *) srcs="${srcs:+$srcs,}$src" ;; esac
    if [ -z "$pin" ]; then [ "$src" = none ] || unread="${unread:-$src}"; continue; fi
    case "$seen" in *"|$pin|"*) continue ;; esac
    seen="${seen:-|}$pin|"; n=$((n + 1)); [ -n "$first" ] || first="$pin"
  done <<EOF
$rows
EOF
  if [ "$n" = 0 ]; then
    [ -z "$unread" ] || { printf '|%s\n' "$srcs"; return 4; }
    printf '|none\n'; return 1
  fi
  # partial: some wrapper's pin cannot be read → the plugin's pin is unknown; print the sources only (a printed value would be a
  # plausible default the header forbids, #22 verify R7)
  [ -z "$unread" ] || { printf '|%s\n' "$srcs"; return 4; }
  printf '%s|%s\n' "$first" "$srcs"
  [ "$n" = 1 ] || return 2
  return 0
}

plugin_binary_repo() {
  local dir="$1" f cand first="" n=0 seen="" files="" binfiles="" unk=0
  [ -d "$dir" ] || { printf '\n'; return 1; }
  files=$(_pbm_wrapper_files "$dir")
  # a plugin with a bin/ wrapper takes its repo from bin/ only — a hooks/ check script pointing at an old fork
  # must not choose which remote's tags drive Case E (#22 verify R3); hook-only layouts use their hooks
  while IFS= read -r f; do case "$f" in "$dir/bin/"*) binfiles="${binfiles:+$binfiles
}$f" ;; esac; done <<EOF
$files
EOF
  [ -z "$binfiles" ] || files="$binfiles"
  # every download site of every file is merged: one site's repo must not hide another site that names a different repo or an
  # unknown one (#22 verify R5 / R9 / R10)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ "$cand" != '?' ] || { unk=1; continue; }
      case "$seen" in *"|$cand|"*) continue ;; esac
      seen="${seen:-|}$cand|"; n=$((n + 1)); [ -n "$first" ] || first="$cand"
    done <<EOC
$(_pbm_file_repo "$f")
EOC
  done <<EOF
$files
EOF
  printf '%s\n' "$first"
  [ "$n" -ge 1 ] || { [ "$unk" = 0 ] || return 4; return 1; }   # only unknown download sites: cannot tell (4), not "none" (1)
  [ "$n" = 1 ] && [ "$unk" = 0 ] || return 2      # a download site with an unknown repo next to a known one: not "the" repo
}

plugin_binary_name() {
  local dir="$1" f v
  [ -d "$dir" ] || { printf '\n'; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    v=$(_pbm_file_asset_name "$f") && { printf '%s\n' "$v"; return 0; }
  done <<EOF
$(_pbm_wrapper_files "$dir")
EOF
  printf '\n'; return 1
}

plugin_install_names() {
  local dir="$1" f v seen="" n=0
  [ -d "$dir" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    v=$(_pbm_file_install_name "$f") || continue
    case "$seen" in *"|$v|"*) continue ;; esac
    seen="${seen:-|}$v|"; printf '%s\n' "$v"; n=$((n + 1))
  done <<EOF
$(_pbm_wrapper_files "$dir")
EOF
  [ "$n" -ge 1 ]
}

plugin_installed_binary_version() {
  local dir="$1" name="${2:-}" side v
  if [ -z "$name" ]; then name=$(plugin_install_names "$dir" | head -1); fi
  [ -n "$name" ] || { printf '\n'; return 2; }
  _pbm_name_ok "$name" || { printf '\n'; return 2; }
  side="$(_pbm_bin_dir)/.$name.version"
  [ -f "$side" ] || { printf '\n'; return 1; }
  v=$(head -1 "$side" 2>/dev/null | tr -d '[:space:]')
  _pbm_version_ok "$v" || { printf '\n'; return 3; }
  printf '%s\n' "$v"
}

# ---- marketplace --------------------------------------------------------------

marketplace_entry_version() {
  local root="$1" plugin="$2" manifest="$1/.claude-plugin/marketplace.json" out rc
  [ -f "$manifest" ] && [ -r "$manifest" ] || { printf '\n'; return 4; }
  out=$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(4)
ps = d.get("plugins") if isinstance(d, dict) else None
if not isinstance(ps, list):
    sys.exit(4)
for p in ps:
    if isinstance(p, dict) and p.get("name") == sys.argv[2]:
        v = p.get("version")
        print(v if isinstance(v, str) else "")
        sys.exit(0)
sys.exit(1)
' "$manifest" "$plugin" 2>/dev/null); rc=$?
  case "$rc" in
    0) if [ -n "$out" ] && ! _pbm_version_ok "$out"; then printf '\n'; return 3; fi; printf '%s\n' "$out"; return 0 ;;
    1) printf '\n'; return 1 ;;
    *) printf '\n'; return 4 ;;
  esac
}

# ---- release ------------------------------------------------------------------

latest_release_version() {
  local repo="$1" gh tag
  _pbm_repo_ok "$repo" || { printf '\n'; return 1; }
  gh=$(_pbm_gh) || { printf '\n'; return 1; }
  tag=$("$gh" release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) || { printf '\n'; return 1; }
  tag=$(printf '%s' "$tag" | head -1 | tr -d '[:space:]'); tag=${tag#v}
  _pbm_version_ok "$tag" || { printf '\n'; return 1; }
  printf '%s\n' "$tag"
}

release_assets() {
  local repo="$1" tag="${2:-}" gh out n
  _pbm_repo_ok "$repo" || return 1
  gh=$(_pbm_gh) || return 1
  if [ -n "$tag" ]; then
    tag=${tag#v}; _pbm_version_ok "$tag" || return 1
    # pins are stored bare (0.3.0) while every real release tag is v0.3.0 (the wrappers build `v$DESIRED_VERSION` themselves);
    # try the v-prefixed tag first, the bare one second — a bare-only lookup made Signal 1 permanently "未核對" (#22 verify R3)
    out=$("$gh" release view "v$tag" --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null) \
      || out=$("$gh" release view "$tag" --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null) || return 1
  else out=$("$gh" release view --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null) || return 1; fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if _pbm_name_ok "$n"; then printf '%s\n' "$n"; else printf '?\n'; fi
  done <<EOF
$out
EOF
  return 0
}

version_gt() {
  local a="$1" b="$2"
  case "$a" in *.*.*) ;; *) return 2 ;; esac
  case "$b" in *.*.*) ;; *) return 2 ;; esac
  case "$a$b" in *[!0-9.]*) return 2 ;; esac
  awk -v a="$a" -v b="$b" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    if (na != 3 || nb != 3) exit 2
    for (i = 1; i <= 3; i++) { if (x[i] == "" || y[i] == "") exit 2 }
    for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}
