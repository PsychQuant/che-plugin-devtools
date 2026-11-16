#!/bin/bash
# Smoke tests for the tag fences of mcp-deploy (Phase 3 Step 3a), cli-deploy
# (Phase 3 Step 1 staging + Step 1.5) and plugin-deploy (Step 7.5) (#42).
#
# Run: bash scripts/test-deploy-tag-fences.sh
#
# Round 1 of #42's verify found the HIGH defects of these fences (tag name not
# bound to the release; ${CLAUDE_PLUGIN_ROOT:?} ending the fence before it did
# anything), round 2 found more (tagging a feature branch; staging only
# Version.swift), and both rounds were fixed by hand-run trials only. Each fence
# below is pulled out of its SKILL.md and run against a fixture repo with a bare
# remote and a `gh` stub, under bash, zsh and /bin/bash (3.2 on macOS) — the
# assertion is on the fence's own decision line and on what the remote holds,
# not on "it did not crash".
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /' | head -20; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing [$3])" "$2"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (found [$3])" "$2"; else ok "$1"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi; }

SHELLS="bash zsh"
[ -x /bin/bash ] && [ "$(/bin/bash -c 'echo $BASH_VERSION')" != "$(bash -c 'echo $BASH_VERSION')" ] && SHELLS="$SHELLS /bin/bash"
command -v zsh >/dev/null 2>&1 || SHELLS=$(printf '%s' "$SHELLS" | sed 's/zsh//')

# fence <skill> <marker> <out> ['old ==> new' ...] — the one ```bash block containing <marker>,
# with literal placeholder substitutions applied
fence() {
  python3 -I - "$PLUGIN_ROOT/skills/$1/SKILL.md" "$2" "${@:4}" > "$3" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
blocks = [b for b in re.findall(r"```bash\n(.*?)```", s, re.S) if sys.argv[2] in b]
if len(blocks) != 1:
    sys.exit(f"{len(blocks)} bash blocks contain {sys.argv[2]!r}")
b = blocks[0]
for pair in sys.argv[3:]:
    old, new = pair.split(" ==> ", 1)
    if old not in b:
        sys.exit(f"placeholder {old!r} not in the block")
    b = b.replace(old, new)
sys.stdout.write(b)
PY
}
# run <shell> <dir> <script> — OUT gets stdout+stderr, RC the exit status
run() {
  local sh=$1 dir=$2 f=$3
  case "$sh" in
    zsh) OUT=$(cd "$dir" && PATH="$T/bin:$PATH" zsh -f -c "$(cat "$f")" 2>&1); RC=$? ;;
    *)   OUT=$(cd "$dir" && PATH="$T/bin:$PATH" "$sh" "$f" 2>&1); RC=$? ;;
  esac
}
# gh stub: `gh api repos/o/r/git/ref/tags/<tag> --jq .object.sha`, answered with the tag
# object id from the bare repo in GH_STUB_REMOTE — "the GitHub repo o/r" — and
# `gh api repos/<name> --jq .full_name` (#53), answered the way GitHub does: o/r is the
# repository's name (any case), GH_STUB_OLD_NAME is a former name that redirects to it, any
# other name does not exist: like the real gh (2.96.0) the stub then prints the body of the
# 404 on stdout, one line of JSON without a newline, and exits 1 - so it is the block's strict
# pattern that has to keep that text out of OWNER_REPO. GH_STUB_NO_NAME=1 makes the lookup
# fail with nothing on stdout (gh not logged in: exit 4). GH_STUB_MULTILINE=1 answers with
# three lines, the first of which is a clean name (not something GitHub sends; the blocks
# must refuse it, because the answer is used as a command argument later).
# gh_full_name is shared with the recording stub further down.
mkdir -p "$T/bin"
cat > "$T/bin/gh-full-name" <<'SH'
#!/bin/sh
# usage: gh-full-name <owner/repo>
[ -z "${GH_STUB_NO_NAME:-}" ] || exit 4
[ -z "${GH_STUB_MULTILINE:-}" ] || { printf '%s\n' o/r --hostname attacker.example; exit 0; }
not_found() { printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/repos#get-a-repository","status":"404"}'; exit 1; }
case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
  o/r) echo o/r ;;
  "$(printf '%s' "${GH_STUB_OLD_NAME:-}" | tr 'A-Z' 'a-z')") [ -n "${GH_STUB_OLD_NAME:-}" ] && echo o/r || not_found ;;
  *) not_found ;;
esac
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/sh
[ "$1" = api ] || exit 1
case "$2" in
  repos/o/r/git/ref/tags/*) git --git-dir="$GH_STUB_REMOTE" rev-parse -q --verify "refs/tags/${2#repos/o/r/git/ref/tags/}" || exit 1 ;;
  repos/*/*/*) exit 1 ;;
  repos/*/*) [ "$3 $4" = "--jq .full_name" ] || exit 1; exec "$(dirname "$0")/gh-full-name" "${2#repos/}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh" "$T/bin/gh-full-name"

# mk <name> [url] — work repo $T/<name> on main, pushed with upstream to bare $T/<name>.git,
# whose remote URL is <url> (default https://github.com/o/r.git) rewritten to the bare path
mk() {
  local url=${2:-https://github.com/o/r.git}
  git init -q --bare -b main "$T/$1.git"
  git init -q -b main "$T/$1"
  git -C "$T/$1" config "url.$T/$1.git.insteadOf" "$url"
  git -C "$T/$1" remote add origin "$url"
  export GH_STUB_REMOTE="$T/$1.git"
}
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
ci() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-c}"; }
push() { git -C "$1" push -q -u origin "$(git -C "$1" branch --show-current)" 2>/dev/null; }
rtag() { git --git-dir="$1" rev-parse -q --verify "refs/tags/$2^{commit}" 2>/dev/null; }
# msgfile <work> <text> — the commit message file the deploy skills read (#50)
msgfile() { local d; d="$(git -C "$1" rev-parse --absolute-git-dir)/harness-deploy"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/commit-message.txt"; }

echo "SKILL text (#42)"
for s in mcp-deploy cli-deploy plugin-deploy; do
  for m in "Step 3a: VERSION" "Step 1.5: VERSION" "Step 7.5: PLUGIN_NAME"; do
    python3 -I -c 'import re,sys; s=open(sys.argv[1]).read(); sys.exit(0 if any(sys.argv[2] in b for b in re.findall(r"```bash\n(.*?)```", s, re.S)) else 1)' \
      "$PLUGIN_ROOT/skills/$s/SKILL.md" "$m" || continue
    fence "$s" "$m" "$T/text.sh"
    hasnt "$s: the tag fence does not use \${CLAUDE_PLUGIN_ROOT:?} (empty in the Bash tool, #39)" "$(cat "$T/text.sh")" 'CLAUDE_PLUGIN_ROOT:?'
  done
done
# lookup_order <SKILL.md> — prints the number of bash blocks that mention OWNER_REPO and, after a
# space, what is wrong with any of them (#53; the rules are spelled out where it is called).
# A function with its own here-document, not a here-document inside $( ): bash 3.2 reads those differently.
lookup_order() {
  python3 -I - "$1" <<'PY'
import re, sys
LOOKUP = 'CANON=$(gh api "repos/$OWNER_REPO" --jq .full_name 2>/dev/null)'
USE = re.compile(r'repos/\$\{?OWNER_REPO\}?/|(?:--repo|-R)[ =]"?\$\{?OWNER_REPO|gh repo [a-z]+ "?\$\{?OWNER_REPO')
blocks = re.findall(r"```bash\n(.*?)```", open(sys.argv[1], encoding="utf-8").read(), re.S)
n, bad = 0, []
for b in blocks:
    if "OWNER_REPO" not in b:
        continue
    n += 1
    lines = b.split("\n")
    d = next((i for i, l in enumerate(lines) if l.startswith("OWNER_REPO=") and l != "OWNER_REPO=$CANON"), None)
    q = next((i for i, l in enumerate(lines) if l == LOOKUP), None)
    a = next((i for i, l in enumerate(lines) if l == "OWNER_REPO=$CANON"), None)
    uses = [i for i, l in enumerate(lines) if USE.search(l) and l != LOOKUP]
    push = next((i for i, l in enumerate(lines) if l.startswith("git push ")), None)
    why = None
    if d is None: why = "uses OWNER_REPO without deriving it"
    elif q is None or q < d: why = "no lookup after the derivation"
    elif not ("wc -l" in lines[q + 1] and "grep -qxE" in lines[q + 1] and "exit 1" in lines[q + 2]):
        why = "the lookup is not followed by the one-line and strict-pattern check that stops"
    elif not (q + 4 < len(lines) and "${CANON%%/*}" in lines[q + 3] and "${OWNER_REPO%%/*}" in lines[q + 3]
              and "tr 'A-Z' 'a-z'" in lines[q + 3] and "exit 1" in lines[q + 4]):
        why = "the check is not followed by the owner comparison that stops (a transferred repository, #53 2026-11-16)"
    elif push is not None and push < q: why = "pushes before the lookup"
    elif uses and (a is None or not (q < a < min(uses))): why = "names the repository before OWNER_REPO=$CANON"
    if why: bad.append(lines[0][:40] + ": " + why)
print(n, "; ".join(bad))
PY
}
bash_blocks() { python3 -I -c 'import re,sys; print("\n".join(re.findall(r"```(?:bash|sh|zsh|shell)\n(.*?)```", open(sys.argv[1]).read(), re.S)))' "$PLUGIN_ROOT/skills/$1/SKILL.md"; }
for s in mcp-deploy cli-deploy; do
  CODE=$(bash_blocks "$s")
  hasnt "$s: the release API is not given target_commitish" "$CODE" 'target_commitish='
  hasnt "$s: no gh release view without --repo" "$(printf '%s\n' "$CODE" | grep 'gh release view' | grep -v -- '--repo')" 'gh release view'
  # a derivation is any line that assigns OWNER_REPO, however it is written; the one line
  # that is not is `OWNER_REPO=$CANON` (#53), which takes over the name GitHub answered with
  N_DERIVE=$(printf '%s\n' "$CODE" | grep '^OWNER_REPO=' | grep -vcxF 'OWNER_REPO=$CANON')
  N_STRICT=$(printf '%s\n' "$CODE" | grep -A1 '^OWNER_REPO=' | grep -c 'grep -qxE')
  same "$s: every owner/repo derivation ($N_DERIVE) is followed by the strict check" "$N_STRICT" "$N_DERIVE"
  # #53: every block that works out owner/repo asks GitHub for the repository's current name,
  # in this order: derivation, lookup, (the push, in the blocks that push), `OWNER_REPO=$CANON`,
  # and only then the first call that names the repository - in any spelling of that call.
  # The lookup's answer is checked on the next line: one line only, and the strict pattern; the
  # line after that compares the owners and stops when they differ (a transfer, 2026-11-16).
  REPORT=$(lookup_order "$PLUGIN_ROOT/skills/$s/SKILL.md")
  case "$s" in mcp-deploy) WANT=4 ;; *) WANT=3 ;; esac
  same "$s: the blocks that work out owner/repo ($WANT: the push block, the tag block, the release blocks) all look up the current name, in order (#53)" "$REPORT" "$WANT "
  has "$s: the completion report has a tag line" "$(cat "$PLUGIN_ROOT/skills/$s/SKILL.md")" '- **Tag**: '
done
has "mcp-deploy: gh release create checks the tag exists" "$(grep 'gh release create' "$PLUGIN_ROOT/skills/mcp-deploy/SKILL.md")" '--verify-tag'
# #49: the hand-release examples outside the skills — rules/ and the templates that get copied
# into other repos — tag first too: gh never creates the tag, an example pushes one tag only, and
# a failed step stops the example before the release is created.
#
# Two kinds of check. The text checks guard against a forgotten step. They do not parse shell
# and look only for the commands and flags named below: a tag pushed by its short name
# (`git push origin v1`) is not recognised as a tag push; the tag name is not compared with the
# release name; a forced push, a + refspec or a dry run of the helper goes unnoticed; ~~~ fences
# are not read; and the one way of stopping on failure they know is a line that ends in &&
# (`set -e` or `|| exit` is reported as unchained). The behaviour check after them runs the two
# examples with stand-in commands; it is the one that shows a failed step stops the release.
#
# doc_commands prints the commands of a document, one per line: every line of a fenced block
# (backslash-continued lines joined, so a flag on a continuation line counts) and every inline
# code span of the prose around the blocks. Prose outside code spans is not printed, so a
# sentence that names a flag in a span of its own ("do not use `--tags`") is not taken for a
# command. With a second argument it counts instead, in the fenced blocks that hold a
# gh release create (text inside quotes is not looked at):
#   commented  lines with a # comment. An interactive zsh does not treat # as a comment (the
#              macOS default), so a comment line inside an && chain ends the chain there and
#              the next command runs whatever happened before it (#49 verify R3)
#   untagged   gh release create lines with no tagging step (release-tag.sh, or git tag with
#              -a, -s, --annotate or --sign) above them in the block since the previous
#              release command
#   unchained  lines above a gh release create that do not end in &&, and lines up to it that
#              hold ; or | (a release command that follows && on the same line counts as a
#              line of its own)
doc_commands() { python3 -I -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n").replace("\\\n", " ")
parts = re.split(r"^[ \t]*```[^\n]*\n(.*?)^[ \t]*```[ \t]*$", text, flags=re.S | re.M)
blocks, prose = parts[1::2], parts[0::2]
mode = sys.argv[2] if len(sys.argv) > 2 else ""
def bare(line):
    # the line with the text inside quotes blanked out
    out, quote = [], ""
    for ch in line:
        if quote:
            out.append(ch if ch == quote else " ")
            if ch == quote:
                quote = ""
        else:
            out.append(ch)
            if ch in "\"\x27":
                quote = ch
    return "".join(out)
if mode:
    count = {"commented": 0, "untagged": 0, "unchained": 0}
    for block in blocks:
        if "gh release create" not in block:
            continue
        block = re.sub(r"&&[ \t]*(?=gh release create)", "&&\n", block)
        tagged, pending = False, 0
        for line in block.split("\n"):
            code = bare(line)
            if not code.strip():
                continue
            if re.search(r"(^|[ \t])#", code):
                count["commented"] += 1
            if code.lstrip().startswith("#"):
                continue
            separators = 1 if re.search(r"[;|]", code) else 0
            if "gh release create" in code:
                count["untagged"] += not tagged
                count["unchained"] += pending + separators
                tagged, pending = False, 0
                continue
            if re.search(r"release-tag\.sh|git tag (-[A-Za-z]*[as][A-Za-z]*|--annotate|--sign)( |$)", line):
                tagged = True
            pending += 1 if separators or not re.search(r"&&[ \t]*$", code) else 0
    print(count[mode])
else:
    lines = [line for block in blocks for line in block.split("\n")]
    lines += [span for part in prose for span in re.findall(r"`([^`\n]+)`", part)]
    print("\n".join(lines))' "$@"; }
N_EXAMPLES=0
while IFS= read -r f; do
  rel=${f#"$PLUGIN_ROOT"/}
  CMDS=$(doc_commands "$f")
  CREATES=$(printf '%s\n' "$CMDS" | grep -c 'gh release create')
  N_EXAMPLES=$((N_EXAMPLES + CREATES))
  VERIFIED=$(printf '%s\n' "$CMDS" | grep 'gh release create' | grep -cE -- '(^|[[:space:]])--verify-tag(=true)?([[:space:]]|$)')
  same "$rel: every gh release create ($CREATES) has --verify-tag" "$VERIFIED" "$CREATES"
  same "$rel: no # comment in a block with gh release create" "$(doc_commands "$f" commented)" "0"
  same "$rel: every gh release create has a tagging step above it in its block" "$(doc_commands "$f" untagged)" "0"
  same "$rel: every step above a gh release create ends in &&" "$(doc_commands "$f" unchained)" "0"
  hasnt "$rel: no example pushes more than one tag" "$(printf '%s\n' "$CMDS" | grep -E '(^|[^a-z-])push .*((--tags|--follow-tags|--mirror|--all)([^a-z-]|$)|refs/tags/[^[:space:]]*[*])')" 'push'
  TAG_PUSHES=$(printf '%s\n' "$CMDS" | grep -cE '(^|[^a-z-])push .*refs/tags/')
  QUIET_PUSHES=$(printf '%s\n' "$CMDS" | grep -E '(^|[^a-z-])push .*refs/tags/' | grep -c -- '--no-follow-tags')
  same "$rel: every push of a tag ($TAG_PUSHES) has --no-follow-tags" "$QUIET_PUSHES" "$TAG_PUSHES"
done < <(find "$PLUGIN_ROOT/rules" "$PLUGIN_ROOT"/skills/*/templates -type f -name '*.md' | sort)
if [ "$N_EXAMPLES" -ge 2 ]; then ok "rules and templates: the release examples were found ($N_EXAMPLES)"; else bad "rules and templates: expected at least 2 gh release create examples, found $N_EXAMPLES"; fi

# #49, behaviour: each of the two example blocks, placeholders filled in, is read by a shell
# with stand-ins for the helper, make, git and gh. A stand-in logs its name and fails when it is
# the step named in PASTE_FAIL. After a failed step the release must not be created; when every
# step succeeds it must be. `zsh -f -i` reads the block from standard input the way an
# interactive zsh reads a paste: # is not a comment there. The other shells read it as a script.
mkdir -p "$T/bin49" "$T/hd49/scripts" "$T/paste49"
for n in make git gh; do
  printf '%s\n' '#!/bin/sh' 'n=${0##*/}' '[ "$n" = git ] && n="git-$1"' '[ "$n" = gh ] && n=release-created' \
    'echo "$n" >> "$PASTE_LOG"' '[ "$PASTE_FAIL" != "$n" ]' > "$T/bin49/$n"
  chmod +x "$T/bin49/$n"
done
printf '%s\n' '#!/bin/sh' 'echo helper >> "$PASTE_LOG"' '[ "$PASTE_FAIL" != helper ]' > "$T/hd49/scripts/release-tag.sh"
# release_block <file> ['old ==> new' ...] — the first fenced block with a gh release create
release_block() { python3 -I -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = [b for b in re.findall(r"^[ \t]*```[^\n]*\n(.*?)^[ \t]*```[ \t]*$", text, re.S | re.M) if "gh release create" in b]
out = blocks[0] if blocks else ""
for pair in sys.argv[2:]:
    old, new = pair.split(" ==> ", 1)
    out = out.replace(old, new)
sys.stdout.write(out)' "$@"; }
# pasted <step that fails, or none> <shell and its arguments> — what ran, in order
pasted() {
  local fail=$1; shift
  rm -f "$T/paste.log"
  ( cd "$T/paste49" && env -i PATH="$T/bin49:/usr/bin:/bin" HOME="$T/paste49" PASTE_LOG="$T/paste.log" PASTE_FAIL="$fail" "$@" < "$T/paste.in" >/dev/null 2>&1 )
  tr '\n' ' ' < "$T/paste.log" 2>/dev/null
}
for EX in "rules/mcp-binary-distribution.md|helper" "skills/mcp-sign-pipeline/templates/README-signing-section.md|make git-tag git-push"; do
  doc=${EX%%|*}; steps=${EX#*|}
  release_block "$PLUGIN_ROOT/$doc" "<harness-devtools> ==> $T/hd49" "<release-commit> ==> HEAD" "<path-to-binary> ==> bin/x" \
    "[<path-to-mcpb>] ==> x.mcpb" "{{TARGET_NAME}} ==> MyMCP" > "$T/paste.in"
  if [ -s "$T/paste.in" ]; then ok "$doc: the release example block was found"; else bad "$doc: no fenced block with gh release create"; fi
  for sh in $SHELLS zsh-paste; do
    case "$sh" in
      zsh-paste) command -v zsh >/dev/null 2>&1 || { echo "  - $doc: zsh is not installed; the interactive-zsh case was NOT run"; continue; }
                 SH_CMD=("$(command -v zsh)" -f -i); label="pasted into an interactive zsh" ;;
      zsh)       SH_CMD=("$(command -v zsh)" -f); label="zsh" ;;
      *)         SH_CMD=("$(command -v "$sh")"); label=$sh ;;
    esac
    for fail in $steps; do
      hasnt "$doc: $fail fails → no release ($label)" "$(pasted "$fail" "${SH_CMD[@]}")" 'release-created'
    done
    has "$doc: every step succeeds → the release is created ($label)" "$(pasted none "${SH_CMD[@]}")" 'release-created'
  done
done
# verify R3: the release steps use the VERSION checked at the top of their block, not a raw {version}
release_blocks() { python3 -I -c 'import re,sys; print("\n".join(b for b in re.findall(r"```bash\n(.*?)```", open(sys.argv[1]).read(), re.S) if "--method POST" in b or "gh release create" in b))' "$PLUGIN_ROOT/skills/$1/SKILL.md"; }
for s in mcp-deploy cli-deploy; do
  has "$s: the release blocks are found (the next check is not run on nothing)" "$(release_blocks "$s")" '/releases" --method POST'
  hasnt "$s: the release blocks do not substitute v{version} unchecked" "$(release_blocks "$s")" 'v{version}'
done
# verify R4: the guard must not repeat the placeholder it guards — substituting {version}
# everywhere would turn the sentinel into the real version and reject every valid run
for s in mcp-deploy cli-deploy; do
  hasnt "$s: no case pattern repeats '{version}'" "$(bash_blocks "$s")" "'{version}'|"
done
hasnt "cli-deploy: no case pattern repeats '{binary}'" "$(bash_blocks cli-deploy)" "'{binary}'|"
hasnt "cli-deploy: no case pattern ends in '{binary}'" "$(bash_blocks cli-deploy)" "|'{binary}')"
# #50: {binary} is substituted on its own assignment line and nowhere else in a shell block. Only fences
# that open at the start of a line count: the release notes template holds an escaped \```bash of its own
shell_fences() { python3 -I -c 'import re,sys; print("\n".join(re.findall(r"^```(?:bash|sh|zsh|shell)\n(.*?)^```", open(sys.argv[1], encoding="utf-8").read(), re.S | re.M)))' "$PLUGIN_ROOT/skills/$1/SKILL.md"; }
same "cli-deploy: every {binary} in a bash block is on a BINARY_NAME='{binary}' line" \
  "$(shell_fences cli-deploy | grep -F '{binary}' | grep -vc "^BINARY_NAME='{binary}'   #")" "0"
same "cli-deploy: exactly one bash line assigns BINARY_NAME='{binary}' (the Step 2 release block)" \
  "$(shell_fences cli-deploy | grep -c "^BINARY_NAME='{binary}'")" "1"
hasnt "plugin-deploy: no case pattern repeats '{plugin-name}'" "$(bash_blocks plugin-deploy)" "'{plugin-name}'|"
hasnt "plugin-deploy: no case pattern repeats '{marketplace-root}'" "$(bash_blocks plugin-deploy)" "|'{marketplace-root}')"
# verify R3 / #39: skill loading may replace $0, $1, … with the invocation's arguments
for SM in "mcp-deploy:Step 3a: VERSION" "cli-deploy:Step 1.5: VERSION" "plugin-deploy:Step 7.5: PLUGIN_NAME"; do
  fence "${SM%%:*}" "${SM#*:}" "$T/pos.sh"
  hasnt "${SM%%:*}: the tag fence has no bare \$<digit> (#39)" "$(grep -oE '\$[0-9]' "$T/pos.sh" | head -1)" '$'
done

for SK in mcp-deploy:3a cli-deploy:1.5; do
  S=${SK%%:*}; STEP=${SK#*:}
  echo "$S Step $STEP"

  mk "$S-main"; W="$T/$S-main"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/f.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/f.sh"
    has "on main: tagged or exists, then hands over to the release step ($sh)" "$OUT" "→ Step $STEP: v1.4.0 已在 o/r"
  done
  same "on main: v1.4.0 is on HEAD" "$(rtag "$T/$S-main.git" v1.4.0)" "$(git -C "$W" rev-parse HEAD)"

  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W"; push "$W"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/f.sh"
    has "files say 1.4.1, the release is 1.4.0 → stops ($sh)" "$OUT" "版本檔與 1.4.0 不一致"
    has "…and says no release ($sh)" "$OUT" "不建 release"
  done
  if [ "$S" = mcp-deploy ]; then
    has "mcp-deploy: the Step 3a message says the .mcpb is packed again" "$OUT" "從 Phase 2 Step 5 重新打包"
    has "…and that a compiled-in file means building again first" "$OUT" "Phase 1 A2 重新編譯"
  fi

  git -C "$W" checkout -q -b feat; put "$W" mcpb/manifest.json '{ "version": "1.5.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/f15.sh" "VERSION='{version}' ==> VERSION='1.5.0'"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/f15.sh"
    has "feature branch → stops, not the default branch ($sh)" "$OUT" "不是預設 branch"
  done
  same "feature branch: no v1.5.0 on the remote" "$(rtag "$T/$S-main.git" v1.5.0)" ""
  git -C "$W" checkout -q main

  mk "$S-work"; W="$T/$S-work"
  put "$W" mcpb/manifest.json '{ "version": "2.0.0" }'; ci "$W"; push "$W"; git -C "$W" branch -m work
  fence "$S" "Step $STEP: VERSION" "$T/f2.sh" "VERSION='{version}' ==> VERSION='2.0.0'"
  run bash "$W" "$T/f2.sh"
  has "local 'work' tracking origin/main → tagged (the upstream branch is what counts)" "$OUT" "→ Step $STEP: v2.0.0 已在 o/r"

  # verify R7: @{u} is a local cache; the remote's branch itself must be at HEAD
  mk "$S-stale"; W="$T/$S-stale"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  git -C "$W" checkout -q -b side; put "$W" side.txt s; ci "$W"; git -C "$W" push -q origin side 2>/dev/null; git -C "$W" checkout -q main
  git --git-dir="$T/$S-stale.git" update-ref refs/heads/main "$(git -C "$W" rev-parse side)"
  fence "$S" "Step $STEP: VERSION" "$T/f7.sh" "VERSION='{version}' ==> VERSION='1.0.0'"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/f7.sh"
    has "the remote's main was rewritten, the local @{u} still says HEAD → stops ($sh)" "$OUT" "不是 HEAD"
    has "…and warns not to pull and rerun, which would tag someone else's commit ($sh)" "$OUT" "不要 pull"
  done
  # verify R8: after a fetch the local @{u} is ahead of HEAD — not "the push failed"
  git -C "$W" fetch -q origin
  run bash "$W" "$T/f7.sh"
  hasnt "after a fetch: HEAD behind upstream is not reported as an unpushed HEAD" "$OUT" "沒推成功？）"
  has "…it says HEAD differs from the upstream" "$OUT" "HEAD 與 upstream 不同"
  same "…and no tag pushed" "$(rtag "$T/$S-stale.git" v1.0.0)" ""

  mk "$S-swift"; W="$T/$S-swift"
  put "$W" Sources/S/Version.swift 'public enum V { public static let version: String = "1.0.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/f3.sh" "VERSION='{version}' ==> VERSION='2.0.0'"
  run bash "$W" "$T/f3.sh"
  has "Version.swift says 1.0.0 (typed), release 2.0.0 → stops" "$OUT" "版本檔與 2.0.0 不一致"
  same "…and no v2.0.0 on the remote" "$(rtag "$T/$S-swift.git" v2.0.0)" ""

  mk "$S-alias" "git@github-work:o/r.git"; W="$T/$S-alias"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/f4.sh" "VERSION='{version}' ==> VERSION='1.0.0'"
  run bash "$W" "$T/f4.sh"
  has "ssh host alias remote → says owner/repo cannot be derived" "$OUT" "推不出 github.com 的 owner/repo"
  hasnt "…without printing the URL" "$OUT" "github-work"
  same "…and no tag pushed" "$(rtag "$T/$S-alias.git" v1.0.0)" ""

  mk "$S-cred" "https://user:sekret@github.com/o/r.git"; W="$T/$S-cred"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/f5.sh" "VERSION='{version}' ==> VERSION='1.0.0'"
  run bash "$W" "$T/f5.sh"
  has "credentials in the remote URL → still o/r" "$OUT" "→ Step $STEP: v1.0.0 已在 o/r"
  hasnt "…and the token is not printed" "$OUT" "sekret"

  mk "$S-nothost" "https://notgithub.com/o/r.git"; W="$T/$S-nothost"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  run bash "$W" "$T/f4.sh"
  has "a host that only ends in github.com → owner/repo cannot be derived" "$OUT" "推不出 github.com 的 owner/repo"
  same "…and no tag pushed" "$(rtag "$T/$S-nothost.git" v1.0.0)" ""

  # verify R6: dot segments are not an owner/repo
  mk "$S-dots" "https://github.com/../.."; W="$T/$S-dots"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  run bash "$W" "$T/f4.sh"
  has "a remote URL that reduces to ../.. → owner/repo cannot be derived" "$OUT" "推不出 github.com 的 owner/repo"

  # verify R3: the GitHub repo gh talks to must hold the SAME tag the push created
  mk "$S-other"; W="$T/$S-other"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  git init -q --bare -b main "$T/$S-impostor.git"
  git -C "$W" push -q "$T/$S-impostor.git" main 2>/dev/null
  git -C "$W" tag -a v1.0.0 -m impostor && git -C "$W" push -q "$T/$S-impostor.git" v1.0.0 2>/dev/null && git -C "$W" tag -d v1.0.0 >/dev/null
  export GH_STUB_REMOTE="$T/$S-impostor.git"
  run bash "$W" "$T/f4.sh"
  has "gh's o/r has a different v1.0.0 → stops" "$OUT" "不是同一個 tag"
  hasnt "…and does not hand over to the release step" "$OUT" "已在 o/r；Step"

  W="$T/$S-main"; export GH_STUB_REMOTE="$T/$S-main.git"; git -C "$W" config branch.main.remote nosuch
  run bash "$W" "$T/f.sh"
  has "upstream remote that is not a configured remote → stops" "$OUT" "不是這個 repo 設定過的 remote"
  git -C "$W" config branch.main.remote origin

  fence "$S" "Step $STEP: VERSION" "$T/f6.sh"
  run bash "$W" "$T/f6.sh"
  has "VERSION left as the placeholder → stops" "$OUT" "VERSION 未代入"

  OUT=$(cd "$W" && CLAUDE_PLUGIN_ROOT=/nonexistent PATH="$T/bin:$PATH" bash "$T/f.sh" 2>&1); RC=$?
  has "helper not found → a ✗ line, not a shell error" "$OUT" "找不到"
  same "…exit 1" "$RC" 1

  # #51 (cross-model review, 2026-11-16): the tag step sends a branch without an upstream back to the
  # pre-push step, where the advice and the checks are; it does not suggest a push of its own
  case "$S" in mcp-deploy) PRE="Step 3（推送前檢查）" ;; *) PRE="Step 1 推送（推送前檢查）" ;; esac
  mk "$S-noup"; W="$T/$S-noup"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"
  fence "$S" "Step $STEP: VERSION" "$T/fnu.sh" "VERSION='{version}' ==> VERSION='1.0.0'"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/fnu.sh"
    has "no upstream → stops ($sh)" "$OUT" "沒有指向 remote 的 upstream"
    has "…and sends the user back to the pre-push step ($sh)" "$OUT" "回 $PRE"
    hasnt "…without suggesting git push -u ($sh)" "$OUT" "git push -u"
  done
  same "…and no tag on the remote" "$(rtag "$T/$S-noup.git" v1.0.0)" ""
  # #51: 21 in the tag step. The release commit is already pushed, so a version source in the commit
  # that cannot be read means a new commit and the pre-push step again
  mk "$S-unread"; W="$T/$S-unread"
  put "$W" Sources/App/Version.swift 'enum V { static let version = makeVersion() }'; ci "$W"; push "$W"
  run bash "$W" "$T/fnu.sh"
  has "a version source that cannot be read (21) → stops" "$OUT" "有版本檔讀不出值"
  has "…an environment problem: fix it and run this step again" "$OUT" "原因是環境時（讀 pyproject.toml 需要 python3 3.11 以上，或 tomli）：修好環境後重跑這一步"
  has "…a version source in the commit: a new commit, then the pre-push step" "$OUT" "原因是 commit 裡的某個版本來源讀不出值時：release commit 已經推出去了，要改那個檔案、補一個新的 commit，再回 $PRE"
  same "…and no tag on the remote" "$(rtag "$T/$S-unread.git" v1.0.0)" ""
done

echo "cli-deploy Phase 3 Step 1: every bumped version file is staged, nothing else"
mk cli-stage; W="$T/cli-stage"
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'
put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; put "$W" CHANGELOG.md x; put "$W" notes.txt keep
put "$W" Sources/S/Deep/Version.swift deep
ci "$W"; push "$W"
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'
put "$W" mcpb/manifest.json '{ "version": "1.1.0" }'; put "$W" CHANGELOG.md y; put "$W" notes.txt unrelated
put "$W" Sources/S/Deep/Version.swift unrelated
fence cli-deploy "Phase 3 Step 1: stage" "$T/stage.sh" "VERSION='{version}' ==> VERSION='1.1.0'"
msgfile "$W" 'v1.1.0: test'
run bash "$W" "$T/stage.sh"
same "Version.swift committed" "$(git -C "$W" show HEAD:Sources/S/Version.swift)" 'enum V { static let version = "1.1.0" }'
same "mcpb/manifest.json committed" "$(git -C "$W" show HEAD:mcpb/manifest.json)" '{ "version": "1.1.0" }'
same "an unrelated modified file is not committed" "$(git -C "$W" show HEAD:notes.txt)" keep
same "a deeper Sources/*/*/Version.swift is not a version source and is not committed (verify R8)" "$(git -C "$W" show HEAD:Sources/S/Deep/Version.swift)" deep
fence cli-deploy "推送前檢查（#51）" "$T/cpush.sh" "VERSION='{version}' ==> VERSION='1.1.0'"
run bash "$W" "$T/cpush.sh"
has "the push block then pushes the release commit" "$OUT" "→ Step 1 推送: release commit 已推到"
fence cli-deploy "Step 1.5: VERSION" "$T/c15.sh" "VERSION='{version}' ==> VERSION='1.1.0'"
run bash "$W" "$T/c15.sh"
has "Step 1.5 then tags v1.1.0" "$OUT" "→ Step 1.5: v1.1.0 已在 o/r"

# verify R3: a CHANGELOG.md created by this release (untracked) is staged too; other new files are not
mk cli-new; W="$T/cli-new"
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'; ci "$W"; push "$W"
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; put "$W" CHANGELOG.md first; put "$W" scratch.txt junk
put "$W" package.json '{ "private": true }'
msgfile "$W" 'v1.1.0: test'
run bash "$W" "$T/stage.sh"
same "a newly created CHANGELOG.md is committed" "$(git -C "$W" show HEAD:CHANGELOG.md 2>/dev/null)" first
same "an unrelated new file is not committed" "$(git -C "$W" ls-tree --name-only HEAD scratch.txt)" ""
same "an untracked package.json this release did not create is not committed (verify R4)" "$(git -C "$W" ls-tree --name-only HEAD package.json)" ""

echo "plugin-deploy Step 7.5"
mk pd; W="$T/pd"
put "$W" .claude-plugin/marketplace.json '{ "plugins": [ { "name": "foo", "source": "./plugins/foo" } ] }'
put "$W" plugins/foo/.claude-plugin/plugin.json '{ "name": "foo", "version": "0.9.0" }'; ci "$W" a
put "$W" plugins/foo/.claude-plugin/plugin.json '{ "name": "foo", "version": "1.0.0" }'; ci "$W" bump
B=$(git -C "$W" rev-parse HEAD)
put "$W" plugins/foo/README.md wip; ci "$W" wip; push "$W"
git -C "$W" config harness-devtools.releaseTag true   # opt-in (#42, 2026-11-10)
fence plugin-deploy "Step 7.5: PLUGIN_NAME" "$T/p.sh" "PLUGIN_NAME='{plugin-name}' ==> PLUGIN_NAME='foo'" "MARKETPLACE_ROOT='{marketplace-root}' ==> MARKETPLACE_ROOT='$W'"
for sh in $SHELLS; do
  run "$sh" "$T" "$T/p.sh"
  has "tagged or exists ($sh)" "$OUT" "→ Step 7.5: release-tag rc=0"
done
same "foo-v1.0.0 is on the bump commit, not the later wip commit" "$(rtag "$T/pd.git" foo-v1.0.0)" "$B"
has "the helper's note about the later commit is shown" "$OUT" "commits after the tagged one"

fence plugin-deploy "Step 7.5: PLUGIN_NAME" "$T/p0.sh" "PLUGIN_NAME='{plugin-name}' ==> PLUGIN_NAME='foo'"
run bash "$T" "$T/p0.sh"
has "MARKETPLACE_ROOT left as the placeholder → no tag" "$OUT" "MARKETPLACE_ROOT 未代入"

git -C "$W" checkout -q -b feat; put "$W" plugins/foo/x.txt y; ci "$W"; push "$W"
run bash "$T" "$T/p.sh"
has "feature branch → no tag" "$OUT" "不是 origin 的預設 branch"
git -C "$W" checkout -q main

# verify R7: the remote's branch itself must be at HEAD, not only the local @{u}
mk pds; W="$T/pds"
put "$W" .claude-plugin/marketplace.json '{ "plugins": [ { "name": "foo", "source": "./plugins/foo" } ] }'
put "$W" plugins/foo/.claude-plugin/plugin.json '{ "name": "foo", "version": "1.0.0" }'; ci "$W" a; push "$W"
git -C "$W" config harness-devtools.releaseTag true
git -C "$W" checkout -q -b side; put "$W" side.txt s; ci "$W"; git -C "$W" push -q origin side 2>/dev/null; git -C "$W" checkout -q main
git --git-dir="$T/pds.git" update-ref refs/heads/main "$(git -C "$W" rev-parse side)"
fence plugin-deploy "Step 7.5: PLUGIN_NAME" "$T/ps.sh" "PLUGIN_NAME='{plugin-name}' ==> PLUGIN_NAME='foo'" "MARKETPLACE_ROOT='{marketplace-root}' ==> MARKETPLACE_ROOT='$W'"
for sh in $SHELLS; do
  run "$sh" "$T" "$T/ps.sh"
  has "the remote's main was rewritten, the local @{u} still says HEAD → no tag ($sh)" "$OUT" "不是 HEAD"
done
same "…and nothing tagged" "$(rtag "$T/pds.git" foo-v1.0.0)" ""

mk pdn; W="$T/pdn"
put "$W" .claude-plugin/marketplace.json '{ "plugins": [ { "name": "bar", "source": "./plugins/bar" } ] }'
put "$W" README.md outer; ci "$W" outer; push "$W"; git -C "$W" config harness-devtools.releaseTag true
git init -q --bare -b main "$T/inner.git"; git init -q -b main "$W/plugins/bar"
git -C "$W/plugins/bar" remote add origin "$T/inner.git"
put "$W/plugins/bar" .claude-plugin/plugin.json '{ "name": "bar", "version": "1.0.0" }'; ci "$W/plugins/bar" inner
fence plugin-deploy "Step 7.5: PLUGIN_NAME" "$T/pn.sh" "PLUGIN_NAME='{plugin-name}' ==> PLUGIN_NAME='bar'" "MARKETPLACE_ROOT='{marketplace-root}' ==> MARKETPLACE_ROOT='$W'"
run bash "$T" "$T/pn.sh"
has "plugin dir is its own git repo → no tag" "$OUT" "是另一個 git repo"
same "…and nothing reached that repo's remote" "$(git --git-dir="$T/inner.git" for-each-ref --format=x | wc -l | tr -d ' ')" 0

# opt-in (#42, 2026-11-10): plugin-deploy does not push a tag unless harness-devtools.releaseTag is true
mk pdo; W="$T/pdo"
put "$W" .claude-plugin/marketplace.json '{ "plugins": [ { "name": "foo", "source": "./plugins/foo" } ] }'
put "$W" plugins/foo/.claude-plugin/plugin.json '{ "name": "foo", "version": "1.0.0" }'; ci "$W" a; push "$W"
fence plugin-deploy "Step 7.5: PLUGIN_NAME" "$T/po.sh" "PLUGIN_NAME='{plugin-name}' ==> PLUGIN_NAME='foo'" "MARKETPLACE_ROOT='{marketplace-root}' ==> MARKETPLACE_ROOT='$W'"
for sh in $SHELLS; do
  run "$sh" "$T" "$T/po.sh"
  has "release tags not enabled → no tag, says how to enable ($sh)" "$OUT" "git config harness-devtools.releaseTag true"
done
same "…and nothing tagged" "$(rtag "$T/pdo.git" foo-v1.0.0)" ""
# the switch is checked before the helper (verify R10)
OUT=$(cd "$T" && CLAUDE_PLUGIN_ROOT=/nonexistent PATH="$T/bin:$PATH" bash "$T/po.sh" 2>&1)
has "switch off and helper missing → the switch is reported, not the helper" "$OUT" "沒有開啟自動推 tag"
printf '[harness-devtools]\n\treleaseTag = true\n' > "$T/gitconfig-on"
git -C "$W" config harness-devtools.releaseTag false
OUT=$(cd "$T" && GIT_CONFIG_GLOBAL="$T/gitconfig-on" PATH="$T/bin:$PATH" bash "$T/po.sh" 2>&1)
has "repo false over global true → no tag" "$OUT" "沒有開啟自動推 tag"
git -C "$W" config harness-devtools.releaseTag maybe
OUT=$(cd "$T" && PATH="$T/bin:$PATH" bash "$T/po.sh" 2>&1)
has "a value that is not a boolean counts as off" "$OUT" "沒有開啟自動推 tag"
git -C "$W" config --unset harness-devtools.releaseTag
OUT=$(cd "$T" && GIT_CONFIG_GLOBAL="$T/gitconfig-on" PATH="$T/bin:$PATH" bash "$T/po.sh" 2>&1)
has "global true alone → tagged" "$OUT" "→ Step 7.5: release-tag rc=0"
same "…foo-v1.0.0 on the remote" "$(rtag "$T/pdo.git" foo-v1.0.0)" "$(git -C "$W" rev-parse HEAD)"
# mcp-deploy and cli-deploy need the tag to build the release, so the switch does not apply to them
for s in mcp-deploy cli-deploy; do
  hasnt "$s: the release tag does not depend on harness-devtools.releaseTag" "$(bash_blocks "$s")" 'harness-devtools.releaseTag'
done

echo "free text never reaches a shell: commit message, release title, release notes, repo description (#50)"
for s in mcp-deploy cli-deploy; do
  CODE=$(bash_blocks "$s")
  for ph in '{title}' '{release-notes}' '{change-summary}' '{updated-description}'; do
    hasnt "$s: no bash block holds the free-text placeholder $ph" "$CODE" "$ph"
  done
done
echo "no bash block holds a placeholder that is not on the list of identifier placeholders (#50)"
# one list per skill. description and keywords are on mcp-deploy's list only for its Phase 4 heredocs (quoted, one-line values, #56).
# The pattern takes any {words} (spaces and CJK too: a free-text placeholder is usually written that way), not only identifiers;
# {'x'} (a guard spells the placeholder with split braces), ${x}, %{x}, awk programs and { cmd; } groups are not placeholders.
for s in mcp-deploy cli-deploy; do
  case "$s" in
    mcp-deploy) ALLOW=" BinaryName description keywords owner project-name project_name repo u version " ;;
    cli-deploy) ALLOW=" binary owner repo u version " ;;
  esac
  FOUND=$(python3 -I -c 'import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
seen = []
W = r"[^\s{}\x27$=;()\"\\|&<>*?]+"
for b in re.findall(r"```(?:bash|sh|zsh|shell)\n(.*?)```", t, re.S):
    for m in re.findall(r"(?<![$%])\{(" + W + r"(?: " + W + r")*)\}", b):
        if m not in seen:
            seen.append(m)
print("\n".join(seen))' "$PLUGIN_ROOT/skills/$s/SKILL.md")
  UNKNOWN=""
  while IFS= read -r tk; do
    [ -n "$tk" ] || continue
    case "$ALLOW" in *" $tk "*) ;; *) UNKNOWN="$UNKNOWN{$tk} " ;; esac
  done <<< "$FOUND"
  same "$s: every placeholder in a shell block is on this skill's list of identifiers (a new one needs a decision: free text goes through a file)" "$UNKNOWN" ""
done
echo "no bash block writes a variable name directly in front of a non-ASCII character (#50)"
# $NAME followed by a full-width character such as ： or （ : bash takes the character's bytes as part of the name,
# the variable comes out empty and the message is garbled. Write ${NAME}.
for s in mcp-deploy cli-deploy; do
  BAD=$(python3 -I -c 'import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
out = []
for b in re.findall(r"```(?:bash|sh|zsh|shell)\n(.*?)```", t, re.S):
    for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])", b):
        out.append(m.group(0))
print(" ".join(out))' "$PLUGIN_ROOT/skills/$s/SKILL.md")
  same "$s: every \$NAME in a bash block that is followed by non-ASCII text is written \${NAME}" "$BAD" ""
done
echo "the skills never recommend bypassPermissions to get a file written (#50)"
for f in skills/mcp-deploy/SKILL.md skills/cli-deploy/SKILL.md CLAUDE.md; do
  # clause by clause (a line holds several; split at 。 and ；): every clause that names it must also say 不要
  BAD=$(python3 -I -c 'import re, sys
for s in re.split(r"[。；\n]", open(sys.argv[1], encoding="utf-8").read()):
    if "bypassPermissions" in s and "不要" not in s:
        print(s.strip()[:80])' "$PLUGIN_ROOT/$f")
  same "$f: bypassPermissions only appears in a sentence that says not to use it" "$BAD" ""
done
# gh and curl stand-ins that record what they were given, one value per file, and play
# the release endpoints of "the GitHub repo o/r"
mkdir -p "$T/bin50"
cat > "$T/bin50/gh" <<'SH'
#!/bin/sh
REC="$GH50_REC"
printf '%s\n' "$1 $2" >> "$REC/calls"
case "$1 $2" in
  "api repos/o/r/git/ref/tags/"*)
    git --git-dir="$GH_STUB_REMOTE" rev-parse -q --verify "refs/tags/${2#repos/o/r/git/ref/tags/}" || exit 1
    exit 0 ;;
  "auth token") echo tok; exit 0 ;;
esac
# the repository itself: `gh api repos/<name> --jq .full_name` (#53)
case "$1 $2 $3 $4" in
  "api repos/"*/*/*" --jq .full_name") ;;
  "api repos/"*/*" --jq .full_name") exec "$GH50_BIN/gh-full-name" "${2#repos/}" ;;
esac
# gh release create: every argument, one per line (the assets are the ones that are not flags or their values)
[ "$1 $2" != "release create" ] || for a in "$@"; do printf '%s\n' "$a"; done > "$REC/create-args"
prev=""
for a in "$@"; do
  case "$prev" in
    --repo|-R)     printf '%s' "$a" > "$REC/repo"; printf '%s\n' "$a" >> "$REC/repos" ;;
    --title)       printf '%s' "$a" > "$REC/title" ;;
    --notes)       printf '%s' "$a" > "$REC/notes-inline" ;;
    --notes-file)  cp "$a" "$REC/notes-file" ;;
    --description) printf '%s' "$a" > "$REC/description" ;;
  esac
  case "$a" in
    name=*)  printf '%s' "${a#name=}" > "$REC/name" ;;
    body=@*) cp "${a#body=@}" "$REC/body-file" ;;
    body=*)  printf '%s' "${a#body=}" > "$REC/body-inline" ;;
  esac
  prev=$a
done
[ -n "${GH50_FAIL:-}" ] && exit 1
[ -n "${GH50_FAIL_VIEW:-}" ] && [ "$1 $2" = "release view" ] && exit 1
[ -n "${GH50_FAIL_POST:-}" ] && [ "$1 $2" = "api repos/o/r/releases" ] && exit 1
case "$1 $2" in "release view") printf '%s\n' "${GH50_ASSETS-Bin proj.mcpb}" | tr ' ' '\n' ;; esac
case "$1 $2" in "api repos/o/r/releases") echo 42 ;; esac
exit 0
SH
printf '%s\n' '#!/bin/sh' 'printf "%s\n" curl >> "$GH50_REC/calls"' 'printf "%s\n" "$*" >> "$GH50_REC/curl-args"' 'exit 0' > "$T/bin50/curl"
chmod +x "$T/bin50/gh" "$T/bin50/curl"
# run50 <shell> <dir> <script> — like run, with the recording gh and curl; $T/rec starts empty.
# Nothing is handed over in the environment: each Bash call of the skill is a fresh shell, so a
# block has to set every variable it uses itself (#50 cross-model review, 2026-11-16)
run50() {
  local sh=$1 dir=$2 f=$3
  rm -rf "$T/rec"; mkdir -p "$T/rec"
  case "$sh" in
    zsh) OUT=$(cd "$dir" && GH50_REC="$T/rec" GH50_BIN="$T/bin" PATH="$T/bin50:$PATH" zsh -f -c "$(cat "$f")" 2>&1); RC=$? ;;
    *)   OUT=$(cd "$dir" && GH50_REC="$T/rec" GH50_BIN="$T/bin" PATH="$T/bin50:$PATH" "$sh" "$f" 2>&1); RC=$? ;;
  esac
}
# hostile <word> — one line that runs commands and breaks out of quotes if a shell ever parses it
hostile() { printf '%s' "$1 \`touch $T/pwned\` \$(touch $T/pwned) \"dq\" 'sq' \\ \$HOME ; touch $T/pwned #"; }
pwned() { if [ -e "$T/pwned" ]; then bad "$1: text from a file was executed"; rm -f "$T/pwned"; else ok "$1: nothing in the text was executed"; fi; }
deploy_dir() { printf '%s/harness-deploy' "$(git -C "$1" rev-parse --absolute-git-dir)"; }
left() { ls "$1" 2>/dev/null | tr '\n' ' '; }

for SM in "mcp-deploy:Step 2" "cli-deploy:Step 1"; do
  S=${SM%%:*}; STEP=${SM#*:}
  mk "$S-50"; W="$T/$S-50"; put "$W" README.md x; put "$W" CHANGELOG.md x; ci "$W"; push "$W"
  # a user setting that drops the lines of a message that start with #; the block must not depend on it
  git -C "$W" config commit.cleanup strip
  D=$(deploy_dir "$W"); mkdir -p "$D"; echo stale > "$D/commit-message.txt"; echo stale > "$D/release-notes.md"
  if [ "$S" = mcp-deploy ]; then echo stale > "$D/release-title.txt"; echo stale > "$D/repo-description.txt"; fi
  fence "$S" "$STEP: DEPLOY_TMP" "$T/prep.sh"
  for sh in $SHELLS; do
    run50 "$sh" "$W" "$T/prep.sh"
    has "$S: the prepare block prints the directory ($sh)" "$OUT" "$D"
  done
  same "$S: …and removes what an earlier run left there" "$(left "$D")" ""

  if [ "$S" = mcp-deploy ]; then MARK="Step 2: VERSION"; else MARK="Phase 3 Step 1: stage"; fi
  fence "$S" "$MARK" "$T/commit.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
  BEFORE=$(git -C "$W" rev-parse HEAD)
  put "$W" CHANGELOG.md changed
  run50 bash "$W" "$T/commit.sh"
  has "$S: no message file → stops" "$OUT" "找不到 commit 訊息檔"
  same "$S: …and nothing is committed" "$(git -C "$W" rev-parse HEAD)" "$BEFORE"
  printf '%s\n' 'v1.3.0: an older release' > "$D/commit-message.txt"
  run50 bash "$W" "$T/commit.sh"
  has "$S: a message left from another version → stops" "$OUT" "第一行要是"
  same "$S: …and nothing is committed" "$(git -C "$W" rev-parse HEAD)" "$BEFORE"
  printf '%s\n' 'v1.4.0: {change-summary}' > "$D/commit-message.txt"
  run50 bash "$W" "$T/commit.sh"
  has "$S: a summary that was never filled in → stops" "$OUT" "還沒代入"
  same "$S: …and nothing is committed" "$(git -C "$W" rev-parse HEAD)" "$BEFORE"
  # the first line must be exactly v<version>: and then something; a longer version, a pre-release, the bare tag and an empty summary are not
  for first in 'v1.4.0-rc1: left by an earlier release candidate' 'v1.4.01: another version' 'v1.4.0' 'v1.4.0: '; do
    printf '%s\n' "$first" > "$D/commit-message.txt"
    run50 bash "$W" "$T/commit.sh"
    has "$S: first line [$first] → stops" "$OUT" "第一行要是"
    same "$S: …and nothing is committed" "$(git -C "$W" rev-parse HEAD)" "$BEFORE"
  done
  for sh in $SHELLS; do
    put "$W" CHANGELOG.md "changed for $sh"
    { printf 'v1.4.0: '; hostile subject; printf '\n\n'; hostile body; printf '\n# not a comment\n'; } > "$D/commit-message.txt"
    cp "$D/commit-message.txt" "$T/expected-msg"
    BEFORE=$(git -C "$W" rev-parse HEAD)
    run50 "$sh" "$W" "$T/commit.sh"
    if [ "$(git -C "$W" rev-parse HEAD)" = "$BEFORE" ]; then bad "$S: no commit was made ($sh)" "$OUT"; else ok "$S: a commit is made ($sh)"; fi
    same "$S: the commit message is the file, character for character ($sh)" "$(git -C "$W" log -1 --format=%B)" "$(cat "$T/expected-msg")"
    pwned "$S commit ($sh)"
    same "$S: the message file is removed after the commit ($sh)" "$(left "$D")" ""
  done
done

# release texts for mcp-deploy: a title line and notes with a heredoc terminator and a code fence in them
mk mcp-rel; W="$T/mcp-rel"
put "$W" mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
put "$W" mcpb/server/Bin x; put "$W" mcpb/proj.mcpb x
ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
D=$(deploy_dir "$W"); mkdir -p "$D"
release_texts() {
  { hostile title; printf '\n'; } > "$D/release-title.txt"
  { hostile notes; printf '\nEOF\n```bash\necho hi\n```\n'; } > "$D/release-notes.md"
  cp "$D/release-notes.md" "$T/expected-notes"
}

echo "mcp-deploy Step 4, method A (#50)"
fence mcp-deploy 'releases" --method POST' "$T/relA.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
run50 bash "$W" "$T/relA.sh"
has "no notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
printf '%s\n' '{CHANGELOG 內容}' > "$D/release-notes.md"
run50 bash "$W" "$T/relA.sh"
has "notes that are still the template → stops" "$OUT" "還有沒代入的 placeholder"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
release_texts; printf '%s\n' '{title}' > "$D/release-title.txt"
run50 bash "$W" "$T/relA.sh"
has "a title that was never filled in → stops" "$OUT" "標題還沒代入"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
release_texts; printf '%s\n' 'v1.4.0 - the one that was released' > "$D/release-title.txt"
run50 bash "$W" "$T/relA.sh"
has "a title that already starts with v<version> → stops" "$OUT" "不要以 v1.4.0 開頭"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
for tok in release-notes 'CHANGELOG 內容' project-name BinaryName owner repo; do
  release_texts; printf '## Install\n\nx {%s} y\n' "$tok" > "$D/release-notes.md"
  run50 bash "$W" "$T/relA.sh"
  has "notes that still hold {$tok} → stops, and names it" "$OUT" "沒代入的 placeholder：{$tok}"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
done
release_texts; printf 'curl -L https://github.com/o/r/releases/download/v{version}/Bin\n' > "$D/release-notes.md"
run50 bash "$W" "$T/relA.sh"
has "notes that still hold the install url's v{version} → stops, and names it" "$OUT" "沒代入的 placeholder：download/v{version}"
release_texts; : > "$D/release-notes.md"
run50 bash "$W" "$T/relA.sh"
has "an empty notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
for sh in $SHELLS; do
  release_texts
  run50 "$sh" "$W" "$T/relA.sh"
  same "the release name is v<version> - <title>, character for character ($sh)" "$(cat "$T/rec/name" 2>/dev/null)" "v1.4.0 - $(hostile title)"
  if cmp -s "$T/rec/body-file" "$T/expected-notes"; then ok "the body is the notes file, byte for byte ($sh)"; else bad "the body is not the notes file ($sh)" "$OUT"; fi
  if [ -e "$T/rec/body-inline" ]; then bad "the notes were put on the command line ($sh)"; else ok "the notes are not on the command line ($sh)"; fi
  pwned "method A ($sh)"
  same "both text files are removed once the release exists ($sh)" "$(left "$D")" ""
done
release_texts; rm -f "$D/release-title.txt"
run50 bash "$W" "$T/relA.sh"
same "without a title file the release is named v<version>" "$(cat "$T/rec/name" 2>/dev/null)" "v1.4.0"
printf 'true\n' > "$D/release-notes.md"
run50 bash "$W" "$T/relA.sh"
same "notes that read true are sent from the file, not as a typed value" "$(cat "$T/rec/body-file" 2>/dev/null)" "true"
release_texts; export GH50_FAIL=1; run50 bash "$W" "$T/relA.sh"; unset GH50_FAIL
same "a release that was not created keeps the text files for the retry" "$(left "$D")" "release-notes.md release-title.txt "
release_texts; export GH50_FAIL_VIEW=1; run50 bash "$W" "$T/relA.sh"; unset GH50_FAIL_VIEW
has "the release exists but the check after the upload fails → says so" "$OUT" "Release created: ID=42"
same "…and the text files are kept, the release has to be made again" "$(left "$D")" "release-notes.md release-title.txt "
# the gate is what the release really holds: curl has no --fail, an HTTP error does not change its exit code
release_texts; export GH50_ASSETS="Bin"; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
has "an asset is missing from the release → says which" "$OUT" "release 上沒有 proj.mcpb"
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
release_texts; export GH50_ASSETS=""; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
has "the release holds no asset at all → stops" "$OUT" "release 上沒有 Bin"
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
release_texts; export GH50_FAIL_POST=1; run50 bash "$W" "$T/relA.sh"; unset GH50_FAIL_POST
has "no release id → stops before any upload" "$OUT" "release 沒建成"
has "…and tells the user instead of deleting or changing a release itself" "$OUT" "不要自己刪或改它"
hasnt "…nothing was uploaded" "$(cat "$T/rec/calls" 2>/dev/null)" "curl"
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
printf '123\n' > "$D/release-notes.md"
run50 bash "$W" "$T/relA.sh"
same "notes that read 123 are sent from the file, not as a typed value" "$(cat "$T/rec/body-file" 2>/dev/null)" "123"

echo "mcp-deploy Step 4, method B (#50)"
fence mcp-deploy 'gh release create "v$VERSION"' "$T/relB.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
rm -f "$D"/*
run50 bash "$W" "$T/relB.sh"
has "no notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
release_texts; printf '%s\n' 'v1.4.0' > "$D/release-title.txt"
run50 bash "$W" "$T/relB.sh"
has "a title that already starts with v<version> → stops" "$OUT" "不要以 v1.4.0 開頭"
hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
release_texts; printf '%s\n' '{title}' > "$D/release-title.txt"
run50 bash "$W" "$T/relB.sh"
has "a title that was never filled in → stops" "$OUT" "標題還沒代入"
hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
for tok in release-notes 'CHANGELOG 內容' project-name BinaryName owner repo; do
  release_texts; printf '## Install\n\nx {%s} y\n' "$tok" > "$D/release-notes.md"
  run50 bash "$W" "$T/relB.sh"
  has "notes that still hold {$tok} → stops, and names it" "$OUT" "沒代入的 placeholder：{$tok}"
  hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
done
release_texts; printf 'curl -L https://github.com/o/r/releases/download/v{version}/Bin\n' > "$D/release-notes.md"
run50 bash "$W" "$T/relB.sh"
has "notes that still hold the install url's v{version} → stops, and names it" "$OUT" "沒代入的 placeholder：download/v{version}"
release_texts; : > "$D/release-notes.md"
run50 bash "$W" "$T/relB.sh"
has "an empty notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
for sh in $SHELLS; do
  release_texts
  run50 "$sh" "$W" "$T/relB.sh"
  same "--title is v<version> - <title>, character for character ($sh)" "$(cat "$T/rec/title" 2>/dev/null)" "v1.4.0 - $(hostile title)"
  if cmp -s "$T/rec/notes-file" "$T/expected-notes"; then ok "--notes-file is the notes file ($sh)"; else bad "--notes-file is not the notes file ($sh)" "$OUT"; fi
  if [ -e "$T/rec/notes-inline" ]; then bad "the notes were put on the command line ($sh)"; else ok "the notes are not on the command line ($sh)"; fi
  # #50: the block finds the binary and the .mcpb itself; nothing comes from an earlier block
  has "the binary is uploaded, found by the block itself ($sh)" "$(cat "$T/rec/create-args" 2>/dev/null)" "mcpb/server/Bin"
  has "…and the .mcpb ($sh)" "$(cat "$T/rec/create-args" 2>/dev/null)" "mcpb/proj.mcpb"
  pwned "method B ($sh)"
  same "both text files are removed once the release exists ($sh)" "$(left "$D")" ""
done
release_texts; export GH50_FAIL=1; run50 bash "$W" "$T/relB.sh"; unset GH50_FAIL
same "a failed gh release create keeps the text files for the retry" "$(left "$D")" "release-notes.md release-title.txt "

echo "mcp-deploy Step 4.5: repo description (#50)"
fence mcp-deploy "Step 4.5: 找不到 repo 描述檔" "$T/desc.sh" "gh repo edit {owner}/{repo} ==> gh repo edit o/r"
rm -f "$D"/*
run50 bash "$W" "$T/desc.sh"
has "no description file → stops" "$OUT" "找不到 repo 描述檔"
hasnt "…before gh repo edit" "$(cat "$T/rec/calls" 2>/dev/null)" "repo edit"
printf '%s\n' '{updated-description}' > "$D/repo-description.txt"
run50 bash "$W" "$T/desc.sh"
has "a description that was never filled in → stops" "$OUT" "描述是空的，或還沒代入"
hasnt "…before gh repo edit" "$(cat "$T/rec/calls" 2>/dev/null)" "repo edit"
printf '\n' > "$D/repo-description.txt"
run50 bash "$W" "$T/desc.sh"
has "an empty description → stops" "$OUT" "描述是空的，或還沒代入"
hasnt "…before gh repo edit" "$(cat "$T/rec/calls" 2>/dev/null)" "repo edit"
for sh in $SHELLS; do
  { hostile description; printf '\n'; } > "$D/repo-description.txt"
  run50 "$sh" "$W" "$T/desc.sh"
  same "the description is passed character for character ($sh)" "$(cat "$T/rec/description" 2>/dev/null)" "$(hostile description)"
  pwned "repo description ($sh)"
  same "the description file is removed afterwards ($sh)" "$(left "$D")" ""
done

echo "cli-deploy Step 2: release (#50)"
mk cli-rel; W="$T/cli-rel"; put "$W" README.md x; ci "$W"; push "$W"
git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
put "$W" .release/Bin x   # the universal binary of Phase 2 Step 3 (untracked, as in a real run)
D=$(deploy_dir "$W"); mkdir -p "$D"
fence cli-deploy 'releases" --method POST' "$T/relC.sh" "VERSION='{version}' ==> VERSION='1.4.0'" "BINARY_NAME='{binary}' ==> BINARY_NAME='Bin'"
run50 bash "$W" "$T/relC.sh"
has "no notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
for tok in release-notes 'CHANGELOG 內容' binary owner repo; do
  release_texts; rm -f "$D/release-title.txt"; printf '## Install\n\nx {%s} y\n' "$tok" > "$D/release-notes.md"
  run50 bash "$W" "$T/relC.sh"
  has "notes that still hold {$tok} → stops, and names it" "$OUT" "沒代入的 placeholder：{$tok}"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
done
release_texts; rm -f "$D/release-title.txt"; : > "$D/release-notes.md"
run50 bash "$W" "$T/relC.sh"
has "an empty notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
release_texts; rm -f "$D/release-title.txt"; export GH50_FAIL_VIEW=1; run50 bash "$W" "$T/relC.sh"; unset GH50_FAIL_VIEW
same "the check after the upload fails → the notes file is kept for the retry" "$(left "$D")" "release-notes.md "
release_texts; rm -f "$D/release-title.txt"; export GH50_ASSETS=""; run50 bash "$W" "$T/relC.sh"; unset GH50_ASSETS
has "the release does not hold the binary → stops" "$OUT" "release 上沒有 Bin"
same "…and the notes file is kept" "$(left "$D")" "release-notes.md "
# the block names the binary itself: {binary} left as it is stops it, even with a BINARY_NAME in the
# environment (that is how the old guard passed in this suite while every real run stopped there)
fence cli-deploy 'releases" --method POST' "$T/relC0.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
for sh in $SHELLS; do
  release_texts; rm -f "$D/release-title.txt"
  export BINARY_NAME=Bin; run50 "$sh" "$W" "$T/relC0.sh"; unset BINARY_NAME
  has "{binary} left in the block → stops, whatever the environment holds ($sh)" "$OUT" "✗ Step 2: BINARY_NAME 未代入或不合法"
  hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
  same "…and the notes file is kept ($sh)" "$(left "$D")" "release-notes.md "
done
# an empty name, a space, a double quote, a semicolon, a slash, a dollar sign, a backslash, a non-ASCII letter:
# the file is there (.release/../x is ./x), so only the guard stands in the way. Run under en_US.UTF-8 where
# the machine has it: /bin/bash 3.2 lets é through a [!A-Za-z] range there, so the guard lists its characters
UTF8_LOC=""; locale -a 2>/dev/null | grep -qx 'en_US.UTF-8' && UTF8_LOC=en_US.UTF-8
[ -n "$UTF8_LOC" ] || echo "  - en_US.UTF-8 is not installed: the guard cases run in the current locale only"
for name in '' 'B in' 'B"x' 'B;x' '../x' 'B$x' 'B\x' 'Bé'; do
  [ -z "$name" ] || put "$W" ".release/$name" x
  fence cli-deploy 'releases" --method POST' "$T/relCn.sh" "VERSION='{version}' ==> VERSION='1.4.0'" "BINARY_NAME='{binary}' ==> BINARY_NAME='$name'"
  for sh in $SHELLS; do
    release_texts; rm -f "$D/release-title.txt"
    SAVED_LC_ALL=${LC_ALL-__unset__}
    [ -z "$UTF8_LOC" ] || export LC_ALL="$UTF8_LOC"
    run50 "$sh" "$W" "$T/relCn.sh"
    if [ "$SAVED_LC_ALL" = __unset__ ]; then unset LC_ALL; else export LC_ALL="$SAVED_LC_ALL"; fi
    has "binary name [$name] → stops ($sh)" "$OUT" "✗ Step 2: BINARY_NAME 未代入或不合法"
    hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
    same "…and the notes file is kept ($sh)" "$(left "$D")" "release-notes.md "
  done
done
# a single quote ends the '…' of the assignment, so the case guard never sees the name: whatever follows the
# quote runs as code before the guard (a crafted name such as B'; cmd; echo ' does). That is why the skill says
# to check the name BEFORE substituting it. This case pins only what the shells do with the name B'x in this
# block (a syntax error before anything reaches gh); it is not a property of the guard
put "$W" ".release/B'x" x
fence cli-deploy 'releases" --method POST' "$T/relCq.sh" "VERSION='{version}' ==> VERSION='1.4.0'" "BINARY_NAME='{binary}' ==> BINARY_NAME='B'x'"
for sh in $SHELLS; do
  release_texts; rm -f "$D/release-title.txt"
  run50 "$sh" "$W" "$T/relCq.sh"
  same "binary name with a single quote → nothing reaches gh ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" ""
  same "…and the notes file is kept ($sh)" "$(left "$D")" "release-notes.md "
done
# a name that is not a file in .release: a binary that was never built, a directory
mkdir -p "$W/.release/Dir"
for name in Missing Dir; do
  fence cli-deploy 'releases" --method POST' "$T/relCn.sh" "VERSION='{version}' ==> VERSION='1.4.0'" "BINARY_NAME='{binary}' ==> BINARY_NAME='$name'"
  release_texts; rm -f "$D/release-title.txt"
  run50 bash "$W" "$T/relCn.sh"
  has "no regular file .release/$name → stops, and names it" "$OUT" "✗ Step 2: 找不到 .release/$name"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
  same "…and the notes file is kept" "$(left "$D")" "release-notes.md "
done
release_texts; rm -f "$D/release-title.txt"; export GH50_FAIL_POST=1; run50 bash "$W" "$T/relC.sh"; unset GH50_FAIL_POST
has "no release id → stops before any upload" "$OUT" "release 沒建成"
hasnt "…nothing was uploaded" "$(cat "$T/rec/calls" 2>/dev/null)" "curl"
for sh in $SHELLS; do
  release_texts; rm -f "$D/release-title.txt"
  run50 "$sh" "$W" "$T/relC.sh"
  same "the release is named v<version> ($sh)" "$(cat "$T/rec/name" 2>/dev/null)" "v1.4.0"
  if cmp -s "$T/rec/body-file" "$T/expected-notes"; then ok "the body is the notes file, byte for byte ($sh)"; else bad "the body is not the notes file ($sh)" "$OUT"; fi
  if [ -e "$T/rec/body-inline" ]; then bad "the notes were put on the command line ($sh)"; else ok "the notes are not on the command line ($sh)"; fi
  pwned "cli-deploy release ($sh)"
  same "the notes file is removed once the release exists ($sh)" "$(left "$D")" ""
done

echo "every token of the Release Notes template stops the release when it is left in the notes (#50)"
# the guard list is kept by hand in three blocks; this ties it to the template. Every other {token} is filled in, so only this one is left.
tpl_tokens() { python3 -I - "$PLUGIN_ROOT/skills/$1/SKILL.md" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
lines, inside = [], False
for l in t[t.index("Release Notes 模板"):].split("\n")[1:]:
    if not inside and l.startswith("```markdown"): inside = True; continue
    if inside and l == "```": break
    if inside: lines.append(l)
print("\n".join(sorted(set(re.findall(r"\{([^{}\n]+)\}", "\n".join(lines))))))
PY
}
tpl_notes() { python3 -I - "$PLUGIN_ROOT/skills/$1/SKILL.md" "$2" "$3" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
lines, inside = [], False
for l in t[t.index("Release Notes 模板"):].split("\n")[1:]:
    if not inside and l.startswith("```markdown"): inside = True; continue
    if inside and l == "```": break
    if inside: lines.append(l)
body = re.sub(r"\{([^{}\n]+)\}", lambda m: m.group(0) if m.group(1) == sys.argv[2] else "x", "\n".join(lines))
open(sys.argv[3], "w", encoding="utf-8").write(body + "\n")
PY
}
W="$T/mcp-rel"; D=$(deploy_dir "$W"); mkdir -p "$D"
tpl_tokens mcp-deploy > "$T/toks"
same "mcp-deploy: the template has tokens to check" "$([ -s "$T/toks" ] && echo yes)" "yes"
for blk in relA relB; do
  while IFS= read -r tok <&3; do
    release_texts; tpl_notes mcp-deploy "$tok" "$D/release-notes.md"
    run50 bash "$W" "$T/$blk.sh"
    has "mcp-deploy $blk: {$tok} left in the notes → stops" "$OUT" "沒代入的 placeholder"
    hasnt "…and nothing is released" "$(cat "$T/rec/calls" 2>/dev/null)" "release"
  done 3< "$T/toks"
done
W="$T/cli-rel"; D=$(deploy_dir "$W"); mkdir -p "$D"
tpl_tokens cli-deploy > "$T/toks"
same "cli-deploy: the template has tokens to check" "$([ -s "$T/toks" ] && echo yes)" "yes"
while IFS= read -r tok <&3; do
  release_texts; rm -f "$D/release-title.txt"; tpl_notes cli-deploy "$tok" "$D/release-notes.md"
  run50 bash "$W" "$T/relC.sh"
  has "cli-deploy: {$tok} left in the notes → stops" "$OUT" "沒代入的 placeholder"
  hasnt "…and nothing is released" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
done 3< "$T/toks"

echo "the asset gate: a project without a binary, and names that only start like the uploaded ones (#50)"
# Python and TypeScript projects keep only run.sh in mcpb/server, so BINARY_NAME is empty: only the .mcpb is uploaded and checked
mk mcp-py; W="$T/mcp-py"
put "$W" mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
put "$W" mcpb/server/run.sh x; put "$W" mcpb/proj.mcpb x
ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
D=$(deploy_dir "$W"); mkdir -p "$D"
release_texts; export GH50_ASSETS="proj.mcpb"; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
same "no binary, the .mcpb is on the release → the block succeeds" "$RC" "0"
same "…and the text files are removed" "$(left "$D")" ""
release_texts; export GH50_ASSETS=""; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
has "no binary, nothing on the release → names the .mcpb" "$OUT" "release 上沒有 proj.mcpb"
hasnt "…and does not name an empty file" "$OUT" "release 上沒有 ："
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
# method B in the same project: only the .mcpb is given to gh release create, not the directory mcpb/server/ (#50)
for sh in $SHELLS; do
  release_texts; run50 "$sh" "$W" "$T/relB.sh"
  same "method B, no binary: the assets are the .mcpb alone ($sh)" "$(sed -n '/^--notes-file$/,$p' "$T/rec/create-args" 2>/dev/null | sed '1,2d' | tr '\n' ' ')" "mcpb/proj.mcpb "
done
# nothing to upload at all: not even a .mcpb. An empty name must not pass as "found" (an empty asset list prints one empty line)
mk mcp-none; W="$T/mcp-none"
put "$W" mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
put "$W" mcpb/server/run.sh x
ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
D=$(deploy_dir "$W"); mkdir -p "$D"
release_texts; export GH50_ASSETS=""; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
has "no file name at all → stops, does not pass an empty name" "$OUT" "BINARY_NAME 與 MCPB_FILENAME 都是空的"
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
for sh in $SHELLS; do
  release_texts; run50 "$sh" "$W" "$T/relB.sh"
  has "method B, nothing to upload → stops ($sh)" "$OUT" "沒有任何要上傳的檔案"
  hasnt "…before gh release create ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
  same "…and the text files are kept ($sh)" "$(left "$D")" "release-notes.md release-title.txt "
done
# a release that only holds Bin.sha256 and proj.mcpb.sig does not hold Bin and proj.mcpb (whole-line match)
W="$T/mcp-rel"; D=$(deploy_dir "$W"); mkdir -p "$D"
release_texts; export GH50_ASSETS="Bin.sha256 proj.mcpb.sig"; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
has "mcp-deploy: names that only start with the uploaded ones → stops" "$OUT" "release 上沒有 Bin"
same "…and the text files are kept" "$(left "$D")" "release-notes.md release-title.txt "
W="$T/cli-rel"; D=$(deploy_dir "$W"); mkdir -p "$D"
release_texts; rm -f "$D/release-title.txt"; export GH50_ASSETS="Bin.sha256"; run50 bash "$W" "$T/relC.sh"; unset GH50_ASSETS
has "cli-deploy: a name that only starts like the binary → stops" "$OUT" "release 上沒有 Bin"
same "…and the notes file is kept" "$(left "$D")" "release-notes.md "

echo "mcp-deploy Step 4: which file in mcpb/server is the binary (#50, cross-model review round 2)"
# mcpsrv <name> <swift|other> <entry ...> — an mcp-deploy project with v1.4.0 tagged and a .mcpb; each entry is a
# file of mcpb/server, or a directory when it ends in /. A Swift project has Package.swift at the repository root
mcpsrv() {
  local n=$1 kind=$2 e; shift 2
  mk "$n"; W="$T/$n"
  put "$W" mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
  put "$W" mcpb/proj.mcpb x
  [ "$kind" = swift ] && put "$W" Package.swift '// swift-tools-version:5.9'
  for e in "$@"; do
    case "$e" in */) put "$W" "mcpb/server/${e}inside" x ;; *) put "$W" "mcpb/server/$e" x ;; esac
  done
  ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
  D=$(deploy_dir "$W"); mkdir -p "$D"
}
# method B: the assets given to gh release create (what follows --notes-file and its value)
assetsB() { sed -n '/^--notes-file$/,$p' "$T/rec/create-args" 2>/dev/null | sed '1,2d' | tr '\n' ' '; }
# names the old grep -v '.sh' dropped ('.' is any character, nothing anchored); a binary that sorts after run.sh
for BIN in flash publish-tool tool; do
  mcpsrv "mcp-bin-$BIN" swift "$BIN" run.sh .gitkeep
  release_texts; export GH50_ASSETS="$BIN proj.mcpb"; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
  has "method A: a binary named $BIN is uploaded" "$(cat "$T/rec/curl-args" 2>/dev/null)" "assets?name=$BIN --data-binary @mcpb/server/$BIN"
  hasnt "…run.sh is not taken for the binary" "$(cat "$T/rec/curl-args" 2>/dev/null)" "run.sh"
  same "…and the release is complete: the text files are removed" "$(left "$D")" ""
  for sh in $SHELLS; do
    release_texts; run50 "$sh" "$W" "$T/relB.sh"
    same "method B: a binary named $BIN is uploaded with the .mcpb ($sh)" "$(assetsB)" "mcpb/server/$BIN mcpb/proj.mcpb "
  done
done
# a Swift project whose mcpb/server holds no binary (only run.sh, .gitkeep and a directory): no release at all
mcpsrv mcp-swift-nobin swift run.sh .gitkeep lib/
for sh in $SHELLS; do
  release_texts; run50 "$sh" "$W" "$T/relB.sh"
  has "method B: a Swift project without a binary → stops ($sh)" "$OUT" "✗ Step 4: 這是 Swift 專案（有 Package.swift），mcpb/server 裡卻沒有 binary"
  hasnt "…before gh release create ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
  same "…and the text files are kept ($sh)" "$(left "$D")" "release-notes.md release-title.txt "
  release_texts; run50 "$sh" "$W" "$T/relA.sh"
  has "method A: a Swift project without a binary → stops ($sh)" "$OUT" "✗ Step 4: 這是 Swift 專案（有 Package.swift），mcpb/server 裡卻沒有 binary"
  hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "/releases"
  same "…and the text files are kept ($sh)" "$(left "$D")" "release-notes.md release-title.txt "
done
# the mcp server in a subdirectory of the repository, Package.swift only at the repository root: still a Swift
# project (the block looks in the current directory and at the repository root)
mk mcp-swift-sub; W="$T/mcp-swift-sub"
put "$W" Package.swift '// swift-tools-version:5.9'
put "$W" srv/mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
put "$W" srv/mcpb/proj.mcpb x
put "$W" srv/mcpb/server/run.sh x
ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
D=$(deploy_dir "$W"); mkdir -p "$D"
for sh in $SHELLS; do
  release_texts; run50 "$sh" "$W/srv" "$T/relB.sh"
  has "method B: run from a subdirectory, Package.swift at the repository root, no binary → stops ($sh)" "$OUT" "✗ Step 4: 這是 Swift 專案（有 Package.swift），mcpb/server 裡卻沒有 binary"
  hasnt "…before gh release create ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
  release_texts; run50 "$sh" "$W/srv" "$T/relA.sh"
  has "method A: run from a subdirectory, Package.swift at the repository root, no binary → stops ($sh)" "$OUT" "✗ Step 4: 這是 Swift 專案（有 Package.swift），mcpb/server 裡卻沒有 binary"
  hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "/releases"
done
# a project that is not Swift, with run.sh and a directory in mcpb/server: the directory is not a binary, only the .mcpb goes up
mcpsrv mcp-node-nobin other run.sh node_modules/
for sh in $SHELLS; do
  release_texts; run50 "$sh" "$W" "$T/relB.sh"
  same "method B: not Swift, no binary file → only the .mcpb is uploaded ($sh)" "$(assetsB)" "mcpb/proj.mcpb "
done
release_texts; export GH50_ASSETS="proj.mcpb"; run50 bash "$W" "$T/relA.sh"; unset GH50_ASSETS
hasnt "method A: not Swift, no binary file → the directory is not uploaded" "$(cat "$T/rec/curl-args" 2>/dev/null)" "node_modules"
has "…the .mcpb is" "$(cat "$T/rec/curl-args" 2>/dev/null)" "@mcpb/proj.mcpb"
same "…and the release is complete: the text files are removed" "$(left "$D")" ""

echo "a remote URL that still has the repository's old name (#53)"
# After a rename or a transfer GitHub redirects git and the API calls that were tried, but
# the asset upload host was not confirmed to follow, and an upload that fails leaves a
# release with no assets. So every block that talks to the API first asks GitHub for the
# repository's current name and uses that from there on. "o/r" is the current name;
# GH_STUB_OLD_NAME is the former one. A former name under the same owner (o/name) is a rename and
# the blocks go on; a former name under another owner (old/name) is a transfer and they stop
# (maintainer decision on #53, 2026-11-16).
for SK in mcp-deploy:3a cli-deploy:1.5; do
  S=${SK%%:*}; STEP=${SK#*:}
  mk "$S-renamed" "https://github.com/o/name.git"; W="$T/$S-renamed"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  fence "$S" "Step $STEP: VERSION" "$T/ren.sh" "VERSION='{version}' ==> VERSION='1.0.0'"
  # the needle is the new message itself: the block has other messages that say 讀不到
  NONAME="✗ Step $STEP: 讀不到 o/name 在 GitHub 上的正式名稱"
  export GH_STUB_NO_NAME=1
  run bash "$W" "$T/ren.sh"
  has "$S: the current name cannot be read → stops" "$OUT" "$NONAME"
  same "$S: …before any tag is pushed" "$(rtag "$T/$S-renamed.git" v1.0.0)" ""
  unset GH_STUB_NO_NAME
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/ren.sh"
    has "$S: a name GitHub does not know (gh prints the 404 body) → stops ($sh)" "$OUT" "$NONAME"
    same "$S: …before any tag is pushed ($sh)" "$(rtag "$T/$S-renamed.git" v1.0.0)" ""
  done
  export GH_STUB_MULTILINE=1
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/ren.sh"
    has "$S: an answer of several lines, the first a clean name → stops ($sh)" "$OUT" "$NONAME"
    same "$S: …before any tag is pushed ($sh)" "$(rtag "$T/$S-renamed.git" v1.0.0)" ""
  done
  unset GH_STUB_MULTILINE
  export GH_STUB_OLD_NAME=o/name
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/ren.sh"
    has "$S: the old name in the URL, same owner (a rename) → goes on under the current name ($sh)" "$OUT" "→ Step $STEP: v1.0.0 已在 o/r"
    has "$S: …and says the URL has the old name ($sh)" "$OUT" "舊名稱 o/name"
  done
  same "$S: …and v1.0.0 is on HEAD" "$(rtag "$T/$S-renamed.git" v1.0.0)" "$(git -C "$W" rev-parse HEAD)"
  unset GH_STUB_OLD_NAME
  # a transfer: the URL's owner is not the owner GitHub answers with → stops before the tag. The URL
  # carries a token, and the message names the two names, never the URL
  mk "$S-moved" "https://user:sekret@github.com/old/name.git"; W="$T/$S-moved"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  export GH_STUB_OLD_NAME=old/name
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/ren.sh"
    has "$S: the repository was transferred to another owner → stops ($sh)" "$OUT" "✗ Step $STEP: remote 的網址指的是 old/name，GitHub 上這個 repo 現在是 o/r：repo 已經轉移到別的 owner"
    has "$S: …says the release would be created under the new owner ($sh)" "$OUT" "release 會建在 o/r 底下"
    has "$S: …and to confirm, change the URL and run the step again ($sh)" "$OUT" "確認這就是要發版的 repo 之後，用 git remote set-url origin <新的網址> 把網址的 owner/repo 改成 o/r ，再重跑這一步"
    hasnt "$S: …without printing the URL ($sh)" "$OUT" "sekret"
    hasnt "$S: …and does not hand over to the release step ($sh)" "$OUT" "已在 o/r"
  done
  same "$S: …and no tag on the remote" "$(rtag "$T/$S-moved.git" v1.0.0)" ""
  unset GH_STUB_OLD_NAME
  mk "$S-case" "https://github.com/O/R.git"; W="$T/$S-case"
  put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'; ci "$W"; push "$W"
  run bash "$W" "$T/ren.sh"
  has "$S: a URL that differs from the current name only in case → goes on" "$OUT" "→ Step $STEP: v1.0.0 已在 o/r"
  hasnt "$S: …and is not called an old name" "$OUT" "舊名稱"
done
# the release blocks: the API call, the uploads and gh release create all get the current name
# mcprel <name> <url> — an mcp-deploy project with v1.4.0 tagged and both assets built
mcprel() {
  mk "$1" "$2"; W="$T/$1"
  put "$W" mcpb/manifest.json '{
  "name": "proj",
  "version": "1.4.0"
}'
  put "$W" mcpb/server/Bin x; put "$W" mcpb/proj.mcpb x
  ci "$W"; push "$W"; git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
  D=$(deploy_dir "$W"); mkdir -p "$D"
}
mcprel mcp-rel-old "https://github.com/o/name.git"
NONAME="✗ Step 4: 讀不到 o/name 在 GitHub 上的正式名稱"
# three ways the name cannot be had: gh fails with nothing on stdout (not logged in), gh prints
# the body of a 404 (a name GitHub does not know), an answer of several lines
for HOW in "GH_STUB_NO_NAME:the current name cannot be read" "-:a name GitHub does not know" "GH_STUB_MULTILINE:an answer of several lines"; do
  VAR=${HOW%%:*}; WHAT=${HOW#*:}
  [ "$VAR" = - ] || export "$VAR=1"
  release_texts
  run50 bash "$W" "$T/relA.sh"
  has "method A: $WHAT → stops" "$OUT" "$NONAME"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "/releases"
  hasnt "…and nothing of the answer became an argument" "$(cat "$T/rec/calls" 2>/dev/null)" "attacker"
  run50 bash "$W" "$T/relB.sh"
  has "method B: $WHAT → stops" "$OUT" "$NONAME"
  hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
  [ "$VAR" = - ] || unset "$VAR"
done
export GH_STUB_OLD_NAME=o/name
for sh in $SHELLS; do
  release_texts
  run50 "$sh" "$W" "$T/relA.sh"
  has "method A: a rename under the same owner → the release is created under the current name ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
  hasnt "…never under the old one ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "repos/o/name/"
  has "…and the assets are uploaded to the current name ($sh)" "$(cat "$T/rec/curl-args" 2>/dev/null)" "uploads.github.com/repos/o/r/releases/"
  hasnt "…never to the old one ($sh)" "$(cat "$T/rec/curl-args" 2>/dev/null)" "o/name"
  # gh release view decides whether the text files are deleted: it has to look at the same repository
  same "…and every gh release view is given the current name ($sh)" "$(sort -u "$T/rec/repos" 2>/dev/null)" "o/r"
  has "…and the block says the URL has the old name ($sh)" "$OUT" "→ Step 4: remote 的網址用的是舊名稱 o/name"
  release_texts
  run50 "$sh" "$W" "$T/relB.sh"
  same "method B: gh release create and gh release view are given the current name ($sh)" "$(sort -u "$T/rec/repos" 2>/dev/null)" "o/r"
  has "…and the block says the URL has the old name ($sh)" "$OUT" "→ Step 4: remote 的網址用的是舊名稱 o/name"
done
unset GH_STUB_OLD_NAME
# a transfer (another owner) stops both methods before the release; the URL carries a token that is never printed
mcprel mcp-rel-moved "https://user:sekret@github.com/old/name.git"
export GH_STUB_OLD_NAME=old/name
for sh in $SHELLS; do
  for blk in relA relB; do
    release_texts
    run50 "$sh" "$W" "$T/$blk.sh"
    has "$blk: the repository was transferred to another owner → stops ($sh)" "$OUT" "✗ Step 4: remote 的網址指的是 old/name，GitHub 上這個 repo 現在是 o/r：repo 已經轉移到別的 owner"
    has "…says the release would be created under the new owner, and how to go on ($sh)" "$OUT" "release 會建在 o/r 底下 — 停止，不建 release，文字檔保留。確認這就是要發版的 repo 之後，用 git remote set-url <remote> <新的網址>"
    hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "release"
    hasnt "…and nothing is uploaded ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "curl"
    hasnt "…without printing the URL ($sh)" "$OUT" "sekret"
    same "…and the text files are kept ($sh)" "$(left "$D")" "release-notes.md release-title.txt "
  done
done
unset GH_STUB_OLD_NAME
# an owner that differs only in case is the same owner: the release goes on, under the name GitHub gives
mcprel mcp-rel-case "https://github.com/O/r.git"
release_texts; run50 bash "$W" "$T/relA.sh"
has "method A: an owner that differs only in case → the release is created under the current name" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
hasnt "…and it is not called a transfer" "$OUT" "轉移"
release_texts; run50 bash "$W" "$T/relB.sh"
same "method B: an owner that differs only in case → gh release create under the current name" "$(cat "$T/rec/repo" 2>/dev/null)" "o/r"
has "…and the release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
hasnt "…and it is not called a transfer" "$OUT" "轉移"
mk cli-rel-old "https://github.com/o/name.git"; W="$T/cli-rel-old"; put "$W" README.md x; ci "$W"; push "$W"
git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
put "$W" .release/Bin x
D=$(deploy_dir "$W"); mkdir -p "$D"
NONAME="✗ Step 2: 讀不到 o/name 在 GitHub 上的正式名稱"
for HOW in "GH_STUB_NO_NAME:the current name cannot be read" "-:a name GitHub does not know" "GH_STUB_MULTILINE:an answer of several lines"; do
  VAR=${HOW%%:*}; WHAT=${HOW#*:}
  [ "$VAR" = - ] || export "$VAR=1"
  release_texts; rm -f "$D/release-title.txt"
  run50 bash "$W" "$T/relC.sh"
  has "cli-deploy Step 2: $WHAT → stops" "$OUT" "$NONAME"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "/releases"
  hasnt "…and before the tag is looked up under a name that was not confirmed" "$(cat "$T/rec/calls" 2>/dev/null)" "git/ref/tags"
  [ "$VAR" = - ] || unset "$VAR"
done
export GH_STUB_OLD_NAME=o/name
for sh in $SHELLS; do
  release_texts; rm -f "$D/release-title.txt"
  run50 "$sh" "$W" "$T/relC.sh"
  has "cli-deploy Step 2: a rename under the same owner → the release is created under the current name ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
  hasnt "…never under the old one ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "repos/o/name/"
  has "…and the binary is uploaded to the current name ($sh)" "$(cat "$T/rec/curl-args" 2>/dev/null)" "uploads.github.com/repos/o/r/releases/"
  hasnt "…never to the old one ($sh)" "$(cat "$T/rec/curl-args" 2>/dev/null)" "o/name"
  same "…and every gh release view is given the current name ($sh)" "$(sort -u "$T/rec/repos" 2>/dev/null)" "o/r"
  has "…and the block says the URL has the old name ($sh)" "$OUT" "→ Step 2: remote 的網址用的是舊名稱 o/name"
done
unset GH_STUB_OLD_NAME
# cli-deploy Step 2: a transfer stops before the release; an owner that differs only in case goes on
for CASE in "cli-rel-moved|https://user:sekret@github.com/old/name.git|old/name" "cli-rel-case|https://github.com/O/r.git|-"; do
  NM=${CASE%%|*}; REST=${CASE#*|}; URL=${REST%%|*}; OLD=${REST#*|}
  mk "$NM" "$URL"; W="$T/$NM"; put "$W" README.md x; ci "$W"; push "$W"
  git -C "$W" tag -a v1.4.0 -m x; git -C "$W" push -q origin refs/tags/v1.4.0
  put "$W" .release/Bin x
  D=$(deploy_dir "$W"); mkdir -p "$D"
  [ "$OLD" = - ] || export GH_STUB_OLD_NAME="$OLD"
  for sh in $SHELLS; do
    release_texts; rm -f "$D/release-title.txt"
    run50 "$sh" "$W" "$T/relC.sh"
    if [ "$OLD" = - ]; then
      has "cli-deploy Step 2: an owner that differs only in case → the release is created under the current name ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
      hasnt "…and it is not called a transfer ($sh)" "$OUT" "轉移"
    else
      has "cli-deploy Step 2: the repository was transferred to another owner → stops ($sh)" "$OUT" "✗ Step 2: remote 的網址指的是 old/name，GitHub 上這個 repo 現在是 o/r：repo 已經轉移到別的 owner"
      has "…says the release would be created under the new owner, and how to go on ($sh)" "$OUT" "release 會建在 o/r 底下 — 停止，不建 release，文字檔保留。確認這就是要發版的 repo 之後，用 git remote set-url <remote> <新的網址>"
      hasnt "…before any release is created ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "releases"
      hasnt "…and nothing is uploaded ($sh)" "$(cat "$T/rec/calls" 2>/dev/null)" "curl"
      hasnt "…without printing the URL ($sh)" "$OUT" "sekret"
      same "…and the notes file is kept ($sh)" "$(left "$D")" "release-notes.md "
    fi
  done
  unset GH_STUB_OLD_NAME
done

echo "the release commit is checked before it is pushed (#51)"
rmain() { git --git-dir="$1" rev-parse -q --verify "refs/heads/${2:-main}" 2>/dev/null; }
for SM in "mcp-deploy:Step 3:3a" "cli-deploy:Step 1 推送:1.5"; do
  S=${SM%%:*}; REST=${SM#*:}; STEP=${REST%%:*}; NEXT=${REST#*:}
  mk "$S-pre"; W="$T/$S-pre"; B="$T/$S-pre.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"
  BASE=$(git -C "$W" rev-parse HEAD)
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release

  # the version files disagree with the release → nothing is pushed
  fence "$S" "推送前檢查（#51）" "$T/pre150.sh" "VERSION='{version}' ==> VERSION='1.5.0'"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/pre150.sh"
    has "$S: the files say 1.4.1, the release is 1.5.0 → stops ($sh)" "$OUT" "✗ $STEP: 版本檔與 1.5.0 不一致"
    same "$S: …and the release commit stays local ($sh)" "$(rmain "$B")" "$BASE"
  done
  if [ "$S" = mcp-deploy ]; then
    has "$S: …and it says the .mcpb has to be packed again" "$OUT" "重新打包"
    has "$S: …and that a compiled-in file means building again first" "$OUT" "Phase 1 A2 重新編譯"
  else
    has "$S: …and that a compiled-in file means building again" "$OUT" "Phase 2 要重新 build"
  fi
  has "$S: …a new commit is what fixes it" "$OUT" "補一個 commit"
  same "$S: …and the check created no tag" "$(git -C "$W" tag -l)" ""

  # the tag name is taken by another commit → nothing is pushed
  git -C "$W" tag -a v1.4.1 -m x "$BASE"; git -C "$W" push -q origin refs/tags/v1.4.1
  fence "$S" "推送前檢查（#51）" "$T/pre141.sh" "VERSION='{version}' ==> VERSION='1.4.1'"
  run bash "$W" "$T/pre141.sh"
  has "$S: v1.4.1 already sits on another commit → stops" "$OUT" "✗ $STEP: v1.4.1 已在別的 commit 上"
  has "$S: …and points at a leftover local tag too" "$OUT" "git tag -l v1.4.1"
  same "$S: …and the release commit stays local" "$(rmain "$B")" "$BASE"
  git -C "$W" push -q origin :refs/tags/v1.4.1; git -C "$W" tag -d v1.4.1 >/dev/null

  # the helper cannot be found → nothing is pushed
  OUT=$(cd "$W" && PATH="$T/bin:$PATH" CLAUDE_PLUGIN_ROOT="$T/no-plugin" bash "$T/pre141.sh" 2>&1)
  has "$S: helper not found → stops" "$OUT" "✗ $STEP: 找不到"
  same "$S: …and the release commit stays local" "$(rmain "$B")" "$BASE"

  # someone else pushed first → the push is refused, and the block says so
  git -C "$W" checkout -q --detach "$BASE"; put "$W" other.txt x; ci "$W" theirs
  THEIRS=$(git -C "$W" rev-parse HEAD); git -C "$W" push -q origin "$THEIRS:refs/heads/main"; git -C "$W" checkout -q main
  run bash "$W" "$T/pre141.sh"
  has "$S: the remote moved on → the push is refused and the block stops" "$OUT" "✗ $STEP: 推送失敗"
  same "$S: …and the remote keeps the other commit" "$(rmain "$B")" "$THEIRS"
  git -C "$W" push -q -f origin "$BASE:refs/heads/main"; git -C "$W" fetch -q origin

  # nothing in the way → pushed, and the tag step takes over. push.followTags is on and an
  # annotated tag that the remote does not have sits on an earlier commit: the push of the
  # release commit must not take it along
  git -C "$W" config push.followTags true; git -C "$W" tag -a unrelated -m x "$BASE"
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/pre141.sh"
    has "$S: nothing in the way → pushed ($sh)" "$OUT" "→ $STEP: release commit 已推到"
  done
  has "$S: …the commits that go along are printed first" "$OUT" "這次會推到 origin 的 main 的 commit"
  same "$S: the remote branch is the release commit" "$(rmain "$B")" "$(git -C "$W" rev-parse HEAD)"
  same "$S: the push took no tag along, and the check created none" "$(git --git-dir="$B" tag -l)" ""
  git -C "$W" tag -d unrelated >/dev/null; git -C "$W" config --unset push.followTags
  fence "$S" "Step $NEXT: VERSION" "$T/tag141.sh" "VERSION='{version}' ==> VERSION='1.4.1'"
  run bash "$W" "$T/tag141.sh"
  has "$S: Step $NEXT then tags the pushed commit" "$OUT" "→ Step $NEXT: v1.4.1 已在 o/r"

  # a branch with no upstream, and one that tracks a branch other than the default → nothing is pushed
  git -C "$W" checkout -q -b feature; put "$W" mcpb/manifest.json '{ "version": "1.4.2" }'; ci "$W" next
  fence "$S" "推送前檢查（#51）" "$T/pre142.sh" "VERSION='{version}' ==> VERSION='1.4.2'"
  run bash "$W" "$T/pre142.sh"
  has "$S: a branch without an upstream → stops" "$OUT" "沒有指向 remote 的 upstream"
  same "$S: …and nothing reaches the remote" "$(rmain "$B" feature)" ""
  # #51 (cross-model review, 2026-11-16): the advice must not be a push that skips these checks
  hasnt "$S: …and does not suggest git push -u" "$OUT" "git push -u"
  has "$S: …it says not to push directly" "$OUT" "不要直接 git push：那樣會跳過這裡的檢查"
  has "$S: …a branch the remote has: set the upstream and run this step again" "$OUT" "git fetch <remote> ，再 git branch --set-upstream-to=<remote>/feature ，然後重跑這一步"
  has "$S: …a branch the remote does not have: push the commit before the release commit, without tags" "$OUT" "git push --no-follow-tags <remote> HEAD~1:refs/heads/feature ，再 git branch --set-upstream-to=<remote>/feature ，然後重跑這一步"
  git -C "$W" push -q -u origin feature 2>/dev/null; FEAT=$(rmain "$B" feature)
  put "$W" mcpb/manifest.json '{ "version": "1.4.3" }'; ci "$W" next2
  fence "$S" "推送前檢查（#51）" "$T/pre143.sh" "VERSION='{version}' ==> VERSION='1.4.3'"
  run bash "$W" "$T/pre143.sh"
  has "$S: a branch that tracks a non-default branch → stops" "$OUT" "不是預設 branch"
  same "$S: …and nothing new reaches the remote" "$(rmain "$B" feature)" "$FEAT"

  # a remote that is not on github.com → nothing is pushed
  mk "$S-ghe" https://ghe.example.com/o/r.git; W="$T/$S-ghe"; B="$T/$S-ghe.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"; BASE=$(git -C "$W" rev-parse HEAD)
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  run bash "$W" "$T/pre141.sh"
  has "$S: a remote outside github.com → stops" "$OUT" "推不出 github.com 的 owner/repo"
  same "$S: …and the release commit stays local" "$(rmain "$B")" "$BASE"

  # #51: the advice for a new repository, followed as printed. An empty remote, a base commit and the
  # release commit, no upstream: push HEAD~1, set the upstream, run the step again → it pushes, checked
  git init -q --bare -b main "$T/$S-new.git"; git init -q -b main "$T/$S-new"; W="$T/$S-new"; B="$T/$S-new.git"
  git -C "$W" config "url.$B.insteadOf" https://github.com/o/r.git; git -C "$W" remote add origin https://github.com/o/r.git
  export GH_STUB_REMOTE="$B"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W" base
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  run bash "$W" "$T/pre141.sh"
  has "$S: a new repository, no upstream → stops" "$OUT" "沒有指向 remote 的 upstream"
  same "$S: …and the remote is still empty" "$(git --git-dir="$B" for-each-ref --format=x | wc -l | tr -d ' ')" 0
  ADVICE=$(printf '%s' "$OUT" | python3 -I -c 'import re, sys
t = sys.stdin.read().split("新的 repo", 1)[-1]
cmds = re.findall(r"git push --no-follow-tags <remote> HEAD~1:refs/heads/[A-Za-z0-9._/-]+|git branch --set-upstream-to=<remote>/[A-Za-z0-9._/-]+", t)
print("\n".join(c.replace("<remote>", "origin") for c in cmds))')
  same "$S: …the advice for a new repository has two commands" "$(printf '%s\n' "$ADVICE" | grep -c .)" 2
  STEPS_OK=yes
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    ( cd "$W" && eval "$cmd" ) >/dev/null 2>&1 || STEPS_OK="failed: $cmd"
  done <<< "$ADVICE"
  same "$S: …both run as printed (the push makes origin/main, so the upstream can be set)" "$STEPS_OK" yes
  same "$S: …the remote now has the commit before the release commit" "$(rmain "$B")" "$(git -C "$W" rev-parse HEAD~1)"
  run bash "$W" "$T/pre141.sh"
  has "$S: …and the step, run again, checks and pushes the release commit" "$OUT" "→ $STEP: release commit 已推到"
  same "$S: …the remote branch is the release commit" "$(rmain "$B")" "$(git -C "$W" rev-parse HEAD)"
  same "$S: …and no tag went along" "$(git --git-dir="$B" tag -l)" ""

  # #53: the tag step asks GitHub for the repository's current name. A name GitHub does not
  # know shows before the push; a former name that still redirects does not stand in the way
  mk "$S-gone" https://github.com/gone/repo.git; W="$T/$S-gone"; B="$T/$S-gone.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"; BASE=$(git -C "$W" rev-parse HEAD)
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  run bash "$W" "$T/pre141.sh"
  has "$S: a name GitHub does not know → stops" "$OUT" "✗ $STEP: 讀不到 gone/repo 在 GitHub 上的正式名稱"
  same "$S: …and the release commit stays local" "$(rmain "$B")" "$BASE"
  mk "$S-preold" https://github.com/o/name.git; W="$T/$S-preold"; B="$T/$S-preold.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  export GH_STUB_OLD_NAME=o/name
  run bash "$W" "$T/pre141.sh"
  has "$S: a former name under the same owner that redirects (a rename) → the push goes on" "$OUT" "→ $STEP: release commit 已推到"
  same "$S: …and the remote branch is the release commit" "$(rmain "$B")" "$(git -C "$W" rev-parse HEAD)"
  unset GH_STUB_OLD_NAME
  # #53, 2026-11-16: a transfer to another owner stops before the push; the URL carries a token that is never printed
  mk "$S-premoved" https://user:sekret@github.com/old/name.git; W="$T/$S-premoved"; B="$T/$S-premoved.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"; BASE=$(git -C "$W" rev-parse HEAD)
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  export GH_STUB_OLD_NAME=old/name
  for sh in $SHELLS; do
    run "$sh" "$W" "$T/pre141.sh"
    has "$S: the repository was transferred to another owner → stops before the push ($sh)" "$OUT" "✗ $STEP: remote 的網址指的是 old/name，GitHub 上這個 repo 現在是 o/r：repo 已經轉移到別的 owner"
    has "$S: …says the release would be created under the new owner, and how to go on ($sh)" "$OUT" "release 會建在 o/r 底下 — 停止，不推送。確認這就是要發版的 repo 之後，用 git remote set-url origin <新的網址> 把網址的 owner/repo 改成 o/r ，再重跑這一步"
    hasnt "$S: …without printing the URL ($sh)" "$OUT" "sekret"
    same "$S: …and the release commit stays local ($sh)" "$(rmain "$B")" "$BASE"
  done
  unset GH_STUB_OLD_NAME
  # an owner that differs only in case is the same owner: the push goes on
  mk "$S-precase" https://github.com/O/r.git; W="$T/$S-precase"; B="$T/$S-precase.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  run bash "$W" "$T/pre141.sh"
  has "$S: an owner that differs only in case → the push goes on" "$OUT" "→ $STEP: release commit 已推到"
  same "$S: …and the remote branch is the release commit" "$(rmain "$B")" "$(git -C "$W" rev-parse HEAD)"

  # the checks that stand between the block and an irreversible push, one at a time (#51 verify R1):
  # each case leaves the remote's main where it was
  mk "$S-x"; W="$T/$S-x"; B="$T/$S-x.git"
  put "$W" mcpb/manifest.json '{ "version": "1.4.0" }'; ci "$W"; push "$W"; BASE=$(git -C "$W" rev-parse HEAD)
  put "$W" mcpb/manifest.json '{ "version": "1.4.1" }'; ci "$W" release
  stays() { same "$S: …and the remote's main did not move" "$(rmain "$B")" "$BASE"; }
  # VERSION not filled in, or not made of the allowed characters
  fence "$S" "推送前檢查（#51）" "$T/prenov.sh"
  run bash "$W" "$T/prenov.sh"
  has "$S: VERSION still the placeholder → stops" "$OUT" "VERSION 未代入或不合法"; stays
  fence "$S" "推送前檢查（#51）" "$T/prebad.sh" "VERSION='{version}' ==> VERSION='1.4.1;x'"
  run bash "$W" "$T/prebad.sh"
  has "$S: VERSION with a character outside the list → stops" "$OUT" "VERSION 未代入或不合法"; stays
  # #53: gh cannot tell the repository's name (not logged in; an answer of several lines). The tag
  # step would stop on it, and it shows before the push, so the release commit must not leave
  for HOW in "GH_STUB_NO_NAME:gh cannot read the repository's name" "GH_STUB_MULTILINE:an answer of several lines"; do
    VAR=${HOW%%:*}; WHAT=${HOW#*:}
    export "$VAR=1"
    for sh in $SHELLS; do
      run "$sh" "$W" "$T/pre141.sh"
      has "$S: $WHAT → stops before the push ($sh)" "$OUT" "✗ $STEP: 讀不到 o/r 在 GitHub 上的正式名稱"; stays
    done
    unset "$VAR"
  done
  # a detached HEAD, an upstream that is a local branch, an upstream remote that is not configured
  git -C "$W" checkout -q --detach
  run bash "$W" "$T/pre141.sh"
  has "$S: a detached HEAD → stops" "$OUT" "沒有指向 remote 的 upstream"; stays
  git -C "$W" checkout -q main
  git -C "$W" checkout -q -b local-up main; git -C "$W" config branch.local-up.remote .; git -C "$W" config branch.local-up.merge refs/heads/main
  run bash "$W" "$T/pre141.sh"
  has "$S: an upstream that is a local branch → stops" "$OUT" "沒有指向 remote 的 upstream"; stays
  git -C "$W" checkout -q main; git -C "$W" branch -q -D local-up
  git -C "$W" config branch.main.remote ghost
  run bash "$W" "$T/pre141.sh"
  has "$S: an upstream remote that is not configured → stops" "$OUT" "不是這個 repo 設定過的 remote 名稱"; stays
  git -C "$W" config branch.main.remote origin
  # a feature branch cut from origin/main: its upstream is the default branch, its name is not
  git -C "$W" checkout -q -b featx main; git -C "$W" branch -q --set-upstream-to=origin/main featx
  run bash "$W" "$T/pre141.sh"
  has "$S: a branch that tracks the default branch under another name → stops" "$OUT" "名稱不同"; stays
  git -C "$W" checkout -q main; git -C "$W" branch -q -D featx
  # the default branch cannot be read: the block must stop, and say it is the connection
  OLDURL=$(git -C "$W" config --get remote.origin.url)   # the written one; get-url would give the rewritten path
  git -C "$W" config --unset "url.$T/$S-x.git.insteadOf"; git -C "$W" remote set-url origin "$T/no-such-remote.git"
  run bash "$W" "$T/pre141.sh"
  has "$S: the default branch cannot be read → stops" "$OUT" "讀不到 origin 的預設 branch"
  hasnt "$S: …and does not blame the branch it tracks" "$OUT" "不是預設 branch"
  git -C "$W" remote set-url origin "$OLDURL"; git -C "$W" config "url.$T/$S-x.git.insteadOf" "$OLDURL"; stays
  # the helper's own exits: 21 (a version source that cannot be read), 30 (the push URL is another repository)
  put "$W" Sources/App/Version.swift 'enum V { static let version = makeVersion() }'; ci "$W" unreadable
  run bash "$W" "$T/pre141.sh"
  has "$S: a version source that cannot be read (21) → stops" "$OUT" "有版本檔讀不出值"
  # #51 (cross-model review, 2026-11-16): 21 is the environment or a file in the commit; the message covers both
  has "$S: …an environment problem: fix it and run again, no new commit" "$OUT" "原因是環境時（讀 pyproject.toml 需要 python3 3.11 以上，或 tomli）：修好環境後重跑這一步，不需要新的 commit"
  has "$S: …a version source in the commit: change it and make a new commit" "$OUT" "原因是 commit 裡的某個版本來源讀不出值時：改那個檔案，補一個 commit，再重跑這一步"
  if [ "$S" = mcp-deploy ]; then
    has "$S: …and build and pack again when the file is compiled in" "$OUT" "Swift 專案要先從 Phase 1 A2 重新編譯，再從 Phase 2 Step 5 重新打包 .mcpb"
  else
    has "$S: …and build again when the file is compiled in" "$OUT" "Phase 2 要重新 build"
  fi
  stays
  git -C "$W" reset -q --hard HEAD~1
  git -C "$W" config remote.origin.pushurl git@github.com:o/other.git
  run bash "$W" "$T/pre141.sh"
  has "$S: a push URL on another repository (30) → stops" "$OUT" "push URL 指向別的 repo"
  has "$S: …and says no new commit is needed" "$OUT" "不需要新的 commit"; stays
  git -C "$W" config --unset remote.origin.pushurl
done
fence mcp-deploy "Step 2: VERSION" "$T/blk.sh"
hasnt "mcp-deploy: the commit block does not push" "$(cat "$T/blk.sh")" 'git push'
fence cli-deploy "Phase 3 Step 1: stage" "$T/blk.sh"
hasnt "cli-deploy: the commit block does not push" "$(cat "$T/blk.sh")" 'git push'
for s in mcp-deploy cli-deploy; do
  fence "$s" "推送前檢查（#51）" "$T/blk.sh"
  hasnt "$s: the push goes to the checked upstream, not to a hard-coded origin main" "$(cat "$T/blk.sh")" 'origin main'
done

echo "cli-deploy Phase 1 Step 0: no uncommitted change in a version file or README.md before the bump (#52)"
# Phase 3 Step 1 stages every listed file that is modified; it cannot tell a change this
# deploy made from one that was already sitting in the work tree. So the check runs
# BEFORE Phase 1 edits anything: a listed file (or README.md) that already has an
# uncommitted change stops the run. CHANGELOG.md is exempt - it is usually the notes of
# this very release - and only gets a note.
fence cli-deploy "Phase 1 Step 0:" "$T/guard.sh"
for SH in $SHELLS; do
  G="g-$(printf '%s' "$SH" | tr -c 'A-Za-z0-9' '-')"
  mk "$G"; W="$T/$G"
  put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'; put "$W" README.md readme
  put "$W" CHANGELOG.md changelog; put "$W" package.json '{ "version": "1.0.0" }'; put "$W" notes.txt notes
  put "$W" Sources/S/Deep/Version.swift deep
  put "$W" Sources/S/Server.swift 'let s = 1'; put "$W" pyproject.toml '[project]'; put "$W" plugin.json '{ }'
  put "$W" .claude-plugin/plugin.json '{ }'; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
  put "$W" Sources/測試/Version.swift 'enum V { static let version = "1.0.0" }'
  ci "$W"; push "$W"; BASE=$(git -C "$W" rev-parse HEAD)
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a clean tree passes" "$RC" 0
  # every file of the list stops the run when it has an uncommitted change (the list is what git matches, not only its text)
  for LF in Sources/S/Server.swift mcpb/manifest.json pyproject.toml plugin.json .claude-plugin/plugin.json package.json; do
    printf '%s\n' "an uncommitted line" >> "$W/$LF"
    run "$SH" "$W" "$T/guard.sh"
    same "$SH: an uncommitted change in $LF stops the run" "$RC" 1
    has "$SH: …and $LF is named" "$OUT" "$LF"
    git -C "$W" checkout -q -- "$LF"
  done
  printf '%s\n' "an uncommitted line" >> "$W/Sources/測試/Version.swift"
  run "$SH" "$W" "$T/guard.sh"
  has "$SH: a path with non-ASCII characters is named as it is, not as an octal escape" "$OUT" "Sources/測試/Version.swift"
  git -C "$W" checkout -q -- "Sources/測試/Version.swift"
  # a merge that is not finished, and a CHANGELOG.md with a conflict: the release commit would finish the merge
  # or commit the conflict markers (#52 verify R1)
  git -C "$W" checkout -q -b side; put "$W" CHANGELOG.md 'side text'; put "$W" notes.txt 'side notes'; ci "$W" side
  git -C "$W" checkout -q main; put "$W" CHANGELOG.md 'main text'; ci "$W" main-side
  git -C "$W" merge -q side >/dev/null 2>&1
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: CHANGELOG.md with a merge conflict stops the run" "$RC" 1
  has "$SH: …the merge that is in progress is named" "$OUT" "MERGE_HEAD"
  git -C "$W" merge --abort >/dev/null 2>&1; git -C "$W" reset -q --hard "$BASE"
  git -C "$W" checkout -q -b side2; put "$W" notes.txt 'side notes'; ci "$W" side2
  git -C "$W" checkout -q main
  git -C "$W" merge -q --no-commit --no-ff side2 >/dev/null 2>&1
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a merge that is resolved but not committed stops the run (the release commit would be its merge commit)" "$RC" 1
  has "$SH: …and says what is in progress" "$OUT" "MERGE_HEAD"
  git -C "$W" merge --abort >/dev/null 2>&1; git -C "$W" reset -q --hard "$BASE"
  # a conflict in CHANGELOG.md without a recorded merge (the files are unmerged in the index only)
  CH_BLOB=$(printf 'a\n' | git -C "$W" hash-object -w --stdin)
  git -C "$W" update-index --force-remove CHANGELOG.md
  printf '0 0000000000000000000000000000000000000000\tCHANGELOG.md\n100644 %s 2\tCHANGELOG.md\n100644 %s 3\tCHANGELOG.md\n' "$CH_BLOB" "$CH_BLOB" | git -C "$W" update-index --index-info 2>/dev/null
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: CHANGELOG.md unmerged in the index stops the run" "$RC" 1
  has "$SH: …and says it is a conflict" "$OUT" "未解決的 merge 衝突"
  git -C "$W" reset -q --hard "$BASE"
  put "$W" README.md unrelated
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: an uncommitted change in README.md stops the run" "$RC" 1
  has "$SH: …and the file is named" "$OUT" "README.md"
  has "$SH: …with what to do" "$OUT" "git stash push -- "
  has "$SH: …and what to do when an earlier cli-deploy left the changes" "$OUT" "上一次沒做完的 cli-deploy"
  git -C "$W" checkout -q -- README.md
  put "$W" Sources/S/Version.swift 'enum V { static let version = "0.9.9" }'
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: an uncommitted change in Sources/*/Version.swift stops the run" "$RC" 1
  has "$SH: …and the file is named" "$OUT" "Sources/S/Version.swift"
  git -C "$W" checkout -q -- Sources/S/Version.swift
  put "$W" package.json '{ "version": "9.9.9" }'; git -C "$W" add package.json
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a change that is already staged stops the run too" "$RC" 1
  has "$SH: …and the file is named" "$OUT" "package.json"
  git -C "$W" reset -q --hard
  git -C "$W" rm -q --cached README.md
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a staged deletion of a listed file stops the run" "$RC" 1
  git -C "$W" reset -q --hard
  put "$W" CHANGELOG.md 'notes for this release'
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a change in CHANGELOG.md alone passes" "$RC" 0
  has "$SH: …with a note that it goes into the release commit" "$OUT" "CHANGELOG.md"
  git -C "$W" checkout -q -- CHANGELOG.md
  git -C "$W" rm -q -f --cached CHANGELOG.md; git -C "$W" commit -qm "drop CHANGELOG" >/dev/null 2>&1
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: an untracked CHANGELOG.md passes" "$RC" 0
  has "$SH: …with the same note" "$OUT" "CHANGELOG.md 已經有未 commit 的修改"
  git -C "$W" reset -q --hard "$BASE"
  put "$W" notes.txt unrelated; put "$W" Sources/S/Deep/Version.swift unrelated
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: a change in a file that is not on the list passes (Phase 3 Step 1 does not stage it)" "$RC" 0
  put "$W" Sources/New/Version.swift 'enum V { static let version = "0.0.1" }'
  run "$SH" "$W" "$T/guard.sh"
  same "$SH: an untracked version file passes (Phase 3 Step 1 does not stage it either)" "$RC" 0
  same "$SH: the check changed nothing: HEAD" "$(git -C "$W" rev-parse HEAD)" "$BASE"
  same "$SH: …and nothing is staged" "$(git -C "$W" diff --cached --name-only)" ""
done
# the check comes before the step that edits the version, and Phase 3 says what it does and does not guarantee
STEP0_ORDER=$(python3 -I - "$PLUGIN_ROOT/skills/cli-deploy/SKILL.md" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("Phase 1 Step 0:"); j = t.index("### Step 1: 更新版本號")
print("before" if i < j else "after")
PY
)
same "the Phase 1 Step 0 check comes before the step that updates the version" "$STEP0_ORDER" before
CLI_TEXT=$(cat "$PLUGIN_ROOT/skills/cli-deploy/SKILL.md")
has "Phase 3 Step 1 says what to do when --stat lists another file" "$CLI_TEXT" "列出別的檔案就不要跑下面的推送區塊"
has "…and that CHANGELOG.md goes in whole" "$CLI_TEXT" "CHANGELOG.md（Step 0 讓它通過，整個檔案都會進 release commit）"
hasnt "the reference to Phase 0 is not the dangling 'Step 0.3'" "$CLI_TEXT" "Step 0.3"
# outside a git repository the check stops instead of passing
mkdir -p "$T/not-a-repo"
run bash "$T/not-a-repo" "$T/guard.sh"
same "outside a git repository the check stops" "$RC" 1
# the check and the staging block must name the same files (CHANGELOG.md is the one exemption)
fence cli-deploy "Phase 3 Step 1: stage" "$T/stage52.sh"
SAME_LIST=$(python3 -I - "$T/guard.sh" "$T/stage52.sh" <<'PY'
import re, shlex, sys
def specs(path, command):
    text = open(path, encoding="utf-8").read().replace("\\\n", " ")
    m = re.search(command + r"[^\n]*? -- ([^\n]*)", text)
    return sorted(shlex.split(m.group(1))) if m else None
guard = specs(sys.argv[1], r"status --porcelain")
stage = specs(sys.argv[2], r"ls-files -m")
if guard is None or stage is None:
    print("pathspec list not found")
elif guard == [s for s in stage if s != "CHANGELOG.md"] and "CHANGELOG.md" in stage:
    print("same")
else:
    print(f"guard {guard} / staging {stage}")
PY
)
same "the check and the staging block name the same files, CHANGELOG.md apart" "$SAME_LIST" same

echo
echo "deploy tag fences: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
