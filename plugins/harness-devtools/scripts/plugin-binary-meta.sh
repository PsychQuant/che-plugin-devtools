#!/bin/bash
# plugin-binary-meta.sh — single reading point for a binary-backed plugin's metadata (#22).
#
# Usage (sourced by skills; sits NEXT TO resolve-marketplace.sh, neither sources the other —
# consumers source both):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/plugin-binary-meta.sh"
#
#   plugin_binary_version <manifest>            # binary_version → binaryVersion → "" ; does NOT fall back to `version`
#                                               # rc 0 (value or empty) / 3 illegal value / 4 manifest unreadable
#   plugin_binary_version_key <manifest>        # which pin key the file uses; rc 1 none / 2 both (binary_version printed) / 4
#   plugin_binary_version_effective <manifest>  # "value|key" with key ∈ binary_version|binaryVersion|version — the value a
#                                               # wrapper would actually download (che-keychain reads binaryVersion-or-version,
#                                               # che-apple-notes-mcp reads version); rc 1 none / 3 illegal / 4 unreadable
#   plugin_is_binary_backed <dir> [manifest]    # rc 0 + hit list "mcp.json bin:<f> hook:<f> pin:<key>" / rc 1 empty
#   plugin_binary_wrappers <dir>                # one row per wrapper FILE: "file|asset|install|repo" (empty field = unknown)
#   plugin_binary_repo <dir>                    # owner/repo, ranked: *_REPO= assignment > release-URL literal; rc 0 one /
#                                               # 1 none / 2 several IN THE SAME TIER (first printed)
#   plugin_binary_name <dir>                    # first valid ASSET name: BINARY_NAME= → INSTALL_NAME= → $HOME/bin/<name>; rc 1 none
#   plugin_install_names <dir>                  # unique INSTALLED names (INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>), one/line
#   plugin_installed_binary_version <dir> [name]  # ${PLUGIN_BIN_DIR:-$HOME/bin}/.<name>.version; rc 1 no sidecar / 2 no name
#   marketplace_entry_version <mp_root> <p>     # rc 0 (value, or EMPTY when the entry has no version) / 1 no entry / 3 illegal / 4 unreadable
#   latest_release_version <owner/repo>         # ${PBM_GH:-gh} release view … tagName, leading v stripped; rc 1 on failure
#   release_assets <owner/repo>                 # latest release asset names, one per line (allowlisted); rc 1 on failure
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
# CONTRACT
#   - bash 3.2 (no arrays needed; no nameref, no associative arrays); zsh-safe when sourced
#     (no unquoted `$VAR` word-splitting, no globs — `find` only; nomatch would abort a fence).
#   - Lookup paths write NOTHING to stderr and leave no variables behind (everything `local`).
#     Callers decide what to say.
#   - Values that will be echoed / used in URLs / used as paths pass an allowlist before being
#     printed — including the basenames of wrapper files (a file called `kc; rm -rf ~` must not
#     reach an agent-facing line).
#   - Field names are read in BOTH spellings; writers must preserve the file's own key
#     (plugin_binary_version_key) — che-keychain / che-transport-mcp wrappers read
#     `binaryVersion` themselves, so renaming the field would break them.
#   - ONE binary per plugin is NOT assumed. che-telegram-mcp ships two wrappers / two binaries /
#     two sidecars; agent-cacher installs two from one wrapper. Consumers that verify assets or
#     sidecars iterate plugin_binary_wrappers / plugin_install_names — the single-value getters
#     (plugin_binary_name / plugin_binary_repo) are for the "which repo does this plugin's
#     release live in" question only.
#   - ASSET name ≠ INSTALL name. `BINARY_NAME=CheKeychainMCP` is what the release asset is
#     called; `INSTALL_NAME=che-keychain` is the file on disk and the sidecar
#     `.che-keychain.version` is keyed by it. Signal 1 (asset present?) wants the former,
#     Phase 5 (sidecar == pin?) the latter. Each getter falls back to the other when only one
#     variable is declared.
#   - Detection pattern for "this file downloads a release" is, verbatim, the one idd-close's
#     has_binary_wrapper uses (references/distribution-detection.md). The owner/repo segment
#     is usually a VARIABLE in real wrappers (`…/repos/$REPO/releases/latest`), so detection is
#     URL shape only; the literal owner/repo is plugin_binary_repo's job, with its own allowlist
#     and ranking (an assignment beats a URL; a bare `github.com/o/r` docs link is never a
#     candidate — it must be a release URL).

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

# _pbm_version_ok <value>: [A-Za-z0-9.+-], non-empty, no leading . or -
_pbm_version_ok() {
  case "$1" in ''|.*|-*|*[!A-Za-z0-9.+-]*) return 1 ;; esac
  return 0
}

# _pbm_repo_ok <owner/repo>: both segments alnum-leading, [A-Za-z0-9._-] only, exactly one slash
_pbm_repo_ok() {
  case "$1" in
    [A-Za-z0-9]*/[A-Za-z0-9]*) case "$1" in *[!A-Za-z0-9._/-]*|*/*/*) return 1 ;; esac; return 0 ;;
    *) return 1 ;;
  esac
}

# _pbm_name_ok <name>: [A-Za-z0-9._-], not leading . or -, not empty  (binary names AND wrapper basenames)
_pbm_name_ok() {
  case "$1" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# _pbm_scan_files <dir> → regular files under bin/ (depth 1) and hooks/*.sh, one per line, sorted
_pbm_scan_files() {
  local dir="$1"
  { [ -d "$dir/bin" ]   && find "$dir/bin"   -maxdepth 1 -type f 2>/dev/null
    [ -d "$dir/hooks" ] && find "$dir/hooks" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
  } | sort
}

# _pbm_assign <file> <VAR> → first VALID quoted-or-bare value of `VAR=…` in the file (indented / `export` / `local` OK);
# the value must end at a quote, whitespace, `;` or EOL — `VAR="a/b${X}"` does not qualify (no partial matches).
_pbm_assign() {
  local file="$1" var="$2" v
  while IFS= read -r v; do
    v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*=["'"'"']?//; s/["'"'"']?[[:space:]]*(;.*|#.*)?$//')
    [ -n "$v" ] || continue
    printf '%s\n' "$v"; return 0
  done <<EOF
$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?${var}=[\"']?[A-Za-z0-9][A-Za-z0-9_./-]*[\"']?([[:space:]]*(;|#).*)?[[:space:]]*\$" "$file" 2>/dev/null)
EOF
  return 1
}

# _pbm_file_repo_tier1 <file> → repo from `<X>_REPO=` / `REPO=` assignments (validated), one per line
_pbm_file_repo_tier1() {
  local file="$1" line v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    v=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*REPO=["'"'"']?//; s/["'"'"']?[[:space:]]*(;.*|#.*)?$//')
    _pbm_repo_ok "$v" && printf '%s\n' "$v"
  done <<EOF
$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?[A-Z_]*REPO=[\"']?[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*[\"']?([[:space:]]*(;|#).*)?[[:space:]]*\$" "$file" 2>/dev/null)
EOF
}

# _pbm_file_repo_tier2 <file> → repo from RELEASE URLs / `gh … --repo o/r` (validated), one per line
_pbm_file_repo_tier2() {
  local file="$1" cand v
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    v=$(printf '%s' "$cand" | sed -E 's/^--repo[[:space:]]+//; s#^gh api[[:space:]]+/?repos/##; s#^api\.github\.com/repos/##; s#^github\.com/##; s#/releases.*$##')
    _pbm_repo_ok "$v" && printf '%s\n' "$v"
  done <<EOF
$(LC_ALL=C grep -oE '(--repo[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*|gh api[[:space:]]+/?repos/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases|api\.github\.com/repos/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases|github\.com/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/releases/(download|tags|latest))' "$file" 2>/dev/null)
EOF
}

# _pbm_file_home_bin_name <file> → first `$HOME/bin/<name>` / `~/bin/<name>` / `$INSTALL_DIR/<name>` literal (validated)
_pbm_file_home_bin_name() {
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

# _pbm_file_asset_name <file>: BINARY_NAME= → INSTALL_NAME= → $HOME/bin/<name>   (release-asset name)
_pbm_file_asset_name() {
  local file="$1" v
  v=$(_pbm_assign "$file" BINARY_NAME)  && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" INSTALL_NAME) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  _pbm_file_home_bin_name "$file"
}

# _pbm_file_install_name <file>: INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>   (on-disk / sidecar name)
_pbm_file_install_name() {
  local file="$1" v
  v=$(_pbm_assign "$file" INSTALL_NAME) && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(_pbm_assign "$file" BINARY_NAME)  && _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }
  _pbm_file_home_bin_name "$file"
}

# _pbm_file_is_wrapper <file>: DOWNLOADS a release. Declaring BINARY_NAME= alone is not enough —
# che-telegram-mcp/bin/test-wrapper-pid.sh declares one for a test stub and must not count as a third binary.
_pbm_file_is_wrapper() {
  LC_ALL=C grep -qE "$_PBM_RELEASE_RE" "$1" 2>/dev/null
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

# The pin a wrapper would actually download: explicit pin first, else the plugin `version` (the
# #77-era wrappers and che-keychain's fallback branch both read it). Prints "value|key" so the
# consumer can SAY which field it is comparing against — a value that came from `version` is a
# real comparison for che-apple-notes-mcp and a shell-vs-binary mix-up for a plugin whose two
# version numbers are independent; only the reader can tell, so the key is always shown.
plugin_binary_version_effective() {
  local manifest="$1" v key rc
  v=$(plugin_binary_version "$manifest"); rc=$?
  [ "$rc" = 4 ] && { printf '\n'; return 4; }
  [ "$rc" = 3 ] && { printf '\n'; return 3; }
  if [ -n "$v" ]; then
    key=$(plugin_binary_version_key "$manifest" 2>/dev/null); printf '%s|%s\n' "$v" "$key"; return 0
  fi
  v=$(_pbm_json_field "$manifest" version) || { printf '\n'; return 4; }
  [ -n "$v" ] || { printf '\n'; return 1; }
  _pbm_version_ok "$v" || { printf '\n'; return 3; }
  printf '%s|version\n' "$v"
}

# ---- structure ----------------------------------------------------------------

plugin_is_binary_backed() {
  local dir="$1" manifest="${2:-}" hits="" f base key
  [ -d "$dir" ] || { printf '\n'; return 1; }
  [ -f "$dir/.mcp.json" ] && hits="mcp.json"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    LC_ALL=C grep -qE "$_PBM_RELEASE_RE" "$f" 2>/dev/null || continue
    base=${f##*/}; _pbm_name_ok "$base" || base='?'     # unsafe filename never reaches an agent-facing line
    case "$f" in "$dir/bin/"*) hits="${hits:+$hits }bin:$base" ;; *) hits="${hits:+$hits }hook:$base" ;; esac
  done <<EOF
$(_pbm_scan_files "$dir")
EOF
  if [ -n "$manifest" ]; then
    key=$(plugin_binary_version_key "$manifest" 2>/dev/null)
    [ -n "$key" ] && hits="${hits:+$hits }pin:$key"
  fi
  printf '%s\n' "$hits"
  [ -n "$hits" ]
}

# One row per wrapper file — "file|asset|install|repo". `file` is the basename ('?' when it fails the
# allowlist), the other three are empty when that file does not declare them. Files that neither
# download a release nor declare a binary name are not wrappers and are not listed.
plugin_binary_wrappers() {
  local dir="$1" f base asset inst repo n=0
  [ -d "$dir" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _pbm_file_is_wrapper "$f" || continue
    base=${f##*/}; _pbm_name_ok "$base" || base='?'
    asset=$(_pbm_file_asset_name "$f") || asset=""
    inst=$(_pbm_file_install_name "$f") || inst=""
    repo=$(_pbm_file_repo_tier1 "$f" | head -1); [ -n "$repo" ] || repo=$(_pbm_file_repo_tier2 "$f" | head -1)
    printf '%s|%s|%s|%s\n' "$base" "$asset" "$inst" "$repo"; n=$((n + 1))
  done <<EOF
$(_pbm_scan_files "$dir")
EOF
  [ "$n" -ge 1 ]
}

plugin_binary_repo() {
  local dir="$1" f cand tier="" first="" n=0 seen=""
  [ -d "$dir" ] || { printf '\n'; return 1; }
  # tier 1 = assignments across all files; only if none, tier 2 = release URLs. Multi-valued
  # within the tier that answered → rc 2 (a docs link can never outvote an assignment).
  for tier in 1 2; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$seen" in *"|$cand|"*) continue ;; esac
        seen="${seen:-|}$cand|"; n=$((n + 1)); [ -n "$first" ] || first="$cand"
      done <<EOF2
$( [ "$tier" = 1 ] && _pbm_file_repo_tier1 "$f" || _pbm_file_repo_tier2 "$f" )
EOF2
    done <<EOF
$(_pbm_scan_files "$dir")
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
    _pbm_file_is_wrapper "$f" || continue
    v=$(_pbm_file_asset_name "$f") && { printf '%s\n' "$v"; return 0; }   # each candidate validated; a bad one is skipped
  done <<EOF
$(_pbm_scan_files "$dir")
EOF
  printf '\n'; return 1
}

plugin_install_names() {
  local dir="$1" f v seen="" n=0
  [ -d "$dir" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _pbm_file_is_wrapper "$f" || continue
    v=$(_pbm_file_install_name "$f") || continue
    case "$seen" in *"|$v|"*) continue ;; esac
    seen="${seen:-|}$v|"; printf '%s\n' "$v"; n=$((n + 1))
  done <<EOF
$(_pbm_scan_files "$dir")
EOF
  [ "$n" -ge 1 ]
}

plugin_installed_binary_version() {
  local dir="$1" name="${2:-}" side v
  if [ -z "$name" ]; then name=$(plugin_install_names "$dir" | head -1); fi
  [ -n "$name" ] || { printf '\n'; return 2; }
  _pbm_name_ok "$name" || { printf '\n'; return 2; }
  side="${PLUGIN_BIN_DIR:-$HOME/bin}/.$name.version"
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

# PBM_GH is a TEST seam (the suites inject a stub so nothing touches the network). When set it must
# be an absolute path to an existing executable — a bare command name from the environment is refused.
latest_release_version() {
  local repo="$1" gh="${PBM_GH:-gh}" tag
  _pbm_repo_ok "$repo" || { printf '\n'; return 1; }
  if [ -n "${PBM_GH:-}" ]; then case "$gh" in /*) [ -x "$gh" ] || { printf '\n'; return 1; } ;; *) printf '\n'; return 1 ;; esac; fi
  tag=$("$gh" release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) || { printf '\n'; return 1; }
  tag=$(printf '%s' "$tag" | head -1 | tr -d '[:space:]'); tag=${tag#v}
  _pbm_version_ok "$tag" || { printf '\n'; return 1; }
  printf '%s\n' "$tag"
}

# release_assets <owner/repo> → asset names of the latest release, one per line; rc 1 when gh fails
# (network / auth / no release) — the caller must say UNKNOWN, not "asset missing". Same PBM_GH seam.
release_assets() {
  local repo="$1" gh="${PBM_GH:-gh}" out
  _pbm_repo_ok "$repo" || return 1
  if [ -n "${PBM_GH:-}" ]; then case "$gh" in /*) [ -x "$gh" ] || return 1 ;; *) return 1 ;; esac; fi
  out=$("$gh" release view --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null) || return 1
  printf '%s\n' "$out" | LC_ALL=C grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$'
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
