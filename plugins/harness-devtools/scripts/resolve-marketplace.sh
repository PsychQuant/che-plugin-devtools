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
#   find_plugin_marketplace akashic-mcp
#   # → psychquant-claude-plugins|/Users/che/Developer/psychquant-claude-plugins|/Users/che/Developer/psychquant-claude-plugins/plugins/akashic-mcp
#   #   three fields since #18: name|root|plugin_dir — the third is the manifest's
#   #   plugins[].source resolved against root, never a `plugins/<name>` guess
#
#   resolve_plugin_dir /Users/che/Developer/che-keychain che-keychain
#   # → /Users/che/Developer/che-keychain/plugin        (rc 0)
#   # rc 1: the manifest lists no such plugin
#   # rc 2: listed, but source is not a relative path or the directory is missing
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
#   rc 0  printed the source (a string; a non-string source is printed as-is so
#         the caller can reject it)
#   rc 1  manifest missing, or it lists no such plugin
#   rc 3  python3 unavailable — caller decides how to degrade
#
# The name is looked up INSIDE the plugins[] array, which sed cannot do reliably
# (the bounded trick _marketplace_name_of uses only works for a top-level key
# that precedes "plugins"). So this is python3 — but only after a fixed-string
# grep shows the manifest mentions the name at all. find_plugin_marketplace
# walks every manifest on the machine (38 here); without the pre-filter that is
# 38 interpreter launches per lookup (~0.8s measured), with it, one or two.
_plugin_source_of() {
  local manifest="${1:-}" plugin="${2:-}" src
  [ -f "$manifest" ] && [ -n "$plugin" ] || return 1
  grep -qF "\"$plugin\"" "$manifest" 2>/dev/null || return 1
  command -v python3 >/dev/null 2>&1 || return 3
  src=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for p in d.get("plugins") or []:
    if isinstance(p, dict) and p.get("name") == sys.argv[2]:
        s = p.get("source")
        print(s if isinstance(s, str) else json.dumps(s))
        sys.exit(0)
sys.exit(1)' "$manifest" "$plugin" 2>/dev/null) || return 1
  [ -n "$src" ] || return 1
  printf '%s\n' "$src"
}

# Where plugin <$2> lives inside marketplace root <$1>, read from the manifest.
#   rc 0  printed the absolute directory
#   rc 1  the manifest lists no such plugin
#   rc 2  listed, but the source is not a relative path (absolute, URL,
#         github:owner/repo, or a non-string) or the directory does not exist
#
# WHY THIS EXISTS (#18)
#   Before it, find_plugin_marketplace decided "this marketplace has the plugin"
#   by testing `$root/plugins/<name>` — a guess at the aggregator layout that
#   never consulted plugins[].source. Every single-plugin marketplace
#   (che-keychain, che-apple-mail-mcp, che-ical-mcp: `"source": "./plugin"`)
#   therefore returned rc 1, and plugin-update's Step 0.1 read that as "not in
#   any registered marketplace" — a message pointing at the wrong fix. The
#   skill's own 17 hardcoded `plugins/{name}` paths then guaranteed that even a
#   hand-supplied MP_ROOT probed a directory that did not exist, and every
#   detection built on it answered "no" instead of "cannot tell" (#16's failure
#   mode, arriving by another door). Two rc values for "listed but unusable"
#   vs "not listed" exist so the consumer can say which one happened.
#
#   No python3 → the legacy `plugins/<name>` probe, so a machine without an
#   interpreter keeps the pre-#18 behaviour rather than gaining a new failure.
resolve_plugin_dir() {
  local root="${1:-}" plugin="${2:-}" src dir rc
  [ -n "$root" ] && [ -n "$plugin" ] || return 1
  src=$(_plugin_source_of "$root/.claude-plugin/marketplace.json" "$plugin"); rc=$?
  if [ "$rc" -eq 3 ]; then
    [ -d "$root/plugins/$plugin" ] || return 1
    printf '%s\n' "$root/plugins/$plugin"
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  case "$src" in
    /*|*:*|\{*|\[*|null) return 2 ;;   # absolute path, URL / github:, non-string
  esac
  dir="$root/${src#./}"
  dir="${dir%/}"
  [ -d "$dir" ] || return 2
  printf '%s\n' "$dir"
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
  # owning a plugins/ directory, and the test below requires the manifest to
  # declare the plugin AND its source directory to exist, so a tie-break loser
  # can only match when it genuinely hosts the plugin.
  #
  # An entry whose directory is missing (resolve_plugin_dir rc 2) is NOT a hit:
  # the same plugin may be complete in another checkout further down the index.
  # Step 0.1 of plugin-update re-asks resolve_plugin_dir per root when the whole
  # walk misses, so that rc 2 still surfaces in the abort message.
  #
  # here-doc, not a pipe: a pipe opens a subshell, so `return 0` would end only
  # that subshell and the function would fall through to `return 1`.
  while IFS="$(printf '\t')" read -r name root; do
    [ -n "$root" ] || continue
    if dir=$(resolve_plugin_dir "$root" "$plugin"); then
      echo "$name|$root|$dir"
      return 0
    fi
  done <<EOF
$(_marketplace_index)
EOF
  return 1
}

