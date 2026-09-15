#!/bin/bash
# plugin-binary-meta.sh — single reading point for a binary-backed plugin's metadata (#22).
#
# Usage (sourced by skills; sits NEXT TO resolve-marketplace.sh, neither sources the other —
# consumers source both):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/plugin-binary-meta.sh"
#
#   plugin_binary_version <manifest>            # explicit manifest pin: binary_version → binaryVersion → "" (never `version`)
#                                               # rc 0 (value or empty) / 3 illegal value / 4 manifest unreadable
#   plugin_binary_version_key <manifest>        # which explicit pin key the file uses; rc 1 none / 2 both (binary_version printed) / 4
#   plugin_is_binary_backed <dir> [manifest]    # rc 0 + hit list "mcp.json bin:<f> hook:<f> pin:<key>" / rc 1 empty
#                                               #   .mcp.json counts only when its mcpServers object is non-empty
#   plugin_binary_wrappers <dir> [manifest]     # one row per file that DOWNLOADS a release:
#                                               #   "dir|file|asset|install|repo|pin|pinsrc"   dir ∈ bin|hooks; empty field = unknown
#                                               #   pinsrc ∈ wrapper:<file> | binary_version | binaryVersion | version | none
#   plugin_binary_pin <dir> <manifest>          # the pin the plugin's DOWNLOADING wrappers use — bin/ rows when any exist, else
#                                               #   hooks/ rows (hook-only layouts such as macdoc / gifthub) — "value|pinsrc[,pinsrc…]":
#                                               #   every distinct source in row order (two wrappers sharing one literal pin → two sources);
#                                               #   rc 0 every pinned wrapper agrees / 1 no wrapper has a pin / 2 wrappers disagree (first printed)
#                                               #   / 4 a wrapper names a manifest key whose value cannot be read (missing / illegal / unreadable)
#   plugin_binary_repo <dir>                    # owner/repo from the DOWNLOADING wrapper files (bin/ when any exist, else hooks/ — a
#                                               #   check hook can never re-point a plugin that has a bin/ wrapper), ranked: *_REPO= assignment
#                                               #   > release-URL literal; rc 0 one / 1 none / 2 several IN THE SAME TIER (first printed)
#   plugin_binary_name <dir>                    # first DECLARED asset name: RELEASE_ASSET= → ASSET_NAME= → BINARY_NAME=; rc 1 none
#                                               #   (never guessed from the install name — a guess would turn into a false "asset missing")
#   plugin_install_names <dir>                  # unique INSTALLED names (INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>), one/line
#   plugin_installed_binary_version <dir> [name]  # <bin dir>/.<name>.version; rc 1 no sidecar / 2 no name / 3 sidecar not a version
#   plugin_bin_dir                              # the sidecar directory (~/bin; PLUGIN_BIN_DIR under PBM_TEST=1)
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
#     has_binary_wrapper uses (references/distribution-detection.md). Detection is URL shape only;
#     the literal owner/repo is plugin_binary_repo's job (assignment beats URL; a bare
#     `github.com/o/r` docs link is never a candidate).
#   - PBM_GH / PLUGIN_BIN_DIR are TEST seams and are honoured only when PBM_TEST=1 is also set;
#     the production path has exactly one way to reach gh and one sidecar directory.

_PBM_RELEASE_RE='gh release download|gh api[[:space:]]+.*/releases|api\.github\.com/.*/releases|github\.com/.*/releases/(download|tags|latest)'

# ---- internal ---------------------------------------------------------------

# _pbm_json_field <file> <key>  → value (empty if absent / not a string); rc 4 unreadable
_pbm_json_field() {
  local file="$1" key="$2" out rc
  [ -f "$file" ] && [ -r "$file" ] || return 4
  out=$(python3 -c '
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
_pbm_repo_ok() {
  case "$1" in
    [A-Za-z0-9]*/[A-Za-z0-9]*) case "$1" in *[!A-Za-z0-9._/-]*|*/*/*) return 1 ;; esac; return 0 ;;
    *) return 1 ;;
  esac
}
_pbm_name_ok() { case "$1" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# _pbm_gh → the gh to run: PBM_GH only under PBM_TEST=1 and only as an absolute executable; rc 1 refuses
_pbm_gh() {
  if [ -n "${PBM_GH:-}" ] && [ "${PBM_TEST:-}" = 1 ]; then
    case "$PBM_GH" in /*) [ -x "$PBM_GH" ] && { printf '%s\n' "$PBM_GH"; return 0; } ;; esac
    return 1
  fi
  printf 'gh\n'
}
# _pbm_bin_dir → sidecar directory: PLUGIN_BIN_DIR only under PBM_TEST=1
_pbm_bin_dir() {
  if [ -n "${PLUGIN_BIN_DIR:-}" ] && [ "${PBM_TEST:-}" = 1 ]; then printf '%s\n' "$PLUGIN_BIN_DIR"; else printf '%s\n' "$HOME/bin"; fi
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

_pbm_file_repo_tier1() {   # `<X>_REPO=` / `REPO=` assignments (validated), one per line
  local file="$1" line v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    v=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*REPO=["'"'"']?//; s/["'"'"']?[[:space:]]*(;.*|#.*)?$//')
    _pbm_repo_ok "$v" && printf '%s\n' "$v"
  done <<EOF
$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*REPO=[\"']?[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*[\"']?([[:space:]]*(;|#).*)?[[:space:]]*\$" "$file" 2>/dev/null)
EOF
  return 0
}
_pbm_file_repo_tier2() {   # RELEASE URLs / `gh … --repo o/r` / `gh api …repos/o/r/releases` (validated), one per line
  local file="$1" cand v
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    v=$(printf '%s' "$cand" | sed -E 's/^--repo[[:space:]]+//; s#^gh api[[:space:]]+/?repos/##; s#^api\.github\.com/repos/##; s#^github\.com/##; s#/releases.*$##')
    _pbm_repo_ok "$v" && printf '%s\n' "$v"
  done <<EOF
$(LC_ALL=C grep -oE '(--repo[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*|gh api[[:space:]]+/?repos/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases|api\.github\.com/repos/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases|github\.com/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases/(download|tags|latest))' "$file" 2>/dev/null)
EOF
  return 0
}
_pbm_file_home_bin_name() {   # first `$HOME/bin/<name>` / `~/bin/<name>` / `$INSTALL_DIR/<name>` literal (validated)
  local file="$1" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    v=${v##*/}
    _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  done <<EOF
$(LC_ALL=C grep -oE '(\$HOME|~|\$INSTALL_DIR)/bin/[A-Za-z0-9_.-]+' "$file" 2>/dev/null)
EOF
  return 1
}
_pbm_file_asset_name() {    # DECLARED release asset only: RELEASE_ASSET= → ASSET_NAME= → BINARY_NAME= (never guessed from the install name)
  local file="$1" v
  v=$(_pbm_assign "$file" RELEASE_ASSET) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" ASSET_NAME)    && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" BINARY_NAME)   && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  return 1
}
_pbm_file_install_name() {  # INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>
  local file="$1" v
  v=$(_pbm_assign "$file" INSTALL_NAME) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" BINARY_NAME)  && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  _pbm_file_home_bin_name "$file"
}
_pbm_file_repo() {          # tier 1 else tier 2, first valid
  local file="$1" v
  v=$(_pbm_file_repo_tier1 "$file" | head -1); [ -n "$v" ] || v=$(_pbm_file_repo_tier2 "$file" | head -1)
  printf '%s\n' "$v"
}

# _pbm_file_pin <file> [manifest] → "value|pinsrc" — what THIS wrapper downloads (closed list of three sources)
#   (1) literal DESIRED_VERSION="x.y.z" in the file          → value|wrapper:<basename>   (basename through the allowlist, else ?)
#   (2) the manifest key(s) the file names on non-comment lines, in file order
#                                                           → value|<key>   (first key with a non-empty manifest value)
#   (3) neither                                             → |none        rc 1
#   (2) applies but no named key has a usable value          → |<first key> rc 4 (manifest missing / unreadable / key absent)
#   (2) applies and the first present value is illegal       → |<key>       rc 3
_pbm_file_pin() {
  local file="$1" manifest="${2:-}" v key first="" base
  base=${file##*/}; _pbm_name_ok "$base" || base='?'
  v=$(_pbm_assign "$file" DESIRED_VERSION)
  if [ -n "$v" ] && _pbm_version_ok "$v"; then printf '%s|wrapper:%s\n' "$v" "$base"; return 0; fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -n "$first" ] || first="$key"
    [ -n "$manifest" ] || continue
    v=$(_pbm_json_field "$manifest" "$key") || { printf '|%s\n' "$first"; return 4; }
    if [ -n "$v" ]; then
      _pbm_version_ok "$v" || { printf '|%s\n' "$key"; return 3; }
      printf '%s|%s\n' "$v" "$key"; return 0
    fi
  done <<EOF
$(LC_ALL=C grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | LC_ALL=C grep -oE '"(binary_version|binaryVersion|version)"[^"]*:' | sed -E 's/^"([A-Za-z_]+)".*$/\1/' | awk '!seen[$0]++')
EOF
  if [ -n "$first" ]; then printf '|%s\n' "$first"; return 4; fi
  printf '|none\n'; return 1
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
  local dir="$1" manifest="${2:-}" hits="" f base key
  [ -d "$dir" ] || { printf '\n'; return 1; }
  if [ -f "$dir/.mcp.json" ] && python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
s = d.get("mcpServers") if isinstance(d, dict) else None
sys.exit(0 if isinstance(s, dict) and len(s) > 0 else 1)
' "$dir/.mcp.json" 2>/dev/null; then hits="mcp.json"; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f##*/}; _pbm_name_ok "$base" || base='?'
    case "$f" in "$dir/bin/"*) hits="${hits:+$hits }bin:$base" ;; *) hits="${hits:+$hits }hook:$base" ;; esac
  done <<EOF
$(_pbm_wrapper_files "$dir")
EOF
  if [ -n "$manifest" ]; then
    key=$(plugin_binary_version_key "$manifest" 2>/dev/null)
    [ -n "$key" ] && hits="${hits:+$hits }pin:$key"
  fi
  printf '%s\n' "$hits"
  [ -n "$hits" ]
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
    repo=$(_pbm_file_repo "$f")
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
    [ "$where" = "$eff" ] || continue
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
  printf '%s|%s\n' "$first" "$srcs"
  [ "$n" = 1 ] || return 2
  [ -z "$unread" ] || return 4
  return 0
}

plugin_binary_repo() {
  local dir="$1" f cand tier first="" n=0 seen="" files="" binfiles=""
  [ -d "$dir" ] || { printf '\n'; return 1; }
  files=$(_pbm_wrapper_files "$dir")
  # a plugin with a bin/ wrapper takes its repo from bin/ only — a hooks/ check script pointing at an old fork
  # must not choose which remote's tags drive Case E (#22 verify R3); hook-only layouts use their hooks
  while IFS= read -r f; do case "$f" in "$dir/bin/"*) binfiles="${binfiles:+$binfiles
}$f" ;; esac; done <<EOF
$files
EOF
  [ -z "$binfiles" ] || files="$binfiles"
  for tier in 1 2; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$seen" in *"|$cand|"*) continue ;; esac
        seen="${seen:-|}$cand|"; n=$((n + 1)); [ -n "$first" ] || first="$cand"
      done <<EOF2
$(if [ "$tier" = 1 ]; then _pbm_file_repo_tier1 "$f"; else _pbm_file_repo_tier2 "$f"; fi)
EOF2
    done <<EOF
$files
EOF
    [ "$n" -ge 1 ] && break
  done
  printf '%s\n' "$first"
  [ "$n" -ge 1 ] || return 1
  [ "$n" = 1 ] || return 2
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
  out=$(python3 -c '
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
