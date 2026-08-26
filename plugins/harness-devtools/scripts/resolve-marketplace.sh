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
#   Add the name to MARKETPLACE_NAMES *and* a case branch below. The test suite
#   asserts every listed name resolves, so adding to only one will fail CI.

set -u

# Newline-delimited; order defines search precedence for find_plugin_marketplace.
#
# **換行分隔 + `while read`，不是空白分隔 + `for mp in $VAR`**（#16）。
# 後者依賴 unquoted 變數的 word-split，而 **zsh 預設不做那件事**——這個檔案是被
# `source` 的，所以跑它的是呼叫端的 shell，`#!/bin/bash` 那行不生效。
#
# 實測：`zsh -c 'source ...; find_plugin_marketplace harness-devtools'` 回 rc=1，
# 同一句在 bash 下回 0 並印出正確的 marketplace。**Claude Code 的 Bash 工具跑在
# zsh**，所以照 skill 教的做（source 之後呼叫）在 session 裡對**每一個** plugin
# 都解析不到，而呼叫端多半不檢查回傳碼——失敗於是變成一個空字串。
#
# 檔頭那句「test suite asserts a clean stderr under /bin/bash」正是它活下來的原因：
# 測試只跑 bash。現在測試兩個 shell 都跑。
MARKETPLACE_NAMES='che-plugin-devtools
psychquant-claude-plugins
sinica-claude-plugins
che-local-plugins'

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
  printf '%s\n' "$MARKETPLACE_NAMES"
}

# Given a plugin name, find which marketplace contains it.
# Prints "<marketplace-name>|<repo-root>" and returns 0 on hit; returns 1 if the
# plugin is not found in any known marketplace.
find_plugin_marketplace() {
  local plugin="${1:-}"
  [ -n "$plugin" ] || return 1

  local mp root
  # here-doc（不是 pipe）：pipe 會開 subshell，`return 0` 就只結束那個 subshell、
  # 函式照樣走到最後的 `return 1`。here-doc 的 while 跑在當前 shell。
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    root=$(resolve_marketplace_root "$mp") || continue
    if [ -d "$root/plugins/$plugin" ]; then
      echo "$mp|$root"
      return 0
    fi
  done <<EOF
$MARKETPLACE_NAMES
EOF
  return 1
}
