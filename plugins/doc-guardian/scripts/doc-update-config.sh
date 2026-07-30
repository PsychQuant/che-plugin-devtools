#!/bin/bash
# doc-update-config.sh — shared config loader for doc-guardian hooks
#
# Three-tier injection (precedence high → low):
#   1. <repo>/.claude/doc-guardian.json     — per-project override
#   2. ~/.cache/doc-guardian/config.json    — per-machine override
#   3. built-in defaults                    — defined in this file
#
# Legacy fallback (doc-tools era, honored for one version):
#   <repo>/.claude/doc-tools.json  and  ~/.cache/doc-tools/config.json
#   are read FIRST, then overlaid by their doc-guardian.json equivalents.
#
# Kill switch (either path works):
#   ~/.cache/doc-guardian/disabled   or   ~/.cache/doc-tools/disabled
#
# Usage (sourced by hook scripts):
#   source "$CLAUDE_PLUGIN_ROOT/scripts/doc-update-config.sh"
#   is_doc_guardian_disabled && exit 0
#   load_doc_guardian_config "$CLAUDE_PROJECT_DIR"
#
# Exposed after load:
#   $CFG_ENABLED                 "true"/"false"   master switch (doc-update-guard)
#   $CFG_MIN_CHANGED_FILES       integer          doc-update-guard threshold
#   $CFG_CODE_EXTENSIONS_REGEX   grep regex       what counts as a code file
#   $CFG_DOC_FILES_REGEX         grep regex       what counts as a doc file
#   $CFG_SKIP_PATHS              newline globs    repos to leave alone
#   $CFG_CLAUDE_MD_ENABLED       "true"/"false"   claude-md-reminder switch
#   $CFG_CLAUDE_MD_MIN_FILES     integer          claude-md-reminder threshold
#   $CFG_ARCH_PATTERNS_REGEX     grep regex       "architectural change" signals
#   $CFG_WIKI_SYNC_ENABLED       "true"/"false"   sync-wiki-check switch
#   $CFG_CHANGELOG_DIR_REGEX     grep regex       changelog directory marker
#
# ---------------------------------------------------------------------------
# BASH 3.2 CONSTRAINT — why this file avoids namerefs
# ---------------------------------------------------------------------------
# macOS ships /bin/bash 3.2.57. The doc-tools version of this file used
# `local -n ref="$2"` to write back into caller arrays. bash 3.2 rejects that
# with `local: -n: invalid option`, and because these scripts run under
# `set -u` WITHOUT `set -e`, execution continued past the error — so:
#
#   enabled / min_changed_files / skip_paths  → worked (plain globals)
#   code_extensions / doc_files               → SILENTLY IGNORED
#
# A config file could be syntactically valid, the hook could run without
# complaint, and two of its five fields would simply never take effect.
#
# Fixed by dropping namerefs entirely: array-valued settings are held as
# space-delimited strings in plain globals, which bash 3.2 handles natively.
#
# Full design notes: ${CLAUDE_PLUGIN_ROOT}/references/doc-update-design.md

set -u

# ---------------------------------------------------------------------------
# Defaults
#
# Every value matches the pre-merge hardcoded behavior of doc-tools 0.2.0 and
# doc-guardian 1.0.2, so migrating changes nothing until a config file is
# actually written. Config-ification here is about removing the need to edit
# shell scripts — not about changing what the hooks do.
# ---------------------------------------------------------------------------

DEFAULT_ENABLED="true"
DEFAULT_MIN_CHANGED_FILES=3
DEFAULT_CODE_EXTENSIONS="R sh sql py ts tsx js jsx css swift go rs kt java c cpp h"
DEFAULT_DOC_FILES="CHANGELOG.md README.md CLAUDE.md changelog/"
DEFAULT_SKIP_PATHS=""

# claude-md-reminder.sh — verbatim from doc-guardian 1.0.2
DEFAULT_CLAUDE_MD_ENABLED="true"
DEFAULT_CLAUDE_MD_MIN_FILES=2
DEFAULT_ARCH_PATTERNS='\.env|vercel\.json|package\.json|Makefile|_targets\.R|schema\.sql|Dockerfile|\.github/workflows|\.claude/skills|\.claude/hooks|^web/(app|components|lib)/|^r_pkg/'

# sync-wiki-check.sh — verbatim from doc-guardian 1.0.2
DEFAULT_WIKI_SYNC_ENABLED="true"
DEFAULT_CHANGELOG_DIR="changelog/"

_DG_CACHE_DIR="$HOME/.cache/doc-guardian"
_DG_LEGACY_CACHE_DIR="$HOME/.cache/doc-tools"

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

is_doc_guardian_disabled() {
  [ -f "$_DG_CACHE_DIR/disabled" ] || [ -f "$_DG_LEGACY_CACHE_DIR/disabled" ]
}

# Back-compat alias for anything still calling the doc-tools name.
is_doc_tools_disabled() { is_doc_guardian_disabled; }

load_doc_guardian_config() {
  local project_dir="${1:-}"

  CFG_ENABLED="$DEFAULT_ENABLED"
  CFG_MIN_CHANGED_FILES="$DEFAULT_MIN_CHANGED_FILES"
  CFG_SKIP_PATHS="$DEFAULT_SKIP_PATHS"
  CFG_CLAUDE_MD_ENABLED="$DEFAULT_CLAUDE_MD_ENABLED"
  CFG_CLAUDE_MD_MIN_FILES="$DEFAULT_CLAUDE_MD_MIN_FILES"
  CFG_WIKI_SYNC_ENABLED="$DEFAULT_WIKI_SYNC_ENABLED"

  # Array-valued settings live as space-delimited strings (bash 3.2 safe).
  _CFG_CODE_EXTS="$DEFAULT_CODE_EXTENSIONS"
  _CFG_DOC_FILES="$DEFAULT_DOC_FILES"
  _CFG_ARCH_PATTERNS="$DEFAULT_ARCH_PATTERNS"
  _CFG_CHANGELOG_DIR="$DEFAULT_CHANGELOG_DIR"

  # Layer 2: per-machine (legacy first, current wins)
  [ -f "$_DG_LEGACY_CACHE_DIR/config.json" ] && _merge_config "$_DG_LEGACY_CACHE_DIR/config.json"
  [ -f "$_DG_CACHE_DIR/config.json" ]        && _merge_config "$_DG_CACHE_DIR/config.json"

  # Layer 1: per-project (legacy first, current wins — highest precedence)
  if [ -n "$project_dir" ]; then
    [ -f "$project_dir/.claude/doc-tools.json" ]    && _merge_config "$project_dir/.claude/doc-tools.json"
    [ -f "$project_dir/.claude/doc-guardian.json" ] && _merge_config "$project_dir/.claude/doc-guardian.json"
  fi

  CFG_CODE_EXTENSIONS_REGEX="\\.($(echo "$_CFG_CODE_EXTS" | tr ' ' '|'))$"
  CFG_DOC_FILES_REGEX="($(echo "$_CFG_DOC_FILES" | sed 's/\./\\./g' | tr ' ' '|'))"
  CFG_ARCH_PATTERNS_REGEX="$_CFG_ARCH_PATTERNS"
  CFG_CHANGELOG_DIR_REGEX="^$(echo "$_CFG_CHANGELOG_DIR" | sed 's/\./\\./g')"

  return 0
}

# Back-compat alias.
load_doc_tools_config() { load_doc_guardian_config "$@"; }

# Check whether a path matches any skip_paths glob.
is_skipped_path() {
  local pwd_abs="${1:-$PWD}"
  [ -n "$CFG_SKIP_PATHS" ] || return 1

  local pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    pattern="${pattern/#\~/$HOME}"
    # shellcheck disable=SC2254
    case "$pwd_abs" in $pattern) return 0 ;; esac
  done <<< "$CFG_SKIP_PATHS"
  return 1
}

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

# Overlay one JSON config file onto the current globals. No namerefs.
# Uses `has()` / `!= null` rather than `// empty` so a literal `false` is not
# swallowed as absent.
_merge_config() {
  local cfg_file="$1"
  command -v jq >/dev/null 2>&1 || return 0   # no jq → defaults stand

  local v

  v=$(jq -r 'if has("enabled") then .enabled else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && CFG_ENABLED="$v"

  v=$(jq -r 'if has("min_changed_files") then .min_changed_files else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && CFG_MIN_CHANGED_FILES="$v"

  v=$(jq -r 'if .code_extensions then (.code_extensions | join(" ")) else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && _CFG_CODE_EXTS="$v"

  v=$(jq -r 'if .doc_files then (.doc_files | join(" ")) else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && _CFG_DOC_FILES="$v"

  v=$(jq -r 'if .skip_paths then (.skip_paths | join("\n")) else empty end' "$cfg_file" 2>/dev/null)
  if [ -n "$v" ]; then
    if [ -z "$CFG_SKIP_PATHS" ]; then CFG_SKIP_PATHS="$v"; else CFG_SKIP_PATHS="$CFG_SKIP_PATHS"$'\n'"$v"; fi
  fi

  # claude_md.*
  v=$(jq -r 'if .claude_md.enabled != null then .claude_md.enabled else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && CFG_CLAUDE_MD_ENABLED="$v"

  v=$(jq -r 'if .claude_md.min_files != null then .claude_md.min_files else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && CFG_CLAUDE_MD_MIN_FILES="$v"

  v=$(jq -r 'if .claude_md.arch_patterns then (.claude_md.arch_patterns | join("|")) else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && _CFG_ARCH_PATTERNS="$v"

  # wiki_sync.*
  v=$(jq -r 'if .wiki_sync.enabled != null then .wiki_sync.enabled else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && CFG_WIKI_SYNC_ENABLED="$v"

  v=$(jq -r 'if .wiki_sync.changelog_dir != null then .wiki_sync.changelog_dir else empty end' "$cfg_file" 2>/dev/null)
  [ -n "$v" ] && _CFG_CHANGELOG_DIR="$v"

  return 0
}
