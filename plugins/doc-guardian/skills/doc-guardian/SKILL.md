---
name: doc-guardian
description: Check whether a Git repository needs changelog, project-guidance, or GitHub Wiki updates by running the plugin's existing documentation guardian scripts manually. Use after commits, before finishing repository work, or when the user asks whether README.md, CLAUDE.md, changelog entries, or the wiki are out of date.
---

# Documentation Guardian

Run the existing Claude Code hook logic manually and report its findings. Codex does not receive PostToolUse or Stop hooks, so never claim these checks run automatically.

## Procedure

1. Resolve the target repository root:

   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel)
   ```

   Stop with a clear message if the current path is not inside a Git repository.

2. Resolve this loaded `SKILL.md` to an absolute path. Let its containing directory be `SKILL_DIR`; the plugin hook directory is `$SKILL_DIR/../../hooks`.

3. Run the project-guidance check that normally follows a commit:

   ```bash
   commit_result=$(printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"git commit"}}' | \
     env CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$SKILL_DIR/../../hooks/claude-md-reminder.sh")
   ```

4. Run the end-of-task changelog and wiki checks:

   ```bash
   changelog_result=$(printf '%s\n' '{"stop_hook_active":false}' | \
     env CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$SKILL_DIR/../../hooks/changelog-update.sh")
   wiki_result=$(printf '%s\n' '{"stop_hook_active":false}' | \
     env CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$SKILL_DIR/../../hooks/sync-wiki-check.sh")
   ```

5. Interpret each result:

   - Empty output means the check passed or did not apply.
   - A JSON object with `decision: "block"` is an actionable finding; report its `reason` in plain language.
   - Invalid JSON or a nonzero script exit is a check failure; report the script name and stderr instead of treating it as a pass.

6. Summarize the three checks as `pass`, `action needed`, or `check failed`.

## Safety and runtime boundary

- Do not create changelog entries or push a wiki unless the user explicitly asks for those changes.
- Do not reinterpret an empty result as proof that all documentation is globally current; the scripts inspect their defined recent-commit conditions.
- Treat the checks as manual in Codex. Automatic enforcement remains Claude Code-only.
