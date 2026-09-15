#!/bin/bash
# plugin-binary-meta.sh — single reading point for a binary-backed plugin's metadata (#22).
#
# Usage (sourced by skills; sits NEXT TO resolve-marketplace.sh, neither sources the other —
# consumers source both):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/plugin-binary-meta.sh"
#
#   plugin_binary_version <manifest>          # binary_version → binaryVersion → "" ; never falls back to `version`
#                                             # rc 0 (value or empty) / 3 illegal value / 4 manifest unreadable
#   plugin_binary_version_key <manifest>      # which key the file actually uses; rc 1 none / 2 both (binary_version printed)
#   plugin_is_binary_backed <dir> [manifest]  # rc 0 + hit list "mcp.json bin:<f> hook:<f> pin:<key>" / rc 1 empty
#   plugin_binary_repo <dir>                  # owner/repo from bin/* + hooks/*.sh; rc 0 one / 1 none / 2 several (first printed)
#   plugin_binary_name <dir>                  # BINARY_NAME= → INSTALL_NAME= → $HOME/bin/<name> literal; rc 1 none
#   plugin_installed_binary_version <dir>     # ${PLUGIN_BIN_DIR:-$HOME/bin}/.<name>.version; rc 1 no sidecar / 2 no name (UNKNOWN)
#   marketplace_entry_version <mp_root> <p>   # rc 0 (value, or EMPTY when the entry has no version) / 1 no entry / 4 unreadable
#   latest_release_version <owner/repo>       # ${PBM_GH:-gh} release view … tagName, leading v stripped; rc 1 on failure
#   version_gt <a> <b>                        # rc 0 a>b / 1 not / 2 not comparable (non x.y.z)
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
#   - Lookup paths write NOTHING to stderr. Callers decide what to say.
#   - Values that will be echoed / used in URLs pass an allowlist before being printed.
#   - Field names are read in BOTH spellings; writers must preserve the file's own key
#     (plugin_binary_version_key) — che-keychain / che-transport-mcp wrappers read
#     `binaryVersion` themselves, so renaming the field would break them.
#   - Detection pattern for "this file downloads a release" is the same one idd-close's
#     has_binary_wrapper uses (URL shape, not variable name):
#       gh release download | api.github.com/repos/<o>/<r>/releases | github.com/<o>/<r>/releases/(download|tags|latest)

# The owner/repo segments are usually a VARIABLE in real wrappers (`…/repos/$REPO/releases/latest`),
# so the shape check is "a repos/<something>/releases" URL — extracting the literal owner/repo is
# plugin_binary_repo's job, with its own allowlist.
_PBM_RELEASE_RE='gh release download|api\.github\.com/repos/[^[:space:]"'"'"']+/releases|github\.com/[^[:space:]"'"'"']+/releases/(download|tags|latest)'

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

# _pbm_name_ok <name>: [A-Za-z0-9._-], not leading . or -, not empty
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

# ---- manifest -----------------------------------------------------------------

plugin_binary_version() {
  local manifest="$1" v rc
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
  [ -f "$dir/.mcp.json" ] && hits="mcp.json"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    LC_ALL=C grep -qE "$_PBM_RELEASE_RE" "$f" 2>/dev/null || continue
    base=${f##*/}
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

plugin_binary_repo() {
  local dir="$1" f cand first="" n=0 seen=""
  [ -d "$dir" ] || { printf '\n'; return 1; }
  # candidates, in file order: assignment `<X>_REPO="o/r"` / `REPO="o/r"` (quotes optional),
  # `--repo o/r`, api.github.com/repos/o/r, github.com/o/r/releases — then dedupe, validate
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      cand=$(printf '%s' "$cand" | sed -E 's/^[A-Z_]*REPO="?//; s/^--repo[[:space:]]+//; s#^api\.github\.com/repos/##; s#^github\.com/##; s#/releases$##; s/"$//')
      _pbm_repo_ok "$cand" || continue
      case "$seen" in *"|$cand|"*) continue ;; esac
      seen="${seen:-|}$cand|"; n=$((n + 1)); [ -n "$first" ] || first="$cand"
    done <<EOF2
$(LC_ALL=C grep -oE '(^[A-Z_]*REPO="?|--repo[[:space:]]+|api\.github\.com/repos/|github\.com/)[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*(/releases)?' "$f" 2>/dev/null)
EOF2
  done <<EOF
$(_pbm_scan_files "$dir")
EOF
  printf '%s\n' "$first"
  [ "$n" -ge 1 ] || return 1
  [ "$n" = 1 ] || return 2
}

plugin_binary_name() {
  local dir="$1" f v
  [ -d "$dir" ] || { printf '\n'; return 1; }
  for key in BINARY_NAME INSTALL_NAME; do
    v=$(_pbm_scan_files "$dir" | while IFS= read -r f; do
          [ -n "$f" ] || continue
          grep "^$key=" "$f" 2>/dev/null | head -1 | cut -s -d'"' -f2
        done | grep -m1 .)
    if [ -n "$v" ]; then _pbm_name_ok "$v" && { printf '%s\n' "$v"; return 0; }; fi
  done
  v=$(_pbm_scan_files "$dir" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -oE '(\$HOME|~|\$INSTALL_DIR)/bin/[A-Za-z0-9_.-]+' "$f" 2>/dev/null | head -1 | sed 's#.*/##'
      done | grep -m1 .)
  if [ -n "$v" ] && _pbm_name_ok "$v"; then printf '%s\n' "$v"; return 0; fi
  printf '\n'; return 1
}

plugin_installed_binary_version() {
  local dir="$1" name side v
  name=$(plugin_binary_name "$dir") || { printf '\n'; return 2; }
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

latest_release_version() {
  local repo="$1" gh="${PBM_GH:-gh}" tag
  _pbm_repo_ok "$repo" || { printf '\n'; return 1; }
  tag=$("$gh" release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) || { printf '\n'; return 1; }
  tag=$(printf '%s' "$tag" | head -1 | tr -d '[:space:]'); tag=${tag#v}
  _pbm_version_ok "$tag" || { printf '\n'; return 1; }
  printf '%s\n' "$tag"
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
