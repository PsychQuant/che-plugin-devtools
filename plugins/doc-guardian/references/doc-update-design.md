# Doc-Update Guard Hook — Design Rationale

Single source of truth for **why** the `doc-update-guard.sh` Stop hook is designed the way it is. Distilled from:

- The original `~/.claude/hooks/changelog-update.sh` docstring (terse, captures explicit decisions)
- `~/.claude/hooks/README.md` (lists the hook but with no per-hook design notes — only newer hooks have those)
- `~/.claude/history.jsonl` (early prompts that originated the design)
- Cross-reference to `pending-tasks-nudge.py` README (its "Rejected alternatives" table illuminates which trade-offs were explicitly considered)

This document captures **both** the decisions originally written down AND the implicit ones that were never previously documented (3-file threshold, code-extension list, 4-doc-files acceptance set, Stop+block trade-off vs warn-only).

---

## What the hook does

On `Stop` event (Claude turn end), look at the most recent commit:

1. If `stop_hook_active=true` → exit 0 (infinite-loop bypass)
2. If kill-switch flag exists → exit 0
3. If config-disabled → exit 0
4. If skip-path matches → exit 0
5. If not in a git repo → exit 0
6. If HEAD commit empty → exit 0
7. Count "code files" changed: matches against `code_extensions` regex
8. If count `< min_changed_files` → exit 0 (not significant)
9. If any of `doc_files` was updated in the same commit → exit 0 (lenient pass)
10. **Otherwise**: emit `decision: "block"` JSON listing what's missing

---

## Decision: per-commit, not per-day

> **From original docstring**: "compact 後 Claude 會忘記先前改了什麼，每筆 commit 都應該獨立檢查。"

Translation: after Claude Code's automatic conversation compaction, the assistant's working memory is partially erased. A "today aggregate" check would silently false-pass because Claude can no longer recall what it changed pre-compact.

Anchoring the check on `HEAD` commit (a stable git artifact, not session memory) is **compaction-resilient**. The trade-off: a series of small commits (1-2 files each) bypasses the check even if they cumulatively cross the threshold. Accepted as cost of compact-resilience.

---

## Decision: Stop event + `decision: "block"`

This is the most contested design choice in the hook system. The newer `pending-tasks-nudge.py` (April 2026) explicitly **rejected** this combination in its "Rejected alternatives" table:

> | Alternative | Why not |
> |-------------|---------|
> | `Stop` hook + `decision: "block"` | Hard-blocks the end-of-turn, which interrupts normal flow; also causes infinite loops if Claude can't determine which task to mark. |

Yet the doc-update guard **uses** Stop+block. Why the discrepancy?

| Factor | Doc-update guard | pending-tasks-nudge |
|--------|-----------------|---------------------|
| Required action | **Specific** — update README/CLAUDE.md/CHANGELOG.md | **Ambiguous** — which task to mark? |
| Resolvability | **Always resolvable** — Claude knows what to write | **Sometimes unresolvable** — no clear "done" task |
| Infinite-loop risk | **Low** — `stop_hook_active=true` bypass + after one update Claude can move on | **High** — Claude could fight hook indefinitely |
| Severity of skip | **High** — undocumented changes accumulate as tech debt | **Medium** — task drift is annoying but recoverable |

→ Stop+block is appropriate **when the required action is specific and resolvable**. Doc updates fit; task triage doesn't.

---

## Decision: ≥3 code files threshold

Heuristic for "significant change":

- 1 file: hot-fix, typo, single-method tweak — usually no doc impact
- 2 files: refactor a function + its caller — borderline
- 3 files: cross-cutting change (function + callers + tests, or new feature spread across modules) — likely needs doc reflection

Not derived from data; chosen as a safe-default that errs on the side of **not annoying**. User can lower to `1` (paranoid mode) or raise to `5` (noisy-mode-resistant) via config.

Override: `min_changed_files` in `~/.cache/doc-tools/config.json` or `<repo>/.claude/doc-tools.json`.

---

## Decision: code extension allowlist

The default set:

```
R sh sql py ts tsx js jsx css swift go rs kt java c cpp h
```

Source: user's primary working languages — R (stats), shell (scripting), SQL (analytics), Python (ML/automation), TypeScript/React (frontend), CSS, Swift (macOS/iOS), Go/Rust/Kotlin/Java/C/C++ (systems work).

**Excluded by design**:
- `.md` — markdown files. Doc files. The whole point of the hook is to require updating these; counting them as "code change" would create perverse incentives.
- `.json` / `.yaml` / `.toml` — config files. Most config tweaks (version bumps, dep updates) don't need doc reflection.
- `.txt` — usually unstructured notes, not code.

Override: `code_extensions` array in config. Caller intent on this field is **full replace**, not append (appending creates accidental superset; explicit override safer).

---

## Decision: 4-doc-files acceptance set (lenient pass)

Any **one** of these counts as "doc updated":

- `CHANGELOG.md` — release notes (matches a single file)
- `README.md` — user-facing overview (matches a single file)
- `CLAUDE.md` — Claude-facing context (matches a single file)
- `changelog/` — directory of dated change files (e.g. `docs/changelog/20260502_foo.md`); matches anything containing the substring

> **From original prompt** (`~/.claude/history.jsonl`): "我想要有一個 changelog 資料夾，幫我在 .claude 的 hook 裡面建立**只要大改動就要修正 README.md 跟 CLAUDE.md**"

Translation: the original ask was about README/CLAUDE.md, not just CHANGELOG. The 4-file acceptance set respects multiple repo conventions:

- Some projects use `CHANGELOG.md`
- Some use `docs/changelog/YYYYMMDD_*.md` directory
- README.md updates suffice for user-facing changes
- CLAUDE.md updates suffice for AI-facing changes

Lenient = don't dictate which convention; let the user/repo decide what counts as "doc reflection".

Override: `doc_files` array in config (full replace).

---

## Decision: `stop_hook_active=true` bypass

When Claude triggers a tool call in response to the hook's block message, Claude Code re-fires the Stop hook with `stop_hook_active=true`. Without bypass, the hook would block again → Claude would respond again → infinite loop.

This is **mandatory plumbing**, not a design choice. Documented in Anthropic's hook reference.

---

## Three-tier config injection

Precedence high → low:

```
1. <repo>/.claude/doc-tools.json    ← per-project (highest)
2. ~/.cache/doc-tools/config.json   ← per-machine
3. built-in defaults                ← in scripts/doc-update-config.sh
```

Plus kill-switch:

```
~/.cache/doc-tools/disabled         ← touch this file → hook short-circuits exit 0
```

### Why this layering

- **Per-machine**: ergonomic for "I'm tired of seeing this on side-projects" without modifying every repo
- **Per-project**: required for legitimate cases — research scratchpads (no docs needed), generated-code repos (auto-generated, doc would lie), monorepo subprojects with different conventions
- **Kill-switch**: emergency exit. Mirror of `archive-first` plugin's `~/.cache/archive-first/disabled` pattern. One `touch` to silence.

### Config schema

All four keys optional; missing keys fall through to defaults.

```json
{
  "enabled": true,
  "min_changed_files": 3,
  "code_extensions": ["py", "ts", "swift"],
  "doc_files": ["CHANGELOG.md", "README.md"],
  "skip_paths": ["~/Developer/scratch/**", "/tmp/**"]
}
```

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `enabled` | bool | `true` | Master switch (per-machine / per-project disable without touching kill-switch flag) |
| `min_changed_files` | int | `3` | Trigger threshold |
| `code_extensions` | string[] | (allowlist above) | Files counted as "code change" |
| `doc_files` | string[] | (4-set above) | Files counted as "doc updated" |
| `skip_paths` | string[] | `[]` | Glob patterns; current working directory matched against each — match → exit 0 |

`code_extensions` and `doc_files` use **full replace**, not merge. Provide the complete list you want.

`skip_paths` is **append across layers** (per-machine + per-project both contribute to the skip set).

---

## Rejected alternatives (worth re-stating)

| Alternative | Why not |
|-------------|---------|
| `PostToolUse` + warn-only (no block) | Doc updates need enforcement; warning is too easy to ignore. Different severity than task-tracking. |
| `UserPromptSubmit` hook | Fires on next user message — too late; user has moved on mentally. |
| File-watcher daemon | Out-of-band complexity; loses the per-commit anchoring (which is the compact-resilience trick). |
| Strict 1-file threshold | Too noisy on hot-fixes / typos. |
| Require all 4 doc files updated | Too strict; respects no repo convention. |
| Hardcode threshold / extensions in script | No per-project flexibility. Three-tier injection added in v0.2.0. |

---

## How the hook compares to other PsychQuant hooks

| Hook | Plugin | Event | Action | Pattern matched |
|------|--------|-------|--------|----------------|
| `doc-update-guard.sh` | `doc-tools` | Stop | block | This hook |
| `claude-md-reminder.sh` | (still in `~/.claude/hooks/`) | PostToolUse(Bash) | warn | Project state drift hint |
| `pending-tasks-nudge.py` | (still in `~/.claude/hooks/`) | PostToolUse(state-changing) | warn | Pending TaskCreate count |
| `archive-first` block hooks | `archive-first` | PreToolUse(Bash/Write/Edit) | deny | Destructive ops on `archived/` |

Future migration candidate: `claude-md-reminder.sh` is logically a doc-tools hook (warns about CLAUDE.md drift). Phase 2 may absorb it.

---

## Verification

```bash
# Mock: HEAD has 4 .py changes, no doc
git init /tmp/dt-test && cd /tmp/dt-test
for i in 1 2 3 4; do echo "x" > $i.py; done
git add -A && git commit -m test --no-verify
echo '{"stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR=/tmp/dt-test bash ~/.claude/plugins/<...>/doc-tools/hooks/doc-update-guard.sh
# Expect: JSON with decision=block, count=4
```

---

## Versioning

- v0.2.0 (initial): hook absorbed from `~/.claude/hooks/changelog-update.sh` + 3-tier config injection added + this design doc written.
- Earlier history (pre-plugin): see `~/.claude/hooks/changelog-update.sh` git history (in `che-claude-config` repo) for the user-level evolution.
