#!/bin/bash
# audit-descriptions.sh — measure skill description health across this repo.
#
# Usage:
#   audit-descriptions.sh [--repo <dir>] [--skills-root <dir>] [--format table|tsv]
#
#   --repo <dir>         scan every skills/ dir in the repo (plugins/*/skills/*
#                        and .claude/skills/*). Default: repo root inferred from
#                        this script's location.
#   --skills-root <dir>  scan exactly one directory whose children are skills.
#                        Overrides --repo. Used by the test fixtures.
#   --format table|tsv   table (default, human) or tsv (machine / tests).
#
# Exit codes:
#   0  every skill passes
#   1  at least one actionable finding (undersized / over-cap / no-description
#      / oversized body)
#   2  the requested root does not exist
#
# WHY THESE THRESHOLDS
#   Per plugins/devtools/rules/skill-description-budget.md, `description` is the
#   ONLY trigger surface — SKILL.md body loads only AFTER the skill triggers. A
#   description that fits in one clause has no room for the "when to use it"
#   phrasing the model matches against, so the skill effectively becomes
#   name-only-by-authorship: technically present in the listing, practically
#   unfindable unless the user already knows the name.
#
#   DESC_FLOOR=100    below this there is no room for a trigger clause at all.
#                     Empirically: this repo's healthy groups sit at 166
#                     (plugin-*) and 449 (doc-guardian) median; the unhealthy
#                     ones at 45 (mcp-*) and 80 (cli-*).
#   DESC_CAP=1536     Claude Code's per-entry truncation limit. Past this the
#                     tail is silently cut — the opposite failure, and the one
#                     the rule's "blood lesson" section documents.
#   BODY_CEILING=500  body is loaded whole on trigger; past ~500 lines the skill
#                     should push detail into references/ (progressive
#                     disclosure) instead of paying the full cost every time.
#
#   The floor is deliberately NOT a target. 100 is where "unusable" ends, not
#   where "good" begins. Aim for the 150–700 band the healthy groups occupy.

set -u

DESC_FLOOR=100
DESC_CAP=1536
BODY_CEILING=500

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." 2>/dev/null && pwd || echo "")"
SKILLS_ROOT=""
FORMAT="table"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO_ROOT="$2"; shift 2 ;;
    --skills-root) SKILLS_ROOT="$2"; shift 2 ;;
    --format)      FORMAT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Collect the skill directories to inspect.
COLLECT=()
if [ -n "$SKILLS_ROOT" ]; then
  [ -d "$SKILLS_ROOT" ] || { echo "✗ skills root does not exist: $SKILLS_ROOT" >&2; exit 2; }
  COLLECT+=("$SKILLS_ROOT")
else
  [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ] || { echo "✗ repo root does not exist: $REPO_ROOT" >&2; exit 2; }
  for d in "$REPO_ROOT"/plugins/*/skills "$REPO_ROOT"/.claude/skills; do
    [ -d "$d" ] && COLLECT+=("$d")
  done
  [ ${#COLLECT[@]} -eq 0 ] && { echo "✗ no skills/ directories found under $REPO_ROOT" >&2; exit 2; }
fi

# Emit one TSV row per skill: name, desc_len, body_lines, verdict, oversized_body, group
ROWS=$(
  for root in "${COLLECT[@]}"; do
    group=$(basename "$(dirname "$root")")   # plugin name, or ".claude" for project skills
    [ "$group" = "$(basename "$REPO_ROOT")" ] && group="(repo)"
    for skill in "$root"/*; do
      [ -d "$skill" ] || continue
      [ -f "$skill/SKILL.md" ] || continue
      python3 - "$skill/SKILL.md" "$(basename "$skill")" "$group" \
              "$DESC_FLOOR" "$DESC_CAP" "$BODY_CEILING" <<'PY'
import re, sys
path, name, group, floor, cap, ceiling = sys.argv[1:7]
floor, cap, ceiling = int(floor), int(cap), int(ceiling)
text = open(path, encoding="utf-8", errors="replace").read()
lines = text.count("\n") + (0 if text.endswith("\n") else 1)

m = re.match(r"^---\n(.*?)\n---", text, re.S)
if not m:
    desc = None
else:
    fm = m.group(1)
    d = re.search(r"^description:\s*(.*?)(?=\n[A-Za-z_-]+:|\Z)", fm, re.S | re.M)
    desc = d.group(1).strip() if d else None
    if desc is not None:
        # Block scalars (`description: |`) leave the marker on line 1; drop it so
        # the count reflects actual prose, not YAML syntax.
        desc = re.sub(r"^[|>][-+]?\s*\n?", "", desc).strip()

if desc is None or desc == "":
    verdict, n = "no-description", 0
else:
    n = len(desc)
    if n > cap:      verdict = "over-cap"
    elif n < floor:  verdict = "undersized"
    else:            verdict = "ok"

oversized = "yes" if lines > ceiling else "no"
print("\t".join([name, str(n), str(lines), verdict, oversized, group]))
PY
    done
  done | sort -t"$(printf '\t')" -k2,2n
)

if [ "$FORMAT" = "tsv" ]; then
  printf 'name\tdesc_chars\tbody_lines\tverdict\toversized_body\tgroup\n'
  [ -n "$ROWS" ] && printf '%s\n' "$ROWS"
else
  printf '%-26s %11s %11s %-15s %-9s %s\n' name description body_lines verdict body_over group
  printf '%-26s %11s %11s %-15s %-9s %s\n' "$(printf '%.0s-' {1..26})" ----------- ----------- --------------- --------- -----
  if [ -n "$ROWS" ]; then
    printf '%s\n' "$ROWS" | while IFS=$'\t' read -r n d b v o g; do
      mark=" "
      [ "$v" != "ok" ] && mark="!"
      [ "$o" = "yes" ] && mark="${mark}B"
      printf '%-26s %11s %11s %-15s %-9s %s %s\n' "$n" "$d" "$b" "$v" "$o" "$g" "$mark"
    done
  fi
fi

# Summary + exit code
TOTAL=$( [ -n "$ROWS" ] && printf '%s\n' "$ROWS" | wc -l | tr -d ' ' || echo 0 )
BAD_DESC=$( [ -n "$ROWS" ] && printf '%s\n' "$ROWS" | awk -F'\t' '$4 != "ok"' | wc -l | tr -d ' ' || echo 0 )
BAD_BODY=$( [ -n "$ROWS" ] && printf '%s\n' "$ROWS" | awk -F'\t' '$5 == "yes"' | wc -l | tr -d ' ' || echo 0 )

if [ "$FORMAT" != "tsv" ]; then
  echo
  echo "SUMMARY: $TOTAL skills — $BAD_DESC with description findings, $BAD_BODY with oversized body (> $BODY_CEILING lines)"
  echo "  thresholds: floor=$DESC_FLOOR cap=$DESC_CAP body_ceiling=$BODY_CEILING"
  echo "  floor is where 'unusable' ends, not where 'good' begins — aim for the 150–700 band"
fi

[ "$BAD_DESC" -gt 0 ] || [ "$BAD_BODY" -gt 0 ] && exit 1
exit 0
