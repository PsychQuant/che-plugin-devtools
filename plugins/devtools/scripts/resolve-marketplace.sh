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
#   # → psychquant-claude-plugins|/Users/che/Developer/psychquant-claude-plugins
#
# WHY THIS EXISTS
#   Before v1.0.0, five places hardcoded /Users/che/Developer/psychquant-claude-plugins
#   (plugin-health / plugin-debug / plugin-upgrade / plugin-create SKILL.md, plus
#   rules/tool-readme-sync.md). That was a single-marketplace assumption baked into
#   what is inherently a multi-marketplace tool: devtools now lives in
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
#   Add the name to MARKETPLACE_NAMES *and* a case branch below. The test suite
#   asserts every listed name resolves, so adding to only one will fail CI.

set -u

# Space-delimited; order defines search precedence for find_plugin_marketplace.
MARKETPLACE_NAMES="che-plugin-devtools psychquant-claude-plugins sinica-claude-plugins che-local-plugins"

# Resolve a marketplace name to its local repo root.
# Returns 1 for unknown or empty names.
resolve_marketplace_root() {
  local name="${1:-}"
  [ -n "$name" ] || return 1

  case "$name" in
    che-plugin-devtools)       echo "$HOME/Developer/che-plugin-devtools" ;;
    psychquant-claude-plugins) echo "$HOME/Developer/psychquant-claude-plugins" ;;
    sinica-claude-plugins)     echo "$HOME/Developer/sinica-claude-plugins" ;;
    # Not a standalone repo — a subdirectory of the che-claude-config checkout.
    che-local-plugins)         echo "$HOME/Developer/che-claude-config/che-local-plugins" ;;
    *) return 1 ;;
  esac
}

# Print every known marketplace name, one per line.
list_marketplaces() {
  local mp
  for mp in $MARKETPLACE_NAMES; do
    echo "$mp"
  done
}

# Given a plugin name, find which marketplace contains it.
# Prints "<marketplace-name>|<repo-root>" and returns 0 on hit; returns 1 if the
# plugin is not found in any known marketplace.
find_plugin_marketplace() {
  local plugin="${1:-}"
  [ -n "$plugin" ] || return 1

  local mp root
  for mp in $MARKETPLACE_NAMES; do
    root=$(resolve_marketplace_root "$mp") || continue
    if [ -d "$root/plugins/$plugin" ]; then
      echo "$mp|$root"
      return 0
    fi
  done
  return 1
}
