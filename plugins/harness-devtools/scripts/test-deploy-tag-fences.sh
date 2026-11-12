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
# gh stub: only `gh api repos/o/r/git/ref/tags/<tag> --jq .object.sha`, answered with the tag
# object id from the bare repo in GH_STUB_REMOTE — "the GitHub repo o/r"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/bin/sh
[ "$1" = api ] || exit 1
case "$2" in repos/o/r/git/ref/tags/*) tag=${2#repos/o/r/git/ref/tags/} ;; *) exit 1 ;; esac
git --git-dir="$GH_STUB_REMOTE" rev-parse -q --verify "refs/tags/$tag" || exit 1
SH
chmod +x "$T/bin/gh"

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
bash_blocks() { python3 -I -c 'import re,sys; print("\n".join(re.findall(r"```bash\n(.*?)```", open(sys.argv[1]).read(), re.S)))' "$PLUGIN_ROOT/skills/$1/SKILL.md"; }
for s in mcp-deploy cli-deploy; do
  CODE=$(bash_blocks "$s")
  hasnt "$s: the release API is not given target_commitish" "$CODE" 'target_commitish='
  hasnt "$s: no gh release view without --repo" "$(printf '%s\n' "$CODE" | grep 'gh release view' | grep -v -- '--repo')" 'gh release view'
  N_DERIVE=$(printf '%s\n' "$CODE" | grep -c '^OWNER_REPO=')
  N_STRICT=$(printf '%s\n' "$CODE" | grep -A1 '^OWNER_REPO=' | grep -c 'grep -qxE')
  same "$s: every owner/repo derivation ($N_DERIVE) is followed by the strict check" "$N_STRICT" "$N_DERIVE"
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
release_blocks() { python3 -I -c 'import re,sys; print("\n".join(b for b in re.findall(r"```bash\n(.*?)```", open(sys.argv[1]).read(), re.S) if "releases --method POST" in b or "gh release create" in b))' "$PLUGIN_ROOT/skills/$1/SKILL.md"; }
for s in mcp-deploy cli-deploy; do
  hasnt "$s: the release blocks do not substitute v{version} unchecked" "$(release_blocks "$s")" 'v{version}'
done
# verify R4: the guard must not repeat the placeholder it guards — substituting {version}
# everywhere would turn the sentinel into the real version and reject every valid run
for s in mcp-deploy cli-deploy; do
  hasnt "$s: no case pattern repeats '{version}'" "$(bash_blocks "$s")" "'{version}'|"
done
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
prev=""
for a in "$@"; do
  case "$prev" in
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
case "$1 $2" in "api repos/o/r/releases") echo 42 ;; esac
exit 0
SH
printf '%s\n' '#!/bin/sh' 'printf "%s\n" curl >> "$GH50_REC/calls"' 'exit 0' > "$T/bin50/curl"
chmod +x "$T/bin50/gh" "$T/bin50/curl"
# run50 <shell> <dir> <script> — like run, with the recording gh and curl; $T/rec starts empty
run50() {
  local sh=$1 dir=$2 f=$3
  rm -rf "$T/rec"; mkdir -p "$T/rec"
  case "$sh" in
    zsh) OUT=$(cd "$dir" && GH50_REC="$T/rec" PATH="$T/bin50:$PATH" zsh -f -c "$(cat "$f")" 2>&1); RC=$? ;;
    *)   OUT=$(cd "$dir" && GH50_REC="$T/rec" PATH="$T/bin50:$PATH" "$sh" "$f" 2>&1); RC=$? ;;
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
fence mcp-deploy "releases --method POST" "$T/relA.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
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
for ph in project-name BinaryName owner repo; do
  release_texts; printf '## Install\n\nclaude mcp add {%s}\n' "$ph" > "$D/release-notes.md"
  run50 bash "$W" "$T/relA.sh"
  has "notes that still hold {$ph} from the install template → stops" "$OUT" "還有沒代入的 placeholder"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
done
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
release_texts; printf '## Install\n\ncurl -L https://github.com/{owner}/{repo}/releases\n' > "$D/release-notes.md"
run50 bash "$W" "$T/relB.sh"
has "notes that still hold {owner} from the install template → stops" "$OUT" "還有沒代入的 placeholder"
hasnt "…before gh release create" "$(cat "$T/rec/calls" 2>/dev/null)" "release create"
for sh in $SHELLS; do
  release_texts
  run50 "$sh" "$W" "$T/relB.sh"
  same "--title is v<version> - <title>, character for character ($sh)" "$(cat "$T/rec/title" 2>/dev/null)" "v1.4.0 - $(hostile title)"
  if cmp -s "$T/rec/notes-file" "$T/expected-notes"; then ok "--notes-file is the notes file ($sh)"; else bad "--notes-file is not the notes file ($sh)" "$OUT"; fi
  if [ -e "$T/rec/notes-inline" ]; then bad "the notes were put on the command line ($sh)"; else ok "the notes are not on the command line ($sh)"; fi
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
D=$(deploy_dir "$W"); mkdir -p "$D"
fence cli-deploy "releases --method POST" "$T/relC.sh" "VERSION='{version}' ==> VERSION='1.4.0'"
run50 bash "$W" "$T/relC.sh"
has "no notes file → stops" "$OUT" "找不到 release notes 檔"
hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
for ph in binary owner repo; do
  release_texts; rm -f "$D/release-title.txt"; printf '## Install\n\ncurl -fsSL https://x/{%s}\n' "$ph" > "$D/release-notes.md"
  run50 bash "$W" "$T/relC.sh"
  has "notes that still hold {$ph} from the install template → stops" "$OUT" "還有沒代入的 placeholder"
  hasnt "…before any release is created" "$(cat "$T/rec/calls" 2>/dev/null)" "api repos/o/r/releases"
done
release_texts; rm -f "$D/release-title.txt"; export GH50_FAIL_VIEW=1; run50 bash "$W" "$T/relC.sh"; unset GH50_FAIL_VIEW
same "the check after the upload fails → the notes file is kept for the retry" "$(left "$D")" "release-notes.md "
for sh in $SHELLS; do
  release_texts; rm -f "$D/release-title.txt"
  run50 "$sh" "$W" "$T/relC.sh"
  same "the release is named v<version> ($sh)" "$(cat "$T/rec/name" 2>/dev/null)" "v1.4.0"
  if cmp -s "$T/rec/body-file" "$T/expected-notes"; then ok "the body is the notes file, byte for byte ($sh)"; else bad "the body is not the notes file ($sh)" "$OUT"; fi
  if [ -e "$T/rec/body-inline" ]; then bad "the notes were put on the command line ($sh)"; else ok "the notes are not on the command line ($sh)"; fi
  pwned "cli-deploy release ($sh)"
  same "the notes file is removed once the release exists ($sh)" "$(left "$D")" ""
done

echo
echo "deploy tag fences: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
