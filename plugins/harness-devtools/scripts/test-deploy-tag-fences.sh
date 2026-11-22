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
fence cli-deploy "Phase 3 Step 1: stage" "$T/stage.sh" '{version}: {change-summary} ==> 1.1.0: test'
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

echo
echo "deploy tag fences: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
