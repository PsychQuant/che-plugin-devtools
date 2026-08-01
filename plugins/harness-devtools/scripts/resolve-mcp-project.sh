#!/bin/bash
# resolve-mcp-project.sh — single source of truth for MCP project source paths.
#
# Usage (sourced by skills / hooks / scripts):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-mcp-project.sh"
#
#   resolve_mcp_project che-ical-mcp
#   # → /Users/che/Developer/che-mcps/che-ical-mcp
#
#   list_mcp_roots
#   # → one umbrella root per line, in search order
#
#   list_mcp_projects
#   # → every resolvable project name, one per line
#
# WHY THIS EXISTS
#   Eleven places across six mcp-* skills hardcoded
#   ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/<name> — a path that
#   no longer exists at all. Every `cd` to it silently fell through to the caller's
#   cwd (`cd X 2>/dev/null && ...` fails closed, but `cd X` alone does not), so the
#   skills would inspect whatever directory happened to be current and report on
#   the wrong project.
#
#   This is the same class of bug resolve-marketplace.sh was written for, and the
#   same shape of fix: one resolver, many call sites.
#
# WHY MULTIPLE ROOTS RATHER THAN ONE
#   The projects genuinely live under three umbrellas, and consolidating them is a
#   separate decision this script deliberately does not force:
#
#     ~/Developer/che-mcps/      21 projects — the main umbrella
#     ~/Developer/che-msg/        2 projects — the telegram family, own umbrella
#     ~/Developer/                1 project  — iss-compute-mcp, standalone
#
#   Note that psychquant-claude-plugins/plugins/che-telegram-mcp is NOT a source
#   project — it is the plugin wrapper that downloads the released binary. Issue #2
#   assumed otherwise; `find -name Package.swift` under it returns zero.
#
# BASH 3.2 CONSTRAINT
#   macOS ships /bin/bash 3.2.57 — no namerefs, no associative arrays. Both fail
#   with a stderr line only, and since these scripts run `set -u` without `set -e`,
#   execution CONTINUES with the assignment skipped. Keep this file 3.2-clean; the
#   test suite asserts clean stderr under /bin/bash.
#
# ADDING AN UMBRELLA
#   Add it to MCP_ROOTS. Order defines search precedence (first match wins).

set -u

# Space-delimited `<home-relative-path>:<mode>`, searched in order.
# $HOME is expanded at use site, not here, so the value stays inspectable and
# testable via an overridden HOME.
#
#   any         a dedicated MCP umbrella — every Swift package under it counts
#               (including shared libraries like biblatex-apa-swift)
#   mcp-suffix  a general-purpose directory — only names ending in -mcp count
#
# The distinction is not cosmetic: ~/Developer holds 22 Swift packages that have
# nothing to do with MCP (macdoc, rush, safari-browser, …). Treating it as `any`
# made list_mcp_projects report 42 projects instead of 24, which would have made
# require_mcp_project's "可用的專案" list actively misleading.
#
# ORDER MATTERS — che-msg BEFORE che-mcps (#11)
#   che-telegram-all-mcp / che-telegram-bot-mcp exist under both. They are not
#   copies of one project: che-msg/ holds them as a monorepo (no per-directory
#   .git, remote PsychQuant/che-msg, last touched 2026-06), while che-mcps/ holds
#   pre-migration standalone clones (own .git, remote kiki830621/*, stopped at
#   2026-02, still on the old file layout before the TelegramAllLib refactor).
#
#   The original order put che-mcps first, so the resolver deterministically
#   pointed six mcp-* skills at four-month-stale source. Determinism is not
#   correctness — the earlier claim "行為確定且有測試 pin 住，所以工具層安全"
#   confused the two. The test pinned "first root wins", never "the winner is
#   the right one".
MCP_ROOTS_SPEC="Developer/che-msg:any Developer/che-mcps:any Developer:mcp-suffix"

# A directory counts as a project only if it carries package metadata for SOME
# language. Two reasons this is not just `Package.swift`:
#   - archived/ and other bookkeeping directories must not resolve as projects
#   - not every MCP here is Swift; iss-compute-mcp is Python (requirements.txt,
#     no pyproject.toml), and a Swift-only gate silently excluded it
# Resolving a project is not the same as claiming every mcp-* skill applies to
# it — the skills that run `swift build` will say so themselves. Better to find
# the project and fail loudly than to report "not found" for something present.
_is_mcp_project() {
  [ -f "$1/Package.swift" ] \
    || [ -f "$1/pyproject.toml" ] || [ -f "$1/requirements.txt" ] \
    || [ -f "$1/package.json" ]   || [ -f "$1/Cargo.toml" ]
}

# Does <name> qualify under <mode>?
_name_ok_for_mode() {
  local name="$1" mode="$2"
  case "$mode" in
    any)        return 0 ;;
    mcp-suffix) case "$name" in *-mcp) return 0 ;; *) return 1 ;; esac ;;
    *)          return 1 ;;
  esac
}

list_mcp_roots() {
  local spec rel
  for spec in $MCP_ROOTS_SPEC; do
    rel="${spec%:*}"
    [ -d "$HOME/$rel" ] && echo "$HOME/$rel"
  done
  return 0
}

# resolve_mcp_project <name> → absolute path on stdout, or exit 1 with no output.
# All roots holding a project of this name, in precedence order, one per line.
# Exposed so callers (and tests) can see shadowing rather than infer it.
mcp_project_candidates() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local spec rel mode root
  for spec in $MCP_ROOTS_SPEC; do
    rel="${spec%:*}"; mode="${spec##*:}"
    root="$HOME/$rel"
    [ -d "$root" ] || continue
    _name_ok_for_mode "$name" "$mode" || continue
    _is_mcp_project "$root/$name" && echo "$root/$name"
  done
  return 0
}

resolve_mcp_project() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local all first
  all=$(mcp_project_candidates "$name")
  [ -n "$all" ] || return 1
  first=$(printf '%s\n' "$all" | head -1)

  # Shadowing must be VISIBLE. A silently-picked winner among several同名 copies
  # is exactly the failure this whole issue was about: the resolver deterministically
  # returned four-month-stale source and nothing said so. stdout stays the single
  # path (callers `cd "$(resolve_mcp_project x)"`); the warning goes to stderr.
  if [ "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" -gt 1 ]; then
    {
      echo "⚠ MCP 專案 '$name' 同時存在於多個 umbrella，取第一個（precedence 依 MCP_ROOTS_SPEC）："
      printf '%s\n' "$all" | sed '1s/^/    → /; 2,$s/^/      /'
      echo "  若取到的不是你要的那份，改 MCP_ROOTS_SPEC 順序，或清掉過時的副本。"
    } >&2
  fi

  echo "$first"
  return 0
}

# Every resolvable project, deduplicated by name (first root wins, matching
# resolve_mcp_project's precedence).
list_mcp_projects() {
  local spec rel mode root d name
  local seen=""
  for spec in $MCP_ROOTS_SPEC; do
    rel="${spec%:*}"; mode="${spec##*:}"
    root="$HOME/$rel"
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      _name_ok_for_mode "$name" "$mode" || continue
      _is_mcp_project "$root/$name" || continue
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen $name"
      echo "$name"
    done
  done
  return 0
}

# Convenience for skills: resolve, or print a usable error and return non-zero.
# Callers should `cd "$(require_mcp_project "$1")" || return 1` rather than the
# old bare `cd <hardcoded path>/$1`, which silently left them in the caller's cwd.
require_mcp_project() {
  local name="${1:-}"
  local path
  if path=$(resolve_mcp_project "$name"); then
    echo "$path"
    return 0
  fi
  {
    echo "✗ 找不到 MCP 專案：${name:-<empty>}"
    echo "  已搜尋："
    list_mcp_roots | sed 's/^/    /'
    echo "  可用的專案："
    list_mcp_projects | sed 's/^/    /' | head -30
  } >&2
  return 1
}
