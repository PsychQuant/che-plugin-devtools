#!/bin/bash
# resolve-marketplace.sh — single source of truth for marketplace repo paths.
#
# Usage (sourced by skills / hooks / scripts):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-marketplace.sh"
#
#   resolve_marketplace_root che-plugin-devtools
#   # → /Users/che/Developer/che-plugin-devtools
#
#   list_marketplaces
#   # → one name per line
#
#   find_plugin_marketplace harness-devtools
#   # → che-plugin-devtools|/Users/che/Developer/che-plugin-devtools|/Users/che/Developer/che-plugin-devtools/plugins/harness-devtools
#   #   three fields since #18: name|root|plugin_dir — the third is the manifest's
#   #   plugins[].source resolved against root (with a plugins/<name> fallback for
#   #   entry-less / non-local / unreadable cases), never a bare layout guess
#
#   resolve_plugin_dir /Users/che/Developer/che-keychain che-keychain
#   # → /Users/che/Developer/che-keychain/plugin        (rc 0)
#   # rc 1 not listed and nothing under plugins/<name>; rc 2 listed but unusable
#   # (bad string, missing dir); rc 4 manifest unreadable; rc 5 non-local source
#   # (git-subdir object / URL) with nothing materialized — full table at the function
#
#   plugin_source_of <root> <plugin>          # plugins[].source, sanitized, same rc table
#   marketplace_plugin_names <root>           # declared ∪ plugins/ dirs, one per line
#   git diff --name-only HEAD~3 | plugin_names_for_paths <root>   # which plugins those paths belong to
#   marketplace_index                         # name<TAB>root, every marketplace once
#   plugin_ctx_path <plugin>                  # private state file for the Step 0.1 → later fences hand-off
#   write_plugin_ctx <file> <mp> <root> <dir> <plugin> / load_plugin_ctx <file> <plugin> / remove_plugin_ctx <file>
#
# WHY THIS EXISTS
#   Before v1.0.0, five places hardcoded /Users/che/Developer/psychquant-claude-plugins
#   (plugin-health / plugin-debug / plugin-upgrade / plugin-create SKILL.md, plus
#   rules/tool-readme-sync.md). That was a single-marketplace assumption baked into
#   what is inherently a multi-marketplace tool: harness-devtools now lives in
#   che-plugin-devtools but still manages plugins in psychquant-claude-plugins (28),
#   sinica-claude-plugins (2) and che-local-plugins (8).
#
#   Where the tool lives and what the tool manages are two different things.
#
# BASH 3.2 CONSTRAINT
#   macOS ships /bin/bash 3.2.57. No namerefs (`local -n`), no associative arrays
#   (`declare -A`). Both fail at runtime with only a stderr line, and because these
#   scripts run with `set -u` but not `set -e`, execution CONTINUES with the
#   assignment silently skipped. That exact failure mode is live in
#   doc-guardian's doc-update-config.sh. Keep this file 3.2-clean; the test suite
#   asserts a clean stderr under /bin/bash.
#
# ADDING A MARKETPLACE
#   Nothing to do. A marketplace is discovered by its own
#   `.claude-plugin/marketplace.json` — the `name` field in that file is the
#   authoritative identity. Put the repo under ~/Developer (one or two levels
#   deep) and it resolves.
#
#   Before #20 this file carried TWO hand-synced hardcoded lists (a name list
#   and a name->path case). Both held 4 entries; the machine had 33 marketplaces.
#   The test suite asserted the two lists agreed with EACH OTHER, so it could
#   never catch them being jointly wrong — and `assert_eq "lists 4 marketplaces"`
#   actively locked the gap in.
#
# WHY find(1) AND NOT A GLOB
#   Two zsh behaviours make globbing unsafe here, and this file is `source`d so
#   it runs in the CALLER's shell (see the #16 note below):
#     1. A glob stored in a variable is NOT expanded by zsh (no GLOB_SUBST).
#     2. A glob with no matches ABORTS with `no matches found:` on stderr,
#        which would break the "sourcing under zsh emits no stderr" test.
#   `find` has neither problem and its newline-delimited output feeds the same
#   `while IFS= read -r` idiom this file already uses. Measured on 38 manifests:
#   0.058s with the prunes below (a python3-per-file parse was 0.80s).

set -u

# Where marketplaces live, relative to $HOME. Repos are found one or two
# directory levels down (hence -maxdepth 4: <level>/<level>/.claude-plugin/f):
# depth 2 is required — bestasr lives at bestASR-project/bestASR, che-ical-mcp at
# che-mcps/che-ical-mcp. Not a variable-held glob (see WHY find(1) above).
MARKETPLACE_SEARCH_ROOT="${MARKETPLACE_SEARCH_ROOT:-$HOME/Developer}"

# Every marketplace.json under the search root, one path per line.
# Prunes keep the depth-4 walk at ~0.06s; without them it is ~0.18s.
_marketplace_manifests() {
  find "$MARKETPLACE_SEARCH_ROOT" -mindepth 1 -maxdepth 4 \
    \( -name .git -o -name node_modules -o -name .build -o -name .venv \) -prune -o \
    -type f -name marketplace.json -path '*/.claude-plugin/*' -print 2>/dev/null
}

# The top-level "name" of a marketplace.json, or non-zero if it has none.
#
# Fast path is a sed bounded to the text BEFORE the first "plugins" key. That
# bound is the whole point: an unbounded "first name wins" sed returns a
# PLUGIN's name for a manifest that lists "plugins" before "name" — silently,
# and a wrong marketplace identity is worse than no answer. Bounded, that same
# manifest yields empty, which is detectable, so we fall back to a real JSON
# parser for exactly those files (0 of 38 on this machine today).
_marketplace_name_of() {
  local manifest="${1:-}" name
  [ -f "$manifest" ] || return 1
  name=$(sed -n '/"plugins"/q
/"name"[[:space:]]*:/{ s/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p; q; }' \
         "$manifest" 2>/dev/null)
  if [ -z "$name" ] && command -v python3 >/dev/null 2>&1; then
    name=$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1])).get("name",""))' "$manifest" 2>/dev/null)
  fi
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# True when $1 is a git worktree rather than a main checkout.
#
# A worktree carries the same marketplace.json. Resolving to one would put
# plugin-update's git gate on the worktree instead of the real checkout — the
# failure #16 added Step 0.1 to prevent, arriving by a different door.
_is_git_worktree() {
  local d="${1:-}" p out gitdir commondir
  [ -d "$d" ] || return 1

  # Fast path, no subprocess. Walk up to the nearest .git and look at its type:
  # a main checkout has a .git *directory* and is never a worktree. That settles
  # 33 of the 38 candidates here without spawning anything. Only a .git *file* is
  # ambiguous — linked worktrees and submodules both use one — so only those pay
  # for git. (Two of the five .git files here are submodules, not worktrees, so
  # the file case genuinely cannot be decided on type alone.)
  p="$d"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    if [ -e "$p/.git" ]; then
      [ -d "$p/.git" ] && return 1
      break
    fi
    p="${p%/*}"
  done
  { [ -z "$p" ] || [ "$p" = "/" ]; } && return 1

  # One process, both paths already absolute (git 2.31+). The older two-call form
  # below needs the cd/pwd dance because git returns whichever form is shorter
  # relative to the cwd: from a subdirectory of a main checkout, --git-dir comes
  # back absolute while --git-common-dir comes back as `../.git`. Comparing those
  # raw strings calls every such subdirectory a worktree.
  out=$(git -C "$d" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  if [ -n "$out" ]; then
    gitdir=$(printf '%s\n' "$out" | sed -n 1p)
    commondir=$(printf '%s\n' "$out" | sed -n 2p)
  else
    gitdir=$(cd "$d" 2>/dev/null && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
    commondir=$(cd "$d" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
  fi
  [ -n "$gitdir" ] && [ -n "$commondir" ] || return 1
  [ "$gitdir" != "$commondir" ]
}

# name<TAB>root for every manifest that is not inside a git worktree. Both public
# accessors read this, so their notion of "a marketplace" cannot drift apart.
#
# Worktrees are the only *global* exclusion: selecting one would put
# plugin-update's Phase 0.5 git gate on the wrong checkout, which is #16's bug
# arriving by another road.
#
# **Deliberately not memoised in a shell variable.** Every call site is
# `$(resolve_marketplace_root x)`, so the function body runs in a subshell and any
# variable it sets dies with that subshell — a cache written there never survives
# to the next call. The cost is kept down in _is_git_worktree instead, which is
# where it actually was.
_marketplace_index() {
  local manifest dir name
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    dir="${manifest%/*}"; dir="${dir%/*}"   # two dirnames, no subprocess
    _is_git_worktree "$dir" && continue
    name=$(_marketplace_name_of "$manifest") || continue
    printf '%s\t%s\n' "$name" "$dir"
  done <<EOF
$(_marketplace_manifests)
EOF
}

# Every root declaring <name>, in precedence order, one per line. Exposed so
# callers (and tests) can see shadowing rather than infer it — same contract as
# resolve-mcp-project.sh's mcp_project_candidates.
#
# owning a plugins/ directory is a **tie-break among same-name candidates, not an
# admission test**. che-local-plugins is declared by two manifests: the parent
# che-claude-config (an aggregator whose plugin sources point into the
# subdirectory, and which has no plugins/ of its own) and the subdirectory
# itself. The tie-break picks the latter, matching what the pre-#20 hardcoded
# path resolved to.
#
# Applying it globally instead would drop every single-plugin marketplace — rush,
# che-keychain, che-ical-mcp and six others, whose repo *is* the plugin and whose
# manifest source reads `./plugin` (singular). That is #20's own coverage gap
# rebuilt out of different parts, so the narrower rule is the load-bearing one.
marketplace_candidates() {
  local want="${1:-}" all preferred
  [ -n "$want" ] || return 1

  all=$(_marketplace_index | awk -F'\t' -v w="$want" '$1 == w { print $2 }')
  [ -n "$all" ] || return 1

  if [ "$(printf '%s\n' "$all" | grep -c .)" -gt 1 ]; then
    preferred=$(printf '%s\n' "$all" | while IFS= read -r d; do
      [ -d "$d/plugins" ] && printf '%s\n' "$d"
    done)
    [ -n "$preferred" ] && all="$preferred"
  fi

  printf '%s\n' "$all"
}

# Resolve a marketplace name to its local repo root.
# Returns 1 for unknown or empty names.
#
# Takes the first candidate. When more than one survives both filters they are
# genuinely distinct checkouts of the same marketplace; warn rather than pick
# silently (resolve-mcp-project.sh does the same for MCP projects).
resolve_marketplace_root() {
  local name="${1:-}" cands count
  [ -n "$name" ] || return 1

  cands=$(marketplace_candidates "$name") || return 1
  count=$(printf '%s\n' "$cands" | grep -c .)
  if [ "$count" -gt 1 ]; then
    echo "⚠ marketplace '$name' 同時存在於多個 checkout，取第一個：" >&2
    printf '%s\n' "$cands" | sed 's/^/    /' >&2
    echo "  若取到的不是你要的那份，清掉過時的副本。" >&2
  fi
  printf '%s\n' "$cands" | head -1
}

# Print every discovered marketplace name, one per line, sorted and deduped.
list_marketplaces() {
  _marketplace_index | cut -f1 | sort -u
}

# The `source` field of plugin <$2> in manifest <$1>.
#   rc 0  printed the source: a relative-looking STRING (validated later by
#         resolve_plugin_dir — this function only classifies, it does not trust)
#   rc 1  the manifest never mentions the name (cheap pre-filter) or lists no
#         such plugin. NOTE the pre-filter is a heuristic: a manifest that does
#         not parse AND never mentions the name is rc 1, not rc 4 — we cannot
#         afford an interpreter launch per manifest per lookup to tell them apart
#   rc 2  listed, but the source is unusable: empty string, number, boolean,
#         null, list — printed as JSON so a caller can show what it saw
#   rc 3  cannot tell — python3 missing, or present but not runnable (the macOS
#         CLT stub passes `command -v` and then fails); caller decides how to degrade
#   rc 4  cannot tell — the manifest exists but is unreadable, does not parse, or
#         is not shaped like a manifest (top level not an object, plugins not a list)
#   rc 5  listed, but the source is NOT a local path: an object (git-subdir etc.)
#         or a URL / `github:owner/repo` string — legal schema, just not resolvable
#         here; printed as-is so a caller can show it
#
# The name is looked up INSIDE the plugins[] array, which sed cannot do reliably
# (the bounded trick _marketplace_name_of uses only works for a top-level key
# that precedes "plugins"). So this is python3 — but only after a fixed-string
# grep shows the manifest mentions the name at all. find_plugin_marketplace
# walks every manifest on the machine (38 here); without the pre-filter that is
# 38 interpreter launches per lookup (~0.8s measured), with it, one or two.
#
# ORDER MATTERS: readability, then python3, then the grep pre-filter. The first
# cut had grep first, so a manifest that never mentions the name returned rc 1
# and the no-python3 legacy probe was unreachable; and every non-zero python
# exit collapsed into rc 1, so a trailing comma in a hand-edited manifest read
# as "not on this marketplace" (#18 verify R1). Each verdict now has its own
# exit code and the shell keeps them apart.
_plugin_source_of() {
  local manifest="${1:-}" plugin="${2:-}" src rc
  [ -f "$manifest" ] && [ -n "$plugin" ] || return 1
  [ -r "$manifest" ] || return 4
  command -v python3 >/dev/null 2>&1 || return 3
  grep -qF "\"$plugin\"" "$manifest" 2>/dev/null || return 1
  src=$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(20)
if not isinstance(d, dict):
    sys.exit(20)
plugins = d.get("plugins")
if plugins is None:
    plugins = []
if not isinstance(plugins, list):
    sys.exit(20)
for p in plugins:
    if isinstance(p, dict) and p.get("name") == sys.argv[2]:
        s = p.get("source")
        if isinstance(s, str) and s.strip() == "":
            print(json.dumps(s)); sys.exit(11)
        if isinstance(s, str) and any(ord(c) < 32 or ord(c) == 127 for c in s):
            print(json.dumps(s)); sys.exit(11)   # control chars incl. a trailing newline the shell would strip
        if isinstance(s, str):
            if "://" in s or ":" in s.split("/")[0]:
                print(s); sys.exit(12)      # URL or scheme:owner/repo
            print(s); sys.exit(0)
        if isinstance(s, dict):
            print(json.dumps(s, ensure_ascii=False)); sys.exit(12)
        print(json.dumps(s)); sys.exit(11)  # number / bool / null / list
sys.exit(10)' "$manifest" "$plugin" 2>/dev/null); rc=$?
  case "$rc" in
    0)  [ -n "$src" ] || return 2; printf '%s\n' "$src"; return 0 ;;
    10) return 1 ;;
    11) printf '%s\n' "$src"; return 2 ;;
    12) printf '%s\n' "$src"; return 5 ;;
    20) return 4 ;;
    *)  return 3 ;;                         # interpreter itself failed
  esac
}

# Public form of the above, keyed by marketplace ROOT (what skills have in hand).
# Same rc table. The value is third-party file content, so it comes back with
# control characters stripped and capped at 200 bytes — a caller cannot forget
# to sanitize what it never receives raw. (The raw form stays private.)
plugin_source_of() {
  local root="${1:-}" plugin="${2:-}" out rc
  [ -n "$root" ] && [ -n "$plugin" ] || return 1
  out=$(_plugin_source_of "$root/.claude-plugin/marketplace.json" "$plugin"); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | LC_ALL=C tr -d '[:cntrl:]' | LC_ALL=C cut -c1-200
  return "$rc"
}

# Where plugin <$2> lives inside marketplace root <$1>, read from the manifest.
#   rc 0  printed the absolute directory
#   rc 1  not listed (or never mentioned) AND nothing plugin-shaped at plugins/<name>
#   rc 2  listed with a source that is unusable — empty / non-string, absolute
#         path, `..` traversal, quotes / backslash / `$` / backtick / `|` /
#         control characters, a directory that does not exist or resolves
#         (through a symlink) to outside <root>, or a directory that is not the
#         plugin asked for (no .claude-plugin/plugin.json, unparsable, or its
#         name differs). rc 2 is definite: it is NOT rescued by plugins/<name>
#   rc 3  no usable python3 to read the manifest, AND nothing at plugins/<name>
#   rc 4  the manifest is unreadable / does not parse / is mis-shaped, AND
#         nothing at plugins/<name>
#   rc 5  the source is not a local path (object such as git-subdir, or a
#         URL / github: string) AND nothing at plugins/<name>
#   rc 6  the plugin NAME itself is not a single path segment of [A-Za-z0-9._-]
#         not starting with `.` or `-` (the name is interpolated into paths and
#         argv downstream; nothing is probed)
#
# WHY THIS EXISTS (#18)
#   Before it, find_plugin_marketplace decided "this marketplace has the plugin"
#   by testing `$root/plugins/<name>` — a guess at the aggregator layout that
#   never consulted plugins[].source. Every single-plugin marketplace
#   (che-keychain, che-apple-mail-mcp, che-ical-mcp: `"source": "./plugin"`)
#   therefore returned rc 1, and plugin-update's Step 0.1 read that as "not in
#   any registered marketplace" — a message pointing at the wrong fix.
#
# THE LEGACY PROBE IS STILL HERE, ON PURPOSE (#18 verify R1/R2)
#   The manifest is the source of truth for WHERE a plugin lives, but the old
#   directory probe handled states that must keep working: an entry-less
#   directory under plugins/ (the "new plugin, add its entry" state Phase 2
#   Step 3 of plugin-update exists for); an object / URL source whose subtree
#   has been materialized under plugins/<name> (akashic-mcp here); a manifest
#   that does not parse, a python3 that will not run, or a typo'd source —
#   "cannot tell" must not become "no". ONE rule, applied to every non-zero
#   classification: manifest first; when it yields no USABLE local directory,
#   probe plugins/<name>; only when both fail does the rc say why.
#
# `.` and `./` mean "the repo root is the plugin" and resolve to <root> itself —
# accepted only when <root>/.claude-plugin/plugin.json exists, otherwise any
# manifest on the search path could claim any plugin name by declaring `.`.
# Callers must use the absolute directory as a git pathspec; relativising
# against <root> gives an empty string for this layout. A root-sourced plugin
# owns every path in its repo, so path-to-plugin mapping treats every path as
# touching it — that is the layout's meaning, not a false positive.
#
# The returned path is the LOGICAL path (root + normalized source, no symlink
# resolution), so it composes with the root the caller already holds; the
# physical path is only used for the containment check.
_normalize_rel() {   # collapse //, /./, leading ./, trailing /. and /
  printf '%s' "${1:-}" | sed -E 's#/+#/#g; s#(^|/)(\./)+#\1#g; s#/\.$##; s#^\./##; s#/$##; s#^\.$##'
}

# A plugin / marketplace NAME is a single path segment of [A-Za-z0-9._-]. Explicit
# ranges under LC_ALL=C — [[:alnum:]] is locale-dependent and admitted more than the
# comment claimed (#18 verify R3).
_valid_name() {
  local LC_ALL=C n="${1:-}"
  case "$n" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac   # no dotfile / option-shaped names
  return 0
}

# True when <$2> is PHYSICALLY inside <$1> (both resolved with pwd -P, so a symlink
# that points outside the root fails even though its logical path looks contained).
_contained_in() {
  local rootp dirp
  rootp=$(cd "${1:-}" 2>/dev/null && pwd -P) || return 1
  dirp=$(cd "${2:-}" 2>/dev/null && pwd -P) || return 1
  case "$dirp" in "$rootp"|"$rootp"/*) return 0 ;; esac
  return 1
}

# Possession for a MANIFEST-sourced directory: it must be a plugin
# (.claude-plugin/plugin.json present) and, when that file names itself, the name
# must be the one asked for. "A directory exists there" is not possession — a
# root that is SOME plugin could otherwise claim ANY name with `source: "."`,
# and a typo'd source pointing at docs/ would read as a plugin with nothing in
# it (#18 verify R3). The legacy plugins/<name> probe uses the directory name
# as its possession claim instead (materialized git-subdir subtrees may carry
# no plugin.json), so this check applies only to manifest-derived directories.
# ONE possession rule for every path (manifest-derived and legacy plugins/<name>;
# #18 verify R5 found the two halves diverging so a plugin could pass Step 0.1
# and stop resolving once its entry was written):
#   * a plugin manifest may live at <dir>/.claude-plugin/plugin.json OR
#     <dir>/plugin.json (Claude Code accepts both; safari-browser uses the latter)
#   * if a manifest exists: it must parse and its name must equal the requested
#     name. FAIL CLOSED — unparsable, nameless, or unreadable is not possessed
#     (a root with a broken plugin.json could otherwise claim any name).
#   * if no manifest exists: the directory must be NAMED after the plugin and
#     look like a plugin (a materialized git-subdir subtree such as akashic-mcp
#     carries skills/ but no manifest; an empty directory is not a plugin).
#   * without python3 the manifest cannot be read: only the named-directory
#     rule remains.
_plugin_manifest_of() {
  local d="${1:-}"
  if [ -f "$d/.claude-plugin/plugin.json" ]; then printf '%s\n' "$d/.claude-plugin/plugin.json"
  elif [ -f "$d/plugin.json" ]; then printf '%s\n' "$d/plugin.json"
  else return 1; fi
}
_looks_like_plugin() {
  local d="${1:-}" c
  for c in .claude-plugin plugin.json skills commands hooks agents .mcp.json; do
    [ -e "$d/$c" ] && return 0
  done
  return 1
}
_is_plugin_named() {
  local dir="${1:-}" plugin="${2:-}" pj name rc
  if ! pj=$(_plugin_manifest_of "$dir"); then
    [ "${dir##*/}" = "$plugin" ] && _looks_like_plugin "$dir"; return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    [ "${dir##*/}" = "$plugin" ]; return
  fi
  name=$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
n = d.get("name") if isinstance(d, dict) else None
if not isinstance(n, str) or not n:
    sys.exit(3)
print(n)' "$pj" 2>/dev/null); rc=$?
  case "$rc" in
    0) [ "$name" = "$plugin" ] ;;
    2|3) return 1 ;;                                  # unparsable / nameless: fail closed
    *) [ "${dir##*/}" = "$plugin" ] ;;                # interpreter itself failed: named-directory rule only
  esac
}

resolve_plugin_dir() {
  local LC_ALL=C root="${1:-}" plugin="${2:-}" src dir rc legacy rel
  [ -n "$root" ] && [ -n "$plugin" ] || return 1
  _valid_name "$plugin" || return 6
  legacy="$root/plugins/$plugin"
  src=$(_plugin_source_of "$root/.claude-plugin/marketplace.json" "$plugin"); rc=$?
  if [ "$rc" -eq 0 ]; then
    case "$src" in
      *[[:cntrl:]]*|*\'*|*\"*|*\\*|*\$*|*\`*|*\|*) rc=2 ;;
      /*) rc=2 ;;
      ..|../*|*/..|*/../*) rc=2 ;;
    esac
  fi
  if [ "$rc" -eq 0 ]; then
    rel=$(_normalize_rel "$src")
    case "$rel" in
      ..|../*|*/..|*/../*) rc=2 ;;
    esac
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -z "$rel" ]; then dir="$root"; else dir="$root/$rel"; fi
    [ -d "$dir" ] && _contained_in "$root" "$dir" && _is_plugin_named "$dir" "$plugin" || rc=2
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  # rc 2 is a DEFINITE answer ("the manifest names a local path and it is wrong"),
  # not a "cannot tell": a typo'd source must surface, not be quietly rescued by
  # a plugins/<name> that happens to exist (#18 verify R4). The legacy probe
  # backs only rc 1 / 3 / 4 / 5.
  [ "$rc" -eq 2 ] && return 2
  # legacy probe: same possession rule as above (_is_plugin_named — a manifest
  # there must agree, otherwise the directory name + plugin shape), and
  # containment is not optional here either — a symlink at plugins/<name>
  # pointing outside used to pass while the same target via the manifest was
  # refused (#18 verify R3).
  if [ -d "$legacy" ] && _contained_in "$root" "$legacy" && _is_plugin_named "$legacy" "$plugin"; then
    printf '%s\n' "$legacy"
    return 0
  fi
  return "$rc"
}

# Every plugin name declared by the manifest at <root> UNION every directory
# under <root>/plugins, one per line, sorted, deduped. The union — not a
# fallback — because an entry-less plugins/<name> is exactly the plugin that
# most needs plugin-update (its entry has not been written yet), and a
# manifest-only listing made it invisible to path mapping (#18 verify R2).
marketplace_plugin_names() {
  local root="${1:-}" manifest declared dirs
  [ -n "$root" ] || return 1
  manifest="$root/.claude-plugin/marketplace.json"
  declared=""
  if [ -r "$manifest" ] && command -v python3 >/dev/null 2>&1; then
    declared=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for p in (d.get("plugins") if isinstance(d, dict) else None) or []:
    if isinstance(p, dict) and isinstance(p.get("name"), str): print(p["name"])' "$manifest" 2>/dev/null) || declared=""
  fi
  dirs=""
  if [ -d "$root/plugins" ]; then
    # same possession bar as the legacy probe: a directory that does not look like
    # a plugin (empty, or a stray folder) is not a plugin name
    dirs=$(find "$root/plugins" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | while IFS= read -r d; do
      [ -d "$d" ] && _looks_like_plugin "$d" && printf '%s\n' "${d##*/}"
    done)
  fi
  # only names that can ever resolve (rc 6 otherwise) — a public helper must not
  # hand callers raw third-party strings (#18 verify R3)
  printf '%s\n%s\n' "$declared" "$dirs" | grep . | sort -u | while IFS= read -r n; do
    _valid_name "$n" && printf '%s\n' "$n"
  done
  return 0
}

# Map repo-relative paths (stdin, one per line — `git log --name-only` /
# `git diff --name-only` output) to the plugin names whose directory contains
# them, via the manifest — never via a `plugins/<x>/` prefix guess (#18 verify
# R1: single-plugin marketplaces keep their files under plugin/). One name per
# line, sorted, deduped. A root-sourced plugin (`source: "."`) owns every path
# in the repo and is therefore reported for any input — by design (see
# resolve_plugin_dir); a caller that wants "commits touched nothing" semantics
# gets none for that layout.
plugin_names_for_paths() {
  local root="${1:-}" paths name dir rel prefix rc
  [ -n "$root" ] || return 1
  paths=$(cat)
  [ -n "$paths" ] || return 0
  # git prints paths relative to the repo TOPLEVEL; the marketplace root may be a
  # subdirectory of it (che-local-plugins inside che-claude-config). Align by
  # prepending the root's own prefix inside the repo; not a git repo → no prefix.
  prefix=$(git -C "$root" rev-parse --show-prefix 2>/dev/null) || prefix=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # "cannot resolve" must not read as "not touched": say so on stderr and
    # move on (the consumers' counts stay clean, the gap is visible). #18 R5
    dir=$(resolve_plugin_dir "$root" "$name" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "⚠ plugin_names_for_paths: '$name' did not resolve (rc $rc) — its paths are NOT counted; fix its entry / plugin.json" >&2
      continue
    fi
    if [ "$dir" = "$root" ]; then
      rel="$prefix"
    else
      rel="$prefix${dir#"$root"/}/"
    fi
    if [ -z "$rel" ]; then
      printf '%s\n' "$name"                 # root-is-plugin at the toplevel: owns every path
      continue
    fi
    printf '%s\n' "$paths" | awk -v p="$rel" 'index($0, p) == 1 { f = 1; exit } END { exit !f }' \
      && printf '%s\n' "$name"
  done <<EOF
$(marketplace_plugin_names "$root")
EOF
  return 0
}

# ── Step 0.1 context hand-off for plugin-update (#18 verify R3/R4) ──
# Each bash fence of a skill is its own Bash tool call; nothing survives between
# them except what the agent pastes. Pasting a value read from a third-party
# manifest (the marketplace name) into shell text is an injection surface, and
# pasting only the NAME cannot pin the CHECKOUT Step 0.1 gated (two same-named
# checkouts, two different tie-break rules). So Step 0.1 WRITES the validated
# triple to a file and every later fence LOADS and re-verifies it. The agent
# pastes exactly one thing: the plugin name it was invoked with.
#
# The file is DATA, never code: it is parsed line by line and never sourced
# (the first cut `. `-sourced it — every statement had run before the first
# check fired). It lives in a private state directory, is created with mktemp
# and moved into place (a symlink planted at the final path is replaced, not
# followed), and is refused on load unless it is a regular file owned by the
# current user. Path: $(plugin_ctx_path <plugin>).
#
#   write_plugin_ctx <file> <mp_name> <root> <plugin_dir> <plugin>
#     rc 0 written; rc 6 a name is invalid; rc 2 a path is unusable (control
#     characters, quotes, `|`, not a directory) or the file cannot be created
#   load_plugin_ctx <file> <plugin>
#     parses the file, then re-verifies: names valid, MP_ROOT is one of that
#     marketplace's candidates, resolve_plugin_dir(MP_ROOT, plugin) still gives
#     PLUGIN_DIR. Sets MP_NAME MP_ROOT PLUGIN_DIR CTX_ID in the caller's shell.
#     rc 1 missing; rc 2 verification failed (incl. older than
#     PLUGIN_CTX_TTL_SECONDS, default 6 h); rc 3 refused (symlink / not owned /
#     not a regular file); rc 6 invalid plugin name (message on stderr)
#   remove_plugin_ctx <file>   — Phase 5 cleanup; a stale context must not let a
#     later run skip Step 0.1's gate
plugin_ctx_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/harness-devtools"
}
plugin_ctx_path() {
  _valid_name "${1:-}" || return 6
  printf '%s/plugin-update-ctx-%s\n' "$(plugin_ctx_dir)" "$1"
}
_ctx_value_ok() {   # a path we will later cd into and quote: no shell-significant bytes ('=' is fine: the KEY= prefix is anchored)
  local LC_ALL=C v="${1:-}"
  case "$v" in ''|*[[:cntrl:]]*|*\'*|*\"*|*\\*|*\$*|*\`*|*\|*) return 1 ;; esac
  return 0
}
_dir_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }
PLUGIN_CTX_TTL_SECONDS="${PLUGIN_CTX_TTL_SECONDS:-21600}"   # 6 h: a context from an aborted run must not pin the next one
write_plugin_ctx() {
  local file="${1:-}" mp="${2:-}" root="${3:-}" dir="${4:-}" plugin="${5:-}" v d tmp
  [ -n "$file" ] || return 2
  _valid_name "$mp" && _valid_name "$plugin" || return 6
  for v in "$root" "$dir"; do
    _ctx_value_ok "$v" && [ -d "$v" ] || return 2
  done
  d=${file%/*}
  [ "$d" != "$file" ] || d=.
  ( umask 077; mkdir -p "$d" ) 2>/dev/null || return 2
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || return 2
  case "$(_dir_mode "$d")" in 700) : ;; *) chmod 700 "$d" 2>/dev/null && [ "$(_dir_mode "$d")" = 700 ] || return 2 ;; esac   # a pre-existing shared-writable dir is not a boundary
  tmp=$(umask 077; mktemp "$d/.ctx.XXXXXX" 2>/dev/null) || return 2
  printf 'MP_NAME=%s\nMP_ROOT=%s\nPLUGIN_DIR=%s\nPLUGIN_NAME=%s\nCTX_ID=%s\nWRITTEN=%s\nWRITTEN_EPOCH=%s\n' \
    "$mp" "$root" "$dir" "$plugin" "$$-$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 2; }
  # mv replaces a symlink planted at $file instead of writing through it
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 2; }
}
_ctx_field() {   # value of KEY= line in <file>; exactly one line, nothing else read
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}
load_plugin_ctx() {
  local file="${1:-}" plugin="${2:-}" got rc epoch
  _valid_name "$plugin" || { echo "✗ plugin name '$(printf '%s' "$plugin" | LC_ALL=C tr -d '[:cntrl:]' | LC_ALL=C cut -c1-80)' is not a single [A-Za-z0-9._-] segment" >&2; return 6; }
  [ -e "$file" ] || { echo "✗ no Step 0.1 context at $file — run Step 0.1 first" >&2; return 1; }
  [ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] \
    || { echo "✗ refusing $file: must be a regular file owned by you (not a symlink)" >&2; return 3; }
  MP_NAME=$(_ctx_field "$file" MP_NAME); MP_ROOT=$(_ctx_field "$file" MP_ROOT)
  PLUGIN_DIR=$(_ctx_field "$file" PLUGIN_DIR); PLUGIN_NAME=$(_ctx_field "$file" PLUGIN_NAME)
  CTX_ID=$(_ctx_field "$file" CTX_ID)
  [ "$PLUGIN_NAME" = "$plugin" ] || { echo "✗ context at $file is for '$(printf '%s' "$PLUGIN_NAME" | LC_ALL=C tr -d '[:cntrl:]' | LC_ALL=C cut -c1-80)', not '$plugin'" >&2; return 2; }
  _valid_name "$MP_NAME" || { echo "✗ context marketplace name is not [A-Za-z0-9._-]" >&2; return 2; }
  _ctx_value_ok "$MP_ROOT" && _ctx_value_ok "$PLUGIN_DIR" || { echo "✗ context paths contain shell-significant bytes" >&2; return 2; }
  epoch=$(_ctx_field "$file" WRITTEN_EPOCH)
  case "$epoch" in ''|*[!0-9]*) echo "✗ context has no valid timestamp — run Step 0.1 again" >&2; return 2 ;; esac
  if [ $(( $(date +%s) - epoch )) -gt "$PLUGIN_CTX_TTL_SECONDS" ]; then
    echo "✗ context at $file is older than ${PLUGIN_CTX_TTL_SECONDS}s (left by an earlier run) — run Step 0.1 again" >&2; return 2
  fi
  # same source of truth as find_plugin_marketplace: the raw index (name<TAB>root),
  # NOT marketplace_candidates — that one applies the plugins/ tie-break and drops a
  # nested same-name parent that Step 0.1 legitimately resolved through (#18 R5)
  marketplace_index 2>/dev/null | awk -F'\t' -v n="$MP_NAME" -v r="$MP_ROOT" '$1 == n && $2 == r { f = 1 } END { exit !f }' \
    || { echo "✗ $MP_ROOT is not an indexed checkout of marketplace '$MP_NAME' any more" >&2; return 2; }
  got=$(resolve_plugin_dir "$MP_ROOT" "$plugin"); rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$PLUGIN_DIR" ] \
    || { echo "✗ '$plugin' no longer resolves to $PLUGIN_DIR in $MP_ROOT (resolve_plugin_dir rc $rc, got '${got:-}')" >&2; return 2; }
  return 0
}
remove_plugin_ctx() {
  local file="${1:-}"
  [ -n "$file" ] && [ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] && rm -f -- "$file"
  return 0
}

# name<TAB>root for every discovered marketplace, in index order — the public
# form of _marketplace_index for callers that must walk every root ONCE (the
# plugin-update Step 0.1 diagnostic loop: per-name marketplace_candidates calls
# rebuilt the index 33 times, ~14 s before the first line of output).
marketplace_index() {
  _marketplace_index
}

# Given a plugin name, find which marketplace contains it.
# Prints "<marketplace-name>|<repo-root>|<plugin-dir>" and returns 0 on hit;
# returns 1 if the plugin is not found in any known marketplace. The third field
# is resolve_plugin_dir's answer (#18); consumers read all three:
#   IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$(find_plugin_marketplace x)"
find_plugin_marketplace() {
  local plugin="${1:-}" name root dir
  [ -n "$plugin" ] || return 1

  # Walks the index directly rather than calling resolve_marketplace_root per
  # name. Two reasons, both found while verifying #20:
  #
  #   * that loop rebuilt the whole index once per marketplace — 33 scans for one
  #     lookup;
  #   * resolve_marketplace_root warns on ambiguous names, so looking up `macdoc`
  #     printed a multi-checkout warning about che-apple-mail-mcp. The warning is
  #     right for a name the *caller* asked for and pure noise for one this sweep
  #     happened to walk past.
  #
  # Skipping the tie-break loses nothing here: the tie-break prefers candidates
  # owning a plugins/ directory, and a hit below requires a USABLE local
  # directory — the manifest's source resolved inside the root (a `.` layout
  # additionally needs plugin.json at the root), or a materialized
  # plugins/<name> — so a tie-break loser can only match when it genuinely
  # hosts the plugin's files. Declaration alone is not possession.
  #
  # A non-zero resolve_plugin_dir (rc 2 / 3 / 4 / 5) is NOT a hit: the same
  # plugin may be complete in another checkout further down the index. Step 0.1
  # of plugin-update re-asks resolve_plugin_dir per root when the whole walk
  # misses, so those rcs still surface in the abort message with their cause.
  #
  # An invalid name (rc 6) cannot match anywhere, so the walk is skipped. A root
  # containing the field separator would misalign the three-field contract, so
  # such roots are skipped too.
  #
  # here-doc, not a pipe: a pipe opens a subshell, so `return 0` would end only
  # that subshell and the function would fall through to `return 1`.
  _valid_name "$plugin" || return 1
  while IFS="$(printf '\t')" read -r name root; do
    [ -n "$root" ] || continue
    case "$root$name" in *\|*) continue ;; esac
    if dir=$(resolve_plugin_dir "$root" "$plugin"); then
      echo "$name|$root|$dir"
      return 0
    fi
  done <<EOF
$(_marketplace_index)
EOF
  return 1
}

