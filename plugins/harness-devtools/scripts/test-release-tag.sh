#!/bin/bash
# Tests for scripts/release-tag.sh (#42).
#
# Run: bash scripts/test-release-tag.sh
#
# Every case builds a throwaway work repo with its own bare remote, runs the
# helper, and asserts on three things the callers depend on: the exit code, the
# `RELEASE_TAG:` decision line, and what the remote actually holds afterwards.
# A case that only checks "it did not crash" proves nothing about a tag.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/release-tag.sh"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # a user's tag.gpgSign must not leak into the fixtures

ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /' | head -20; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3], got [$2])" "${OUT:-}"; fi; }
has()   { if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing [$2])" "$OUT"; fi; }
hasnt() { if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1 (found [$2])" "$OUT"; else ok "$1"; fi; }

N=0
# new_repo: fresh work repo + bare remote; sets W (not a $(…) call — the counter must persist)
new_repo() {
  N=$((N+1)); local d="$T/r$N"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/work"
  git -C "$d/work" remote add origin "$d/remote.git"
  W="$d/work"
}
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-c}" && git -C "$1" push -q origin main 2>/dev/null; }
run() {   # run <work> [helper args...]; sets OUT and RC
  local w="$1"; shift
  # RT_BASH picks the bash that runs the helper; the suite reruns itself with /bin/bash
  # (3.2 on macOS) at the end, because that is the bash `bash "$HELPER"` meets on a Mac
  # without Homebrew bash first on PATH (#42 verify R2)
  OUT=$(cd "$w" && "${RT_BASH:-bash}" "$HELPER" "$@" 2>&1); RC=$?
}
remote_commit() { git -C "$1" ls-remote --tags origin "refs/tags/$2^{}" | cut -f1; }
plugin_json() { put "$1" "${2:-}.claude-plugin/plugin.json" "{ \"name\": \"p\", \"version\": \"$3\" }"; }

echo "== plugin.json only"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "decision line" "RELEASE_TAG: tagged name=v1.2.3"
check "remote tag points at HEAD" "$(remote_commit "$W" v1.2.3)" "$(git -C "$W" rev-parse HEAD)"
check "annotated tag" "$(git -C "$W" cat-file -t v1.2.3)" tag

echo "== same commit again → skip"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "exists" "RELEASE_TAG: exists name=v1.2.3"

echo "== not bumped: new commit, same version"
put "$W" README.md x; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 10" "$RC" 10
has "not-bumped" "RELEASE_TAG: not-bumped name=v1.2.3"
check "tag not moved" "$(remote_commit "$W" v1.2.3)" "$(git -C "$W" rev-parse HEAD~1)"

echo "== hatch path __version__ agrees with plugin.json"
new_repo; plugin_json "$W" "" 0.7.0
put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
path = "x/__init__.py"'
put "$W" x/__init__.py '"""x"""

__version__ = "0.7.0"'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "sources list hatch" "hatch:x/__init__.py"

echo "== hatch __version__ disagrees with plugin.json"
new_repo; plugin_json "$W" "" 1.2.3
put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]
[tool.hatch.version]
path = "x/__init__.py"'
put "$W" x/__init__.py '__version__ = "1.2.4"'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 20" "$RC" 20
has "mismatch line" "RELEASE_TAG: mismatch"
has "names both values" "1.2.4"
check "no local tag" "$(git -C "$W" tag -l)" ""
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== dynamic version that is not a hatch path → unreadable"
new_repo; plugin_json "$W" "" 1.0.0
put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21" "$RC" 21
has "unreadable" "RELEASE_TAG: unreadable"

echo "== pyproject static version"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "2.0.0"'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "pyproject source" "pyproject"
check "remote v2.0.0" "$(remote_commit "$W" v2.0.0)" "$(git -C "$W" rev-parse HEAD)"

echo "== package.json"
new_repo; put "$W" package.json '{ "name": "x", "version": "3.1.4" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "tag v3.1.4" "name=v3.1.4"

echo "== Version.swift: static let version"
new_repo; put "$W" Sources/Foo/Version.swift 'enum AppVersion {
    static let version = "0.4.0"
}'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "tag v0.4.0" "name=v0.4.0"

echo "== Version.swift: static let current + mcpb manifest + Server.swift agree"
new_repo; put "$W" Sources/Bar/Version.swift 'enum V { static let current = "0.3.0" }'
put "$W" mcpb/manifest.json '{ "name": "bar", "version": "0.3.0" }'
put "$W" Sources/Bar/Server.swift 'let server = Server(name: "bar", version: "0.3.0", capabilities: .init())
let protocolVersion: String = "2025-06-18"'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "manifest source" "mcpb"
has "server source" "Server.swift"

echo "== Server.swift with two different versions → unreadable"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
put "$W" Sources/S/Server.swift 'Server(name: "s", version: "1.0.0")
Server(name: "t", version: "1.0.1")'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21" "$RC" 21

echo "== version that is not x.y.z → unreadable"
new_repo; plugin_json "$W" "" 1.2; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21" "$RC" 21

echo "== no version source at all → unreadable"
new_repo; put "$W" README.md x; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21" "$RC" 21

echo "== work tree differs from HEAD → HEAD wins"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
plugin_json "$W" "" 9.9.9
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "tag from HEAD" "name=v1.0.0"

echo "== plugin in a subdirectory, plugin-style name"
new_repo; plugin_json "$W" "plugins/foo/" 1.2.3; put "$W" .claude-plugin/marketplace.json '{ "plugins": [] }'; commit "$W"
run "$W" --dir plugins/foo --commit HEAD --name-style plugin --plugin foo
check "exit 0" "$RC" 0
has "plugin-style name" "name=foo-v1.2.3"
check "remote foo-v1.2.3" "$(remote_commit "$W" foo-v1.2.3)" "$(git -C "$W" rev-parse HEAD)"

echo "== --dry-run creates nothing"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "exit 0" "$RC" 0
has "dry-run line" "RELEASE_TAG: dry-run name=v1.2.3"
check "no local tag" "$(git -C "$W" tag -l)" ""

echo "== remote rejects the tag push → 30, retry command, local tag kept"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
printf '#!/bin/sh\nexit 1\n' > "$T/r$N/remote.git/hooks/pre-receive"; chmod +x "$T/r$N/remote.git/hooks/pre-receive"
run "$W" --dir . --commit HEAD --name-style v
check "exit 30" "$RC" 30
has "push-failed line" "RELEASE_TAG: push-failed name=v1.2.3"
has "retry command" "push --no-follow-tags origin refs/tags/v1.2.3"
check "local tag kept for retry" "$(git -C "$W" tag -l)" v1.2.3

echo "== unreachable remote → 30"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
git -C "$W" remote set-url origin "$T/does-not-exist.git"
run "$W" --dir . --commit HEAD --name-style v
check "exit 30" "$RC" 30

echo "== round 2 (#42 verify R1)"

echo "== --expect agrees → tagged"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.2.3
check "exit 0" "$RC" 0
has "tag v1.2.3" "name=v1.2.3"

echo "== --expect disagrees with the version files → 20, nothing created"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.2.4
check "exit 20" "$RC" 20
has "names the expected version" "1.2.4"
check "no local tag" "$(git -C "$W" tag -l)" ""
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== no version in the tree (version computed at build time) + --expect → tagged from --expect"
new_repo; put "$W" Sources/S/BuildVersion.swift 'enum BuildVersion { static let value = "unknown" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.5.0
check "exit 0" "$RC" 0
has "tag v1.5.0" "name=v1.5.0"
has "source is --expect" "sources=--expect"

echo "== Version.swift with no recognisable declaration is not a source"
new_repo; put "$W" Sources/gfs/Version.swift 'struct Version: ParsableCommand {
    func run() { print("gfh 0.3.1") }
}'
put "$W" mcpb/manifest.json '{ "version": "0.3.1" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "only the manifest counted" "sources=mcpb/manifest.json"

echo "== a TAB in the hatch path cannot hide the real __version__ (verify R1 PoC, variant 2)"
new_repo; plugin_json "$W" "" 1.0.0
mkdir -p "$W/x"; printf '__version__ = "2.0.0"\n' > "$W/x/a	1.0.0"
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/a\\t1.0.0"\n' > "$W/pyproject.toml"
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21 (a hatch path outside [A-Za-z0-9._/-] is refused, so 1.0.0 cannot pass as agreed)" "$RC" 21
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== a TAB in the hatch path cannot smuggle text into the tag name (verify R1 PoC, variant 1)"
new_repo
mkdir -p "$W/x"; printf '__version__ = "2.0.0"\n' > "$W/x/a	1.0.0;touch\${IFS}PWNED"
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/a\\t1.0.0;touch${IFS}PWNED"\n' > "$W/pyproject.toml"
commit "$W"
run "$W" --dir . --commit HEAD --name-style v
if git -C "$W" ls-remote --tags origin | grep -q ';'; then bad "a tag containing ';' reached the remote"; else ok "no tag containing ';' on the remote"; fi
if printf '%s' "$OUT" | grep -q ';touch'; then bad "output carries the injected text" "$OUT"; else ok "output does not carry the injected text"; fi
check "exit 21 (refused)" "$RC" 21

echo "== --at-bump: tag the commit that set the version, not later commits"
new_repo; plugin_json "$W" "" 0.9.0; commit "$W" old
plugin_json "$W" "" 1.0.0; commit "$W" bump
BUMP=$(git -C "$W" rev-parse HEAD)
put "$W" a.txt 1; commit "$W" wip1; put "$W" b.txt 2; commit "$W" wip2
run "$W" --dir . --commit HEAD --name-style v --at-bump
check "exit 0" "$RC" 0
check "remote v1.0.0 points at the bump commit" "$(remote_commit "$W" v1.0.0)" "$BUMP"
has "notes the later commits the tag does not include" "commits after the tagged one that change the repository: 2"
run "$W" --dir . --commit HEAD --name-style v --at-bump
check "second run: exit 0 (exists)" "$RC" 0
has "second run says exists" "RELEASE_TAG: exists name=v1.0.0"

echo "== --at-bump with two sources bumped in different commits → the commit where they first agree"
new_repo; plugin_json "$W" "" 1.0.0
put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]
[tool.hatch.version]
path = "x/__init__.py"'
put "$W" x/__init__.py '__version__ = "1.0.0"'; commit "$W" base
plugin_json "$W" "" 1.1.0; commit "$W" half
put "$W" x/__init__.py '__version__ = "1.1.0"'; commit "$W" full
FULL=$(git -C "$W" rev-parse HEAD)
put "$W" c.txt 3; commit "$W" later
run "$W" --dir . --commit HEAD --name-style v --at-bump
check "exit 0" "$RC" 0
check "remote v1.1.0 points at the commit where both sources agree" "$(remote_commit "$W" v1.1.0)" "$FULL"

echo "== --at-bump when the version never changed → the commit that introduced it"
new_repo; plugin_json "$W" "" 2.0.0; commit "$W" first
FIRST=$(git -C "$W" rev-parse HEAD)
put "$W" d.txt 4; commit "$W" more
run "$W" --dir . --commit HEAD --name-style v --at-bump
check "exit 0" "$RC" 0
check "remote v2.0.0 points at the first commit" "$(remote_commit "$W" v2.0.0)" "$FIRST"

echo "== non-ASCII directory under Sources/ is still read"
new_repo; put "$W" "Sources/版本/Version.swift" 'enum V { static let version = "0.5.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
has "tag v0.5.0" "name=v0.5.0"

echo "== the annotated tag message names the repository, not the checkout directory"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
OUT=$(git -C "$W" cat-file -p v1.2.3); has "tag object message is 'remote 1.2.3'" "remote 1.2.3"

echo "== --at-bump follows a commit that deleted a version source (verify R2, Codex)"
new_repo; plugin_json "$W" "" 1.0.0; put "$W" package.json '{ "version": "1.0.0" }'; commit "$W" base
plugin_json "$W" "" 2.0.0; commit "$W" half
rm "$W/package.json"; commit "$W" drop
DROP=$(git -C "$W" rev-parse HEAD)
put "$W" e.txt 5; commit "$W" unrelated
run "$W" --dir . --commit HEAD --name-style v --at-bump
check "exit 0" "$RC" 0
check "remote v2.0.0 points at the commit where the sources first agree (the deletion)" "$(remote_commit "$W" v2.0.0)" "$DROP"

echo "== --at-bump refuses to guess when the walk limit is reached (verify R2)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W" first
for i in 1 2 3 4; do put "$W" .claude-plugin/plugin.json "{ \"name\": \"p$i\", \"version\": \"1.0.0\" }"; commit "$W" "rename $i"; done
OUT=$(cd "$W" && RELEASE_TAG_MAX_WALK=3 "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --at-bump 2>&1); RC=$?
check "exit 21" "$RC" 21
has "says why" "walk limit"
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""
OUT=$(cd "$W" && RELEASE_TAG_MAX_WALK=9 "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --at-bump 2>&1); RC=$?
check "within the limit: exit 0" "$RC" 0
check "within the limit: tag on the first commit" "$(remote_commit "$W" v1.0.0)" "$(git -C "$W" rev-list --max-parents=0 HEAD)"

echo "== Version.swift with a type annotation, an access modifier or var is a source (verify R2, Codex)"
new_repo; put "$W" Sources/S/Version.swift 'public enum V { public static let version: String = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 2.0.0
check "the file says 1.0.0, the release is 2.0.0 → exit 20" "$RC" 20
has "names the Swift source" "Sources/S/Version.swift"
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""
run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0
check "agreeing release → exit 0" "$RC" 0
new_repo; put "$W" Sources/S/Version.swift 'enum V { static var current = "3.1.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "static var current → exit 0" "$RC" 0
has "tag v3.1.0" "name=v3.1.0"

echo "== a version declaration that is not a string literal → unreadable, not ignored (verify R2)"
new_repo; put "$W" Sources/S/Version.swift 'enum V { static let version = Bundle.main.shortVersion }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0
check "exit 21 (no fallback to --expect)" "$RC" 21
check "no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== versions git refuses as a tag name are refused before tagging, dry-run included (verify R2)"
for bad_v in '1.0.0-a..b' '1.0.0-x.lock' '1.0.0-rc.'; do
  new_repo; plugin_json "$W" "" "$bad_v"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run
  check "$bad_v: dry-run exit 21" "$RC" 21
done
new_repo; put "$W" .claude-plugin/plugin.json '{ "name": "p", "version": "1.0.0\n" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a version with a trailing newline → exit 21" "$RC" 21

echo "== a push URL that differs from the fetch URL → nothing is pushed anywhere (verify R3, Codex)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
git init -q --bare "$T/r$N/other.git"
git -C "$W" remote set-url --push origin "$T/r$N/other.git"
run "$W" --dir . --commit HEAD --name-style v
check "exit 30" "$RC" 30
has "says why" "push URL"
check "no tag on the fetch remote" "$(git -C "$W" ls-remote --tags origin)" ""
check "no tag on the push remote" "$(git --git-dir="$T/r$N/other.git" for-each-ref refs/tags)" ""
check "no local tag left behind" "$(git -C "$W" tag -l)" ""

echo "== --at-bump in a shallow clone refuses unless the history shows where the version was set (verify R3)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W" c1
plugin_json "$W" "" 2.0.0; commit "$W" c2
put "$W" a.txt 1; commit "$W" c3; put "$W" b.txt 2; commit "$W" c4
REMOTE_GIT="$T/r$N/remote.git"; C2=$(git -C "$W" rev-parse HEAD~2)
git clone -q --branch main --depth 2 "file://$REMOTE_GIT" "$T/r$N/shallow2"
run "$T/r$N/shallow2" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "depth 2 (the bump is not visible) → exit 21" "$RC" 21
has "says shallow" "shallow"
git clone -q --branch main --depth 3 "file://$REMOTE_GIT" "$T/r$N/shallow3"
run "$T/r$N/shallow3" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "depth 3 (the bump is the boundary, its parent hidden) → exit 21" "$RC" 21
git clone -q --branch main --depth 4 "file://$REMOTE_GIT" "$T/r$N/shallow4"
run "$T/r$N/shallow4" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "depth 4 (the commit before the bump is visible) → exit 0" "$RC" 0
has "…on the bump commit" "commit=$(git -C "$W" rev-parse --short "$C2")"

echo "== Version.swift: only a whole string literal counts (verify R3, Codex)"
for init in '"1.0.0" + "-beta"' '"1.0.0".lowercased()' '"1.0.0"
        + "-beta"'; do
  new_repo; put "$W" Sources/S/Version.swift "enum V { static let version = $init }"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0
  check "initializer [$init] → exit 21, not 1.0.0" "$RC" 21
  check "…no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""
done
new_repo; put "$W" Sources/S/Version.swift 'enum V {
    // static let version = "0.9.0"
    /* static let current = "0.8.0" */
    static let version = "1.0.0" // shipped
}'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0
check "commented-out declarations are ignored, a trailing comment is fine → exit 0" "$RC" 0

echo "== --at-bump: a commit whose sources cannot all be read (verify R3)"
new_repo; plugin_json "$W" "" 1.0.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'; commit "$W" base
plugin_json "$W" "" 1.1.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; commit "$W" bump
put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.1.0" } }'; commit "$W" computed
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; commit "$W" fixed
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "readable sources there all equal the current version → cannot tell → exit 21" "$RC" 21
new_repo; plugin_json "$W" "" 1.0.0; put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.0.0" } }'; commit "$W" old-format
plugin_json "$W" "" 1.1.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; commit "$W" bump
BUMP=$(git -C "$W" rev-parse HEAD); put "$W" c.txt 1; commit "$W" wip
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "a readable source there differs → the walk stops normally → exit 0" "$RC" 0
has "…on the bump commit" "commit=$(git -C "$W" rev-parse --short "$BUMP")"

echo "== values from the repository stay masked in messages (verify R3)"
new_repo; put "$W" "Sources/a b c/Version.swift" 'enum V { static let version = "1.0.0"; static let current = "2.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v
check "exit 21" "$RC" 21
has "the directory name keeps its ? marks" "Sources/a?b?c/Version.swift"
if printf '%s' "$OUT" | grep -qF 'Sources/a b c'; then bad "the directory name came back with spaces" "$OUT"; else ok "the directory name does not come back with spaces"; fi

echo "== a --dir whose name has [ ] is read normally (verify R3)"
new_repo; plugin_json "$W" "p[1]/" 1.0.0; commit "$W"
run "$W" --dir "p[1]" --commit HEAD --name-style plugin --plugin p --dry-run
check "exit 0" "$RC" 0

echo "== hatch: the version is read exactly as hatchling reads it (verify R6: its regex source, first match)"
# hatchling/version/core.py: DEFAULT_PATTERN = (?i)^(__version__|VERSION) *= *(['"])v?(?P<version>.+?)\2,
# re.MULTILINE, first match; [tool.hatch.version] pattern overrides it; source defaults to "regex".
# So `"1.0.0" + "-beta"` builds 1.0.0, and the tag must say what the build publishes.
hatch_repo() {   # hatch_repo <__init__.py text> [extra [tool.hatch.version] lines]
  new_repo; plugin_json "$W" "" 1.0.0
  printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/__init__.py"\n%s' "${2:-}" > "$W/pyproject.toml"
  put "$W" x/__init__.py "$1"; commit "$W"
}
for init in '__version__ = "1.0.0" + "-beta"' '__version__ = "1.0.0".lower()' '__version__ = "1.0.0" if True else "2"' '__version__ = "v1.0.0"' 'VERSION = "1.0.0"'; do
  hatch_repo "$init"
  run "$W" --dir . --commit HEAD --name-style v --dry-run
  check "[$init] → hatch builds 1.0.0 → exit 0" "$RC" 0
done
hatch_repo '__version__: str = "1.0.0"  # typed'
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "an annotated __version__ is not found by hatch's pattern → exit 21" "$RC" 21
hatch_repo '__version__ = "0.1.0"
VERSION_STRING = "1.0.0"' 'pattern = "^VERSION_STRING = \"(?P<version>[^\"]+)\""
'
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a custom [tool.hatch.version] pattern is used → 1.0.0, exit 0" "$RC" 0
hatch_repo '__version__ = "1.0.0"' 'source = "code"
'
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a version source other than regex → exit 21" "$RC" 21
has "…and says so" "source"

echo "== Server.swift: comments do not count (verify R4)"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.1.0" }'
put "$W" Sources/S/Server.swift '// Before 1.1 this said Server(name: "s", version: "1.0.0")
/* version: "0.9.0" */
let s = Server(name: "s", version: "1.1.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "old versions in comments are ignored → exit 0" "$RC" 0
has "…and Server.swift is a source" "Sources/S/Server.swift"

echo "== // inside a Swift string is not a comment (verify R4)"
new_repo; put "$W" Sources/S/Version.swift 'enum V { static let repo = "https://x.y/a"; static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 2.0.0
check "the version after a URL string is still read → mismatch, exit 20" "$RC" 20
check "…no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== --at-bump: an older commit with no version field means the version was not set there (verify R4)"
new_repo; put "$W" .claude-plugin/plugin.json '{ "name": "p" }'; commit "$W" c1
plugin_json "$W" "" 0.1.0; commit "$W" c2
C2=$(git -C "$W" rev-parse HEAD); put "$W" d.txt 1; commit "$W" c3
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
has "…on the commit that added the version" "commit=$(git -C "$W" rev-parse --short "$C2")"

echo "== push URL: the same repository written another way is not a different repository (verify R4)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
git -C "$W" remote set-url origin https://github.com/o/r.git
git -C "$W" config url.git@github.com:.pushInsteadOf https://github.com/
# a dry run now looks the tag up on the remote (#51). A test must not reach github.com:
# GIT_ALLOW_PROTOCOL=file makes that lookup fail at once, offline, AFTER the push-URL check
OUT=$(cd "$W" && GIT_ALLOW_PROTOCOL=file "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
hasnt "https fetch + ssh push to github.com/o/r → passes the push-URL check" "push URL"
has "…and goes on to the tag lookup" "cannot query remote"
git -C "$W" config --unset url.git@github.com:.pushInsteadOf
git -C "$W" remote set-url --push origin git@github.com:o/other.git
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a push URL for another repository → exit 30" "$RC" 30
has "…and says the push URL differs" "push URL"

echo "== messages stay ASCII, so a non-UTF-8 locale does not break the run (verify R4)"
new_repo; plugin_json "$W" "" 1.0.0; put "$W" Sources/S/Version.swift 'struct Version { func run() { print("x") } }'; commit "$W"
if locale -a 2>/dev/null | grep -qx 'en_US.ISO8859-15'; then
  OUT=$(cd "$W" && LC_ALL=en_US.ISO8859-15 "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
  check "LC_ALL=en_US.ISO8859-15 → exit 0" "$RC" 0
fi

echo "== local tags (verify R4)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
git -C "$W" tag -a v1.0.0 -m local HEAD; LOCAL_OBJ=$(git -C "$W" rev-parse v1.0.0)
run "$W" --dir . --commit HEAD --name-style v
check "a local tag on this commit, not yet on the remote → pushed (exit 0)" "$RC" 0
check "…the same tag object, not a new one" "$(git -C "$W" ls-remote --tags origin refs/tags/v1.0.0 | cut -f1)" "$LOCAL_OBJ"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"; put "$W" e.txt 1; commit "$W"
git -C "$W" tag -a v1.0.0 -m old HEAD~1
run "$W" --dir . --commit HEAD --name-style v
check "a local tag on another commit → exit 10" "$RC" 10
check "…nothing on the remote" "$(git -C "$W" ls-remote --tags origin)" ""

echo "== Server.swift: only a whole string literal counts (verify R5, Codex)"
for arg in '"1.0.0" + "-beta"' '"1.0.0".lowercased()'; do
  new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
  put "$W" Sources/S/Server.swift "let s = Server(name: \"s\", version: $arg)"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0
  check "version: $arg → exit 21, not 1.0.0" "$RC" 21
  check "…no remote tag" "$(git -C "$W" ls-remote --tags origin)" ""
done

echo "== --at-bump follows a hatch version file that was renamed (verify R5, Codex)"
new_repo
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/old.py"\n' > "$W/pyproject.toml"
put "$W" x/old.py '__version__ = "1.0.0"'; commit "$W" A
put "$W" x/old.py '__version__ = "2.0.0"'; commit "$W" B
B=$(git -C "$W" rev-parse HEAD)
git -C "$W" mv x/old.py x/new.py
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/new.py"\n' > "$W/pyproject.toml"; commit "$W" C
put "$W" z.txt 1; commit "$W" D
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
has "…on the commit that bumped the old file, not the rename" "commit=$(git -C "$W" rev-parse --short "$B")"

echo "== hatch files python3 would not parse are read like hatch reads them (verify R5, R6)"
hatch_repo "$(printf '\xef\xbb\xbf"""doc"""\n__version__ = "1.0.0"')"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a UTF-8 BOM before a docstring → exit 0" "$RC" 0
hatch_repo "$(printf 'type Alias = int\ndef f[T](x: T) -> T:\n    return x\n__version__ = "1.0.0"')"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "syntax newer than python3 → exit 0" "$RC" 0
hatch_repo "__version__ = $(printf '%*s' 200000 '' | tr ' ' '-')1"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "no quoted version (hatch cannot parse it either) → exit 21" "$RC" 21
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
hatch_repo "$(printf '# -*- coding: latin-1 -*-\n# caf\xe9\n__version__ = "1.0.0"')"
run "$W" --dir . --commit HEAD --name-style v --dry-run
# hatchling opens the file with encoding="utf-8" (strict), so it cannot build this
# project; the helper must not tag a version the build cannot read (verify R7)
check "a byte that is not UTF-8 → exit 21, as hatchling fails to read it" "$RC" 21
has "…says why" "not UTF-8"
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
hatch_repo "$(printf '\xef\xbb\xbf__version__ = "1.0.0"')"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a BOM right before __version__ on line 1 → exit 21 (hatch's ^ does not match after U+FEFF)" "$RC" 21

echo "== hatch path is normalised the way hatchling does it (verify R7)"
for hp in './x/__init__.py' 'x//__init__.py' 'x/./__init__.py'; do
  new_repo; plugin_json "$W" "plugins/foo/" 1.0.0
  printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "%s"\n' "$hp" > "$W/pyproject.toml.tmp"
  mkdir -p "$W/plugins/foo"; mv "$W/pyproject.toml.tmp" "$W/plugins/foo/pyproject.toml"
  put "$W" plugins/foo/x/__init__.py '__version__ = "1.0.0"'; commit "$W"
  run "$W" --dir plugins/foo --commit HEAD --name-style plugin --plugin foo --dry-run
  check "[$hp] in a plugin directory → exit 0" "$RC" 0
  has "…read as x/__init__.py" "hatch:x/__init__.py"
done
new_repo; plugin_json "$W" "" 1.0.0
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "/x/__init__.py"\n' > "$W/pyproject.toml"
put "$W" x/__init__.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "an absolute hatch path (not a file in the repository) → exit 21" "$RC" 21

echo "== --at-bump follows the branch's own (first-parent) history across a merge (verify R7, Codex)"
new_repo
pj() { printf '{\n  "name": "p",\n  "version": "%s",\n  "k1": "1",\n  "k2": "2",\n  "k3": "3",\n  "fa": "%s",\n  "k4": "4",\n  "k5": "5",\n  "k6": "6",\n  "fb": "%s"\n}\n' "$1" "$2" "$3" > "$W/.claude-plugin/plugin.json"; }
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$W" "${@:2}"; }
mkdir -p "$W/.claude-plugin"; pj 1.0.0 0 0
git -C "$W" add -A; at 2026-01-01T00:00:00+0000 commit -qm C0
git -C "$W" checkout -qb feat
pj 2.0.0 0 1; git -C "$W" add -A; at 2026-01-02T00:00:00+0000 commit -qm F1   # older bump, on the feature branch
F1=$(git -C "$W" rev-parse HEAD)
git -C "$W" checkout -q main
pj 2.0.0 1 0; git -C "$W" add -A; at 2026-01-03T00:00:00+0000 commit -qm M1   # newer bump, on main
M1=$(git -C "$W" rev-parse HEAD)
at 2026-01-04T00:00:00+0000 merge -q --no-ff --no-edit feat
git -C "$W" push -q origin main 2>/dev/null
check "fixture: the merged plugin.json equals neither parent" "$(git -C "$W" diff --quiet HEAD^1 HEAD -- .claude-plugin/plugin.json || git -C "$W" diff --quiet HEAD^2 HEAD -- .claude-plugin/plugin.json || echo neither)" neither
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
has "…on main's bump commit" "commit=$(git -C "$W" rev-parse --short "$M1")"
if printf '%s' "$OUT" | grep -qF "commit=$(git -C "$W" rev-parse --short "$F1")"; then bad "…not the feature branch's bump" "$OUT"; else ok "…not the feature branch's bump"; fi

echo "== a root plugin.json without a version field is not a source (verify R5)"
new_repo; put "$W" .claude-plugin/plugin.json '{ "name": "p", "description": "d" }'; put "$W" mcpb/manifest.json '{ "version": "1.2.3" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.2.3 --dry-run
check "mcpb/manifest.json decides → exit 0" "$RC" 0
has "…and plugin.json is not listed as a source" "sources=mcpb/manifest.json"
new_repo; put "$W" .claude-plugin/plugin.json '{ "name": "p" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "plugin.json without a version and nothing else → still exit 21 (no version source)" "$RC" 21

echo "== Server.swift: an escape or interpolation after a version prefix is not a plain version (verify R6)"
for arg in '"1.0.\(patch)"' '"1.0.0\u{2d}beta"'; do
  new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
  put "$W" Sources/S/Server.swift "let s = Server(name: \"s\", version: $arg)"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0 --dry-run
  check "version: $arg → exit 21" "$RC" 21
done

echo "== Swift block comments nest (verify R6, Codex)"
new_repo; put "$W" Sources/S/Version.swift '/* /* old */ static let version = "0.9.0" */
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --expect 1.0.0 --dry-run
check "a declaration inside a nested comment is ignored → exit 0" "$RC" 0

echo "== --at-bump with [ ] in the plugin directory name and a Swift source (verify R6, Codex)"
new_repo; put "$W" "p[1]/Sources/S/Version.swift" 'enum V { static let version = "1.0.0" }'; commit "$W" a
put "$W" "p[1]/Sources/S/Version.swift" 'enum V { static let version = "2.0.0" }'; commit "$W" bump
B=$(git -C "$W" rev-parse HEAD); put "$W" z.txt 1; commit "$W" later
run "$W" --dir "p[1]" --commit HEAD --name-style plugin --plugin p --at-bump --dry-run
check "exit 0" "$RC" 0
has "…on the bump commit" "commit=$(git -C "$W" rev-parse --short "$B")"

echo "== a pyproject.toml in history whose [tool.hatch] is not a table (verify R6)"
new_repo; plugin_json "$W" "" 1.0.0; printf '[project]\nname = "x"\n[tool.hatch]\nversion = "oops"\n' > "$W/pyproject.toml"; commit "$W" odd
printf '[project]\nname = "x"\nversion = "2.0.0"\n' > "$W/pyproject.toml"; plugin_json "$W" "" 2.0.0; commit "$W" bump
B=$(git -C "$W" rev-parse HEAD); put "$W" z.txt 1; commit "$W" later
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
new_repo; plugin_json "$W" "" 1.0.0; printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch]\nversion = "oops"\n' > "$W/pyproject.toml"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "at HEAD → exit 21" "$RC" 21
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi

echo "== mcpb/manifest.json without a version at an older commit is not a source (verify R6)"
new_repo; put "$W" mcpb/manifest.json '{ "name": "m" }'; commit "$W" a
put "$W" mcpb/manifest.json '{ "name": "m", "version": "1.0.0" }'; commit "$W" b
B=$(git -C "$W" rev-parse HEAD); put "$W" z.txt 1; commit "$W" c
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
has "…on the commit that added the version" "commit=$(git -C "$W" rev-parse --short "$B")"

echo "== a UTF-8 BOM in a JSON source (verify R6)"
new_repo; put "$W" .claude-plugin/plugin.json "$(printf '\xef\xbb\xbf{ "name": "p", "version": "1.0.0" }')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "exit 0" "$RC" 0

echo "== push.followTags=true does not carry other local tags along (verify R8, Codex)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
git -C "$W" tag -a v1.0.0-preview -m preview HEAD
git -C "$W" config push.followTags true
run "$W" --dir . --commit HEAD --name-style v
check "exit 0" "$RC" 0
check "v1.0.0 reached the remote" "$(remote_commit "$W" v1.0.0)" "$(git -C "$W" rev-parse HEAD)"
check "…and the unpushed v1.0.0-preview did not" "$(git -C "$W" ls-remote --tags origin refs/tags/v1.0.0-preview)" ""

echo "== hatch reads the version file with universal newlines, like open() (verify R8)"
hatch_repo "$(printf '__version__ = "1.0.0"\r')" "pattern = '^__version__ = \"(?P<version>[^\"]+)\"\$'"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "CRLF file, pattern ending in \$ → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
hatch_repo "$(printf '# x\r__version__ = "1.0.0"\r')" "pattern = '^__version__ = \"(?P<version>[^\"]+)\"\$'"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "lone CR line ends → exit 0" "$RC" 0

echo "== a Swift multi-line string is not code (verify R8, Codex)"
new_repo
put "$W" Sources/S/Version.swift 'enum V {
    static let version = "1.0.0"
    static let doc = """
    static let version = "0.9.0"
    """
}'
put "$W" Sources/S/Server.swift 'let s = Server(name: "s", version: "1.0.0")
let help = """
Server(name: "old", version: "0.9.0")
"""'
commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "declarations inside \"\"\" … \"\"\" do not count → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
new_repo; put "$W" Sources/S/Version.swift 'enum V { static let version = """
1.0.0
""" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a version declared as a multi-line string is still not a plain literal → exit 21" "$RC" 21

echo "== Server.swift: a space before the colon (#54)"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.1.0" }'
put "$W" Sources/S/Server.swift 'let s = Server(name: "s", version : "1.0.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.1.0
check "version : \"1.0.0\" is read and disagrees with the manifest → exit 20" "$RC" 20
has "…Server.swift is among the sources" "Sources/S/Server.swift"
new_repo; put "$W" Sources/S/Server.swift 'let s = Server(name: "s", version
    :
    "1.0.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "the colon on a line of its own is read too → exit 20, --expect does not stand in" "$RC" 20

echo "== Swift raw strings are strings: what is inside is not code, and what follows is still read (#54)"
new_repo; put "$W" Sources/S/Version.swift 'let quote = #"say """hi""" now"#
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "a raw string holding \"\"\" does not blank the rest of the file → exit 20" "$RC" 20
has "…the declaration after it is the source" "Sources/S/Version.swift"
new_repo; put "$W" Sources/S/Version.swift 'let doc = #"""
static let version = "0.9.0"
"""#
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a declaration inside a multi-line raw string does not count → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
new_repo; put "$W" Sources/S/Version.swift 'let a = ##"one "# two"##
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "a raw string ends at its own number of # → exit 20" "$RC" 20
new_repo; put "$W" Sources/S/Version.swift '#if DEBUG
let flag = #available(macOS 14, *)
#endif
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "#if, #available and #endif are not strings → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
# Swift reads #"""x"# as a ONE-line raw string (""x) because "# closes it on the same line. Taken for
# a multi-line one, it would run to the next """# and swallow the declaration in between, and --expect
# would stand in for it
new_repo; put "$W" Sources/S/Version.swift 'let a = #"""x"#
enum V { static let version = "1.0.0" }
let b = #"""
text
"""#'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "#\"\"\"x\"# closes on its own line, the declaration after it is read → exit 20, --expect does not stand in" "$RC" 20
has "…Version.swift is the source" "sources=Sources/S/Version.swift"
# an escape does not close a string: \#" in a #"…"# string, \""" in a multi-line string
new_repo; put "$W" Sources/S/Version.swift 'let c = #"a \#"# static let version = "9.9.9" "#
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "\\#\" inside a raw string does not close it; the text after it is still inside → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
new_repo; put "$W" Sources/S/Version.swift 'let d = """
He said \"""hi
static let version = "9.9.9"
"""
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "\\\"\"\" inside a multi-line string does not close it → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
# a backslash at the end of a one-line string does not carry the string onto the next line
new_repo; put "$W" Sources/S/Version.swift 'let x = "trailing\
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "a one-line string ends at its line break even after a backslash → the declaration is read, exit 20" "$RC" 20

echo "== text inside a one-line string is not a declaration (#54)"
new_repo; put "$W" Sources/S/Version.swift 'let help = "write static let version = in Version.swift"
enum V { static let version = "1.0.0" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "static let version inside a string is not a declaration → exit 0, not 21" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
put "$W" Sources/S/Server.swift 'let help = #"pass version: "9.9.9" to the server"#
let s = Server(name: "s", version: "1.0.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "version: \"9.9.9\" inside a raw string is not a version → exit 0, not 21" "$RC" 0
has "…version 1.0.0" "version=1.0.0"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
put "$W" Sources/S/Server.swift 'let s = Server(name: "s", version: #"1.0.0"#)'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a version given as a raw string literal is not a plain literal → exit 21, not skipped" "$RC" 21
new_repo; put "$W" Sources/S/Version.swift 'enum V { static let version = #"1.0.0"# }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "Version.swift: a version declared as a raw string literal → exit 21, not skipped" "$RC" 21
has "…not a string literal" "not as a string literal"
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
put "$W" Sources/S/Server.swift 'let help = "pass version: \"9.9.9\" to the server"
let s = Server(name: "s", version: "1.0.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "version: \\\"9.9.9\\\" with escaped quotes inside a string is not a version → exit 0" "$RC" 0
has "…version 1.0.0" "version=1.0.0"

echo "== a string that is never closed makes the file unreadable (#54)"
for OPEN in 'let doc = """
static let version = "0.9.0"' 'let doc = #"""
text' 'let x = #"no end'; do
  new_repo; put "$W" Sources/S/Version.swift "$OPEN
enum V { static let version = \"1.0.0\" }"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "Version.swift with an unclosed $(printf '%s' "$OPEN" | sed -n '1s/^[^=]*= *//p' | cut -c1-4) string → exit 21" "$RC" 21
  has "…and the message says a string is not closed" "not closed"
done
new_repo; put "$W" mcpb/manifest.json '{ "version": "1.0.0" }'
put "$W" Sources/S/Server.swift 'let doc = """
Server(name: "s", version: "1.0.0")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "Server.swift with an unclosed multi-line string → exit 21" "$RC" 21

echo "== deeply nested JSON or TOML is a problem line, not a traceback (verify R8)"
new_repo; put "$W" package.json "$(printf '%*s' 200000 '' | tr ' ' '[')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "package.json nested 200000 deep → exit 21" "$RC" 21
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
new_repo; put "$W" pyproject.toml "x = $(printf '%*s' 5000 '' | tr ' ' '[')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "pyproject.toml nested 5000 deep → exit 21" "$RC" 21
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi

echo "== poetry: [tool.poetry].version is a version source (#48)"
new_repo; put "$W" pyproject.toml '[tool.poetry]
name = "x"
version = "1.4.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "poetry alone → exit 0" "$RC" 0
has "…and it is the version" "name=v1.4.0"
has "…named as the poetry source" "sources=poetry"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "--expect cannot stand in for the poetry version → exit 20" "$RC" 20
new_repo; plugin_json "$W" "" 1.4.0; put "$W" pyproject.toml '[tool.poetry]
version = "1.3.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "poetry disagrees with plugin.json → exit 20" "$RC" 20
new_repo; put "$W" pyproject.toml '[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"

[project]
name = "x"
dynamic = ["version"]

[tool.poetry]
version = "2.0.1"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "poetry 2: a dynamic version kept in [tool.poetry], poetry's backend stated → exit 0" "$RC" 0
has "…version 2.0.1" "name=v2.0.1"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.poetry]
version = "2.0.1"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.1
check "…the same file with no [build-system]: nothing says poetry supplies the dynamic version → exit 21" "$RC" 21
has "…and the message asks for the build backend" "build-backend"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "2.0.0"

[tool.poetry]
version = "2.0.1"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "[project].version and [tool.poetry].version differ → exit 20" "$RC" 20
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = 3'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 3.0.0
check "a poetry version that is not a string → exit 21, --expect does not replace it" "$RC" 21
new_repo; put "$W" pyproject.toml 'tool = { poetry = "x" }'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 3.0.0
check "[tool].poetry that is not a table is not a source → --expect is used" "$RC" 0

echo "== a version that comes from git tags is not a version source (#48: a closed list of three)"
for SCM in 'setuptools_scm|[build-system]
requires = ["setuptools", "setuptools-scm"]
build-backend = "setuptools.build_meta"

[project]
name = "x"
dynamic = ["version"]

[tool.setuptools_scm]' 'hatch-vcs|[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
source = "vcs"' 'poetry-dynamic-versioning|[build-system]
requires = ["poetry-core", "poetry-dynamic-versioning"]
build-backend = "poetry_dynamic_versioning.backend"

[tool.poetry]
name = "x"
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true'; do
  SCM_NAME=${SCM%%|*}
  new_repo; put "$W" pyproject.toml "${SCM#*|}"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
  check "$SCM_NAME with --expect → exit 0" "$RC" 0
  has "…the tag uses --expect" "name=v1.2.3"
  has "…and it says where the version comes from" "comes from git tags ($SCM_NAME)"
  run "$W" --dir . --commit HEAD --name-style v --dry-run
  check "$SCM_NAME without --expect → exit 21" "$RC" 21
  has "…with the same explanation" "comes from git tags ($SCM_NAME)"
done
new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml '[build-system]
requires = ["setuptools", "setuptools-scm"]
build-backend = "setuptools.build_meta"

[project]
name = "x"
dynamic = ["version"]

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "setuptools_scm next to a plugin.json → plugin.json decides, exit 0" "$RC" 0
has "…version 1.2.3" "name=v1.2.3"
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = "1.1.0"

[tool.poetry-dynamic-versioning]
enable = false'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "poetry-dynamic-versioning switched off → the poetry version counts" "$RC" 0
has "…version 1.1.0" "name=v1.1.0"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
source = "code"
path = "x.py"'; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "another hatch source is not on the list → still exit 21" "$RC" 21

echo "== a git-tag declaration never hides a version that is in the file (#48 verify R1)"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
path = "x.py"

[tool.setuptools_scm]
version_file = "x/_v.py"'; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "a [tool.setuptools_scm] table next to a hatch path: the path is read → exit 20" "$RC" 20
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "…and the matching release → exit 0" "$RC" 0
has "…read from the hatch file" "sources=hatch:x.py"
hasnt "…without a git-tag note" "comes from git tags"
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = "1.0.0"

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "a [tool.setuptools_scm] table next to [tool.poetry].version → exit 20" "$RC" 20
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = "1.0.0"

[tool.hatch.version]
source = "vcs"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "hatch source = vcs next to [tool.poetry].version → exit 20" "$RC" 20
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "1.0.0"

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a static [project].version next to a [tool.setuptools_scm] table → exit 0" "$RC" 0
has "…version 1.0.0" "name=v1.0.0"
hasnt "…and no git-tag note contradicts it" "comes from git tags"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "…and --expect cannot replace it → exit 20" "$RC" 20
new_repo; put "$W" pyproject.toml '[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
source = "vcs"
path = "x.py"'; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "hatch source = vcs does not use path, and neither does the helper → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (hatch-vcs)"
new_repo; put "$W" pyproject.toml '[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"

[project]
name = "x"
dynamic = ["version"]

[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "the poetry 2 layout with poetry-dynamic-versioning → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (poetry-dynamic-versioning)"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
path = 5

[tool.poetry]
version = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path that is not a string is a problem even next to a poetry version → exit 21" "$RC" 21

echo "== each git-tag backend is judged by its own table, and none hides another declaration (#48 verify R2)"
new_repo; put "$W" pyproject.toml '[build-system]
requires = ["poetry-core", "poetry-dynamic-versioning"]
build-backend = "poetry_dynamic_versioning.backend"

[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
check "poetry-dynamic-versioning next to a [tool.setuptools_scm] table: the placeholder is still not read → exit 0" "$RC" 0
has "…and the note names the backend that is stated" "comes from git tags (poetry-dynamic-versioning)"
hasnt "…not the table of a backend that is not" "setuptools_scm"
new_repo; put "$W" pyproject.toml '[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
source = "vcs"
path = "x.py"

[tool.setuptools_scm]'; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 2.0.0
check "hatch source = vcs next to a [tool.setuptools_scm] table: path is still not read → exit 0" "$RC" 0
has "…and the note names the backend that is stated" "comes from git tags (hatch-vcs)"
hasnt "…not the table of a backend that is not" "setuptools_scm"
for SETUPTOOLS in 'attr = "x.__version__"' 'file = "VERSION"'; do
  new_repo; put "$W" pyproject.toml "[project]
name = \"x\"
dynamic = [\"version\"]

[tool.setuptools.dynamic]
version = {$SETUPTOOLS}

[tool.setuptools_scm]"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
  check "setuptools ${SETUPTOOLS%% *} next to a [tool.setuptools_scm] table is still unreadable → exit 21" "$RC" 21
  has "…and the message names the table" "[tool.setuptools.dynamic]"
done
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]
source = "env"

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "another hatch source next to a [tool.setuptools_scm] table is still unreadable → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml '[project]
name = "x"
dynamic = ["version"]

[tool.hatch.version]

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
# verify R3: a [tool.hatch.version] table that is not source = "vcs" is read or it is a
# problem - hatch's regex source cannot work without a path, and 2.6.0 stopped here too
check "an empty [tool.hatch.version] table next to setuptools_scm is not explained away → exit 21" "$RC" 21
has "…and the message names the table" "[tool.hatch.version] has no path"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "1.2.3"

[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a static version next to a poetry-dynamic-versioning placeholder → exit 0" "$RC" 0
has "…version 1.2.3" "name=v1.2.3"
hasnt "…and the note does not say the version comes from git tags" "comes from git tags"
has "…it says the placeholder was not read" "placeholder"

echo "== a declaration the helper cannot read is exit 21 next to ANYTHING else in the file (#48 verify R3)"
# Rounds 1-3 each found one more neighbour that hid such a declaration (a git-tag
# table, a second git-tag table, a [tool.poetry].version): the checks ran as one
# if/elif chain and the first branch that matched won. The rule is per declaration,
# so the test is a matrix - every unreadable declaration next to every kind of
# neighbour, with a release that agrees with the readable sources (1.0.0) and one
# that does not (9.9.9). A neighbour that hides the declaration shows up as exit 0
# with the first and as exit 20 with the second.
dyn_pyproject() {   # a [project] whose version is dynamic, then each argument as a table
  local t
  printf '[project]\nname = "x"\ndynamic = ["version"]\n'
  for t in "$@"; do [ -z "$t" ] || printf '\n%s\n' "$t"; done
}
for U in 'setuptools attr|[tool.setuptools.dynamic]|[tool.setuptools.dynamic]
version = {attr = "x.__version__"}' 'setuptools file|[tool.setuptools.dynamic]|[tool.setuptools.dynamic]
version = {file = "VERSION"}' 'hatch source = env|hatch version source|[tool.hatch.version]
source = "env"' 'a hatch table without a path|[tool.hatch.version] has no path|[tool.hatch.version]
pattern = "v(?P<version>.+)"' 'a tool.hatch.version that is not a table|tool.hatch.version is not a table|[tool.hatch]
version = "x.py"'; do
  U_NAME=${U%%|*}; U_REST=${U#*|}; U_SAYS=${U_REST%%|*}; U_TOML=${U_REST#*|}
  for H in 'nothing else|' 'a [tool.poetry].version|[tool.poetry]
version = "1.0.0"' 'a hatch path|[tool.hatch.version]
path = "x.py"' 'hatch source = vcs|[tool.hatch.version]
source = "vcs"' 'a [tool.setuptools_scm] table|[tool.setuptools_scm]' 'a poetry-dynamic-versioning placeholder|[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true'; do
    H_NAME=${H%%|*}; H_TOML=${H#*|}
    # one file holds one [tool.hatch.version]; source = "code" with a path is covered above
    case "$U_TOML/$H_NAME" in "[tool.hatch"*"/a hatch path"|"[tool.hatch"*"/hatch source = vcs") continue ;; esac
    new_repo; put "$W" pyproject.toml "$(dyn_pyproject "$U_TOML" "$H_TOML")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
    for EXPECT in 1.0.0 9.9.9; do
      run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$EXPECT"
      check "$U_NAME next to $H_NAME, --expect $EXPECT → exit 21" "$RC" 21
    done
    has "…and the message names it" "$U_SAYS"
  done
done

echo "== the backend tables count only when [project].dynamic lists version and [project] states none (as in 2.6.0)"
# pyproject.toml specification, `dynamic`: "If the metadata does not list a key in
# dynamic, then a build back-end CANNOT fill in the requisite metadata on behalf of the
# user", and a back-end "MUST raise an error if the metadata specifies a key statically
# as well as being listed in dynamic" (the exception it makes is for a list or table
# that can be extended, which version is not). So in these files no build takes a
# version from the table (hatchling stops with "Field `project.version` can only be
# resolved dynamically if `version` is in field `project.dynamic`"). The helper has left
# such a table alone since #42; #48 does not change that, and these cases pin it.
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "1.0.0"

[tool.setuptools.dynamic]
version = {attr = "x.__version__"}'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a static version, dynamic not listed, next to a setuptools dynamic table → exit 0" "$RC" 0
has "…read from [project]" "sources=pyproject"
new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "1.0.0"
dynamic = ["version"]

[tool.setuptools.dynamic]
version = {attr = "x.__version__"}'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a version both static and listed in dynamic: the static one is read → exit 0" "$RC" 0
has "…read from [project]" "sources=pyproject"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "…and --expect cannot replace it → exit 20" "$RC" 20
for DEAD in 'a hatch path|[tool.hatch.version]
path = "x.py"' 'hatch source = env|[tool.hatch.version]
source = "env"' 'a setuptools dynamic table|[tool.setuptools.dynamic]
version = {attr = "x.__version__"}'; do
  new_repo; put "$W" pyproject.toml "[project]
name = \"x\"

${DEAD#*|}"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
  check "${DEAD%%|*} without version in dynamic is not consulted → exit 0" "$RC" 0
  has "…and --expect names the tag" "sources=--expect"
done
new_repo; put "$W" pyproject.toml '[project]
name = "x"

[tool.hatch.version]
source = "env"

[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 9.9.9
check "…the same next to a [tool.setuptools_scm] table → exit 0" "$RC" 0
# the specification quoted above means no back-end supplies a version here, from git tags
# or anywhere else, so the note that says it does is not printed (#48 pre-check)
hasnt "…and no note says the version comes from git tags" "comes from git tags"

echo "== the stated build backend decides what may stand for a dynamic version (#48 pre-check)"
# [build-system].build-backend is the one place a pyproject.toml says who supplies a
# dynamic version. The helper knows a CLOSED list of five backend strings, and a stated
# backend only ever takes a pass away. The four passes #48 added - the poetry 2 layout
# and the three git-tag declarations - hold only under their own backend, stated. A
# hatch path, which 2.6.0 read too, still counts when no backend is stated, and stops
# counting under a stated backend that is not hatchling. Before this, a table of a
# backend the helper does not know ([tool.pdm.version], say) was hidden by a
# [tool.poetry].version or a git-tag table next to it, and the run exited 0.
bs() { [ -z "$1" ] || printf '[build-system]\nrequires = [%s]\nbuild-backend = "%s"\n\n' "${2:-\"x\"}" "$1"; }
PLUGINS='"setuptools>=80", "setuptools_scm[toml]>=8", "hatch-vcs", "poetry-dynamic-versioning"'
PASS_POETRY2='[tool.poetry]
version = "1.0.0"'
PASS_SCM='[tool.setuptools_scm]'
PASS_HATCH_VCS='[tool.hatch.version]
source = "vcs"'
PASS_PDV='[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = true'
PASS_HATCH_PATH='[tool.hatch.version]
path = "x.py"'
for P in "the poetry 2 layout|poetry|$PASS_POETRY2" "a [tool.setuptools_scm] table|setuptools|$PASS_SCM" \
         "hatch source = vcs|hatch|$PASS_HATCH_VCS" "poetry-dynamic-versioning|poetry|$PASS_PDV" \
         "a hatch path|hatch-or-not-stated|$PASS_HATCH_PATH"; do
  P_NAME=${P%%|*}; P_REST=${P#*|}; P_FAMILY=${P_REST%%|*}; P_TOML=${P_REST#*|}
  # hatchling.ouroboros is hatchling's own bootstrap backend: the list is of whole strings, not prefixes
  for B in "|not-stated" "hatchling.build|hatch" "setuptools.build_meta|setuptools" "setuptools.build_meta:__legacy__|setuptools" \
           "poetry.core.masonry.api|poetry" "poetry_dynamic_versioning.backend|poetry" "pdm.backend|other" "hatchling.ouroboros|other"; do
    B_NAME=${B%%|*}; B_FAMILY=${B#*|}
    case "$P_FAMILY/$B_FAMILY" in
      poetry/poetry|setuptools/setuptools|hatch/hatch|hatch-or-not-stated/hatch|hatch-or-not-stated/not-stated) WANT=0 ;;
      *) WANT=21 ;;
    esac
    new_repo; put "$W" pyproject.toml "$(bs "$B_NAME" "$PLUGINS"; dyn_pyproject "$P_TOML")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
    run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
    check "$P_NAME, build-backend ${B_NAME:-not stated} → exit $WANT" "$RC" "$WANT"
  done
done
# the case as it was found: a backend the helper does not know, next to something that carried the run
for HIDER in "a [tool.poetry].version|$PASS_POETRY2" "a [tool.setuptools_scm] table|$PASS_SCM" "a hatch path|$PASS_HATCH_PATH"; do
  for B in "" "pdm.backend"; do
    new_repo; put "$W" pyproject.toml "$(bs "$B"; dyn_pyproject "${HIDER#*|}" '[tool.pdm.version]
source = "file"
path = "v.py"')"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" v.py '__version__ = "3.0.0"'; commit "$W"
    for EXPECT in 1.0.0 9.9.9; do
      # No backend stated and a hatch path: the helper cannot tell that the path is not
      # in use, and reads it - as 2.6.0 does. Stating the backend is what closes this.
      case "$B/${HIDER%%|*}/$EXPECT" in
        "/a hatch path/1.0.0") WANT=0 ;; "/a hatch path/9.9.9") WANT=20 ;; *) WANT=21 ;;
      esac
      run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$EXPECT"
      check "a [tool.pdm.version] next to ${HIDER%%|*}, build-backend ${B:-not stated}, --expect $EXPECT → exit $WANT" "$RC" "$WANT"
    done
    [ -z "$B" ] || has "…and the message names the backend" "pdm.backend"
    [ -z "$B" ] || has "…and says what the user can do" "state the version in [project]"
  done
done
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["hatchling"]\n\n'; dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a [build-system] table with no build-backend key states no backend: a hatch path is read → exit 0" "$RC" 0
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["poetry-core"]\n\n'; dyn_pyproject "$PASS_POETRY2")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "…and the poetry 2 layout is not carried by it → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nbuild-backend = 5\n\n'; dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a build-backend that is not a string is stated and matches nothing → exit 21" "$RC" 21
has "…and the message says so" "a build-backend that is not a string"
new_repo; put "$W" pyproject.toml "$(printf 'build-system = "hatchling.build"\n\n'; dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a build-system that is not a table matches nothing → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$(bs pdm.backend; printf '[project]\nname = "x"\nversion = "1.0.0"\n')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a static [project].version under a backend the helper does not know is still read → exit 0" "$RC" 0
has "…from [project]" "sources=pyproject"
# a version that comes from git tags in a tree with no [project] table (a setup.py project)
new_repo; put "$W" pyproject.toml "$(bs setuptools.build_meta '"setuptools", "setuptools-scm"'; printf '[tool.setuptools_scm]\n')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
check "no [project] table, a [tool.setuptools_scm] table, setuptools stated → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (setuptools_scm)"
new_repo; put "$W" pyproject.toml '[tool.setuptools_scm]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
check "…the same with no backend stated → exit 0, as in 2.6.0" "$RC" 0
hasnt "…but the note is not printed: nothing says setuptools is the backend" "comes from git tags"

# [tool.setuptools_scm] is the table of a plugin. An isolated build installs only what
# [build-system].requires lists, so without setuptools-scm there the table is not in use,
# and it does not explain anything (#48 second pre-check). Names are compared the way
# package indexes do: case, and - _ . , do not matter; a longer name is another package.
for R in 'requires = ["setuptools", "setuptools-scm"]|0' 'requires = ["setuptools", "setuptools_scm[toml]>=6.2"]|0' \
         'requires = ["setuptools", "Setuptools.SCM >= 8"]|0' 'requires = ["setuptools"]|21' \
         'requires = ["setuptools", "my-setuptools-scm"]|21' 'requires = ["setuptools", "setuptools-scm-git-archive"]|21' \
         'requires = "setuptools-scm"|21' 'requires = [["setuptools-scm"]]|21' '|21' \
         'requires = ["setuptools", "setuptools-scm (>=8)"]|0' \
         'requires = ["setuptools", "setuptools-scm @ https://example.com/setuptools_scm-8.0.0-py3-none-any.whl"]|0' \
         "requires = [\"setuptools\", \"setuptools-scm; python_version < '0'\"]|21" \
         "requires = [\"setuptools\", \"setuptools-scm>=8 ; python_version >= '3.9'\"]|21" \
         "requires = [\"setuptools\", \"setuptools_scm[toml]>=6.2;python_version>='3.9'\"]|21" \
         "requires = [\"setuptools\", \"setuptools-scm @ https://example.com/x.whl ; python_version < '0'\"]|21" \
         'requires = ["setuptools", "setuptools-scm @ https://example.com/a;b.whl"]|21' \
         "requires = [\"setuptools-scm<8; python_version < '3.9'\", \"setuptools-scm>=8; python_version >= '3.9'\"]|21" \
         "requires = [\"setuptools-scm; python_version < '0'\", \"setuptools-scm>=8\"]|0" \
         "requires = [\"setuptools\", \"setuptools-scm; sys_platform == 'win32'\"]|21" \
         'requires = ["setuptools", "  setuptools-scm >= 8"]|0'; do
  new_repo; put "$W" pyproject.toml "$(printf '[build-system]\n%s\nbuild-backend = "setuptools.build_meta"\n\n' "${R%|*}"; dyn_pyproject "$PASS_SCM")"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "a [tool.setuptools_scm] table under setuptools, ${R%|*} → exit ${R##*|}" "$RC" "${R##*|}"
  # the table and its backend are both there: the message has to name the one thing that is missing
  [ "${R##*|}" = 0 ] || has "…and the message says what is missing in requires" "has no setuptools-scm entry that counts"
done
# verify R4: a requirement with an environment marker (the text after `;`) is installed only
# where the marker holds, so it does not show that the plugin is part of the build - the
# helper cannot know the environment a build will run in, and does not evaluate markers. That
# is the last seven cases of the list above: one marker that never holds, two that normally do,
# a marker on a URL requirement, a `;` inside a URL (no marker, but the helper does not parse
# URLs and stops), two entries whose markers cover every case between them
# (still 21: neither is unconditional), and an unconditional entry next to a conditional one
# (0: the unconditional one counts). Verify R5 added the last two: a marker on a variable
# other than python_version (21), and white space before the name (0: a requirement may
# start with it). The message speaks of entries with a `;`, which is true of the URL case
# as well. The same file with [tool.setuptools_scm] removed stops with the general message,
# not with the one about requires.
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n\n'; dyn_pyproject)"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "dynamic version under setuptools with no [tool.setuptools_scm] table → exit 21" "$RC" 21
hasnt "…and the message is not the one about requires" "has no setuptools-scm entry"

# verify R4: a [project] table that neither states a version nor lists it in dynamic, next
# to a poetry-dynamic-versioning placeholder. No back-end fills a version in there, so the
# git-tag note would claim what cannot happen; the file gets the placeholder note.
new_repo; put "$W" pyproject.toml "$(bs poetry.core.masonry.api; printf '[project]\nname = "x"\n\n%s\n' "$PASS_PDV")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a [project] table with no version and no dynamic, next to a poetry-dynamic-versioning placeholder → exit 0, as in 2.6.0" "$RC" 0
hasnt "…and no note says the version comes from git tags (verify R4)" "comes from git tags"
has "…the placeholder note is printed instead" "placeholder of poetry-dynamic-versioning"

echo "== what sits next to pyproject.toml can take the version over (#48 verify R5)"
# verify R5: setuptools takes a version that setup.py or setup.cfg states before
# setuptools-scm supplies one - the wheel carried setup.py's 2.0.0 while the helper went on
# with --expect. The helper reads neither file, and setup.py is code, so their PRESENCE next
# to pyproject.toml is enough: [tool.setuptools_scm] then does not count. A setup.py that
# only calls setup(), or a setup.cfg with no version in it, stops the run as well; 2.6.0
# stopped on every one of these files. Names are compared without regard to case, because
# on a file system that ignores case setuptools opens Setup.py as setup.py.
SCM_OK="$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n'; dyn_pyproject "$PASS_SCM")"
for L in 'setup.py|from setuptools import setup
setup(version="2.0.0")|setup.py' 'setup.cfg|[metadata]
version = 3.0.0|setup.cfg' 'setup.py|from setuptools import setup
setup()|setup.py' 'setup.cfg|[flake8]
max-line-length = 100|setup.cfg' 'Setup.py|from setuptools import setup
setup(version="2.0.0")|setup.py'; do
  NAME="${L%%|*}"; REST="${L#*|}"; BODY="${REST%|*}"; SHOWN="${REST##*|}"
  new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" "$NAME" "$BODY"; commit "$W"
  for E in 1.0.0 9.9.9; do
    run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$E"
    check "[tool.setuptools_scm] with $NAME next to it ($(printf '%s' "$BODY" | tail -n 1)), --expect $E → exit 21" "$RC" 21
  done
  has "…the message names the file" "the directory also holds $SHOWN"
  hasnt "…and no note says the version comes from git tags" "comes from git tags"
done
new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" setup.py 'from setuptools import setup; setup()'; put "$W" setup.cfg '[metadata]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "both setup.py and setup.cfg next to it → exit 21" "$RC" 21
has "…and both are named" "the directory also holds setup.cfg, setup.py"
new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" tools/setup.py 'from setuptools import setup; setup(version="2.0.0")'; put "$W" docs/setup.cfg '[metadata]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "setup.py and setup.cfg in other directories only → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (setuptools_scm)"
new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" setup.py/notes.txt 'a directory, not a file'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a DIRECTORY named setup.py is not the file → exit 0" "$RC" 0
new_repo; put "$W" pkg/pyproject.toml "$SCM_OK"; put "$W" pkg/setup.py 'from setuptools import setup; setup()'; commit "$W"
run "$W" --dir pkg --commit HEAD --name-style v --dry-run --expect 1.0.0
check "--dir pkg with pkg/setup.py → exit 21" "$RC" 21
new_repo; put "$W" pkg/pyproject.toml "$SCM_OK"; put "$W" setup.py 'from setuptools import setup; setup()'; commit "$W"
run "$W" --dir pkg --commit HEAD --name-style v --dry-run --expect 1.0.0
check "--dir pkg with setup.py at the repository root only → exit 0: it is not next to pkg/pyproject.toml" "$RC" 0
# the two reasons a [tool.setuptools_scm] table may not count are each reported
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n\n'; dyn_pyproject "$PASS_SCM")"; put "$W" setup.cfg '[metadata]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "setup.cfg next to it AND setuptools-scm missing from requires → exit 21" "$RC" 21
has "…the requires reason is reported" "has no setuptools-scm entry that counts"
has "…and so is the file" "the directory also holds setup.cfg"
# only that one pass is taken away: everything else reads as before
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n[project]\nname = "x"\nversion = "1.0.0"\n\n%s\n' "$PASS_SCM")"; put "$W" setup.py 'from setuptools import setup; setup()'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a static [project].version with setup.py next to it → exit 0: the tables are not consulted" "$RC" 0
has "…from [project]" "sources=pyproject"
hasnt "…and no note about a missing [project] table" "no [project] table"
new_repo; put "$W" pyproject.toml "$(bs hatchling.build '"hatchling"'; dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" setup.py 'from setuptools import setup; setup(version="2.0.0")'; put "$W" setup.cfg '[metadata]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path under hatchling with setup.py and setup.cfg next to it → exit 0: hatchling does not read them" "$RC" 0
new_repo; put "$W" pyproject.toml "$(bs poetry.core.masonry.api '"poetry-core>=2"'; dyn_pyproject "$PASS_POETRY2")"; put "$W" setup.cfg '[metadata]
version = 3.0.0'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "the poetry 2 layout with setup.cfg next to it → exit 0" "$RC" 0
# a tree with no [project] table is not this case. 2.6.0 went on with the other sources or
# --expect there, and so does the helper now: setup.py and setup.cfg have never been version
# sources (a known limit, written in the README). The git-tag note is not printed, though:
# with setup.cfg in the directory the helper cannot say where the version comes from.
new_repo; put "$W" pyproject.toml "$(bs setuptools.build_meta '"setuptools", "setuptools-scm"'; printf '[tool.setuptools_scm]\n')"; put "$W" setup.cfg '[metadata]
name = x
version = 3.0.0'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
check "no [project] table, [tool.setuptools_scm], and a setup.cfg that states a version → exit 0, as in 2.6.0" "$RC" 0
hasnt "…but no note says the version comes from git tags" "comes from git tags"
has "…and a note says setup.cfg is not read" "setup.cfg next to it can state the version"
# --at-bump reads the same way at every commit it walks: a bump commit that still had
# setup.py cannot be told from one whose version setup.py set
new_repo; plugin_json "$W" "" 1.0.0; put "$W" pyproject.toml "$SCM_OK"; put "$W" setup.py 'from setuptools import setup; setup()'; commit "$W" "bump"
git -C "$W" rm -q setup.py; commit "$W" "drop setup.py"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "setup.py deleted after the bump: the current commit reads → exit 0" "$RC" 0
run "$W" --dir . --commit HEAD --name-style v --dry-run --at-bump
check "…but --at-bump stops at the bump commit, which still had it → exit 21" "$RC" 21

# hatchling merges hatch.toml over [tool.hatch], one top-level key at a time (hatchling
# metadata/core.py, read 2026-11-15): a `version` key there REPLACES [tool.hatch.version],
# and a `metadata` key replaces [tool.hatch.metadata]. The wheel carried the 2.0.0 of the
# path hatch.toml names while pyproject.toml said source = "vcs". The helper reads
# pyproject.toml only, so a version key in hatch.toml stops the run whenever hatch is the
# one building (hatchling.build stated, or no backend stated).
HATCH_VCS_OK="$(bs hatchling.build '"hatchling", "hatch-vcs"'; dyn_pyproject "$PASS_HATCH_VCS")"
HATCH_PATH_OK="$(bs hatchling.build '"hatchling"'; dyn_pyproject "$PASS_HATCH_PATH")"
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" hatch.toml '[version]
path = "about.py"'; put "$W" about.py '__version__ = "2.0.0"'; commit "$W"
for E in 1.0.0 2.0.0; do
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$E"
  check "source = \"vcs\" with a [version] table in hatch.toml, --expect $E → exit 21" "$RC" 21
done
has "…the message names hatch.toml" "hatch.toml: has a version key"
hasnt "…and no note says the version comes from git tags" "comes from git tags"
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" hatch.toml '[envs.default]
dependencies = ["pytest"]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with a hatch.toml that has no version key → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (hatch-vcs)"
new_repo; put "$W" pyproject.toml "$HATCH_PATH_OK"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" hatch.toml '[version]
path = "y.py"'; put "$W" y.py '__version__ = "2.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path with a [version] table in hatch.toml → exit 21 (2.6.0 compared the file hatchling does not use)" "$RC" 21
has "…the message names hatch.toml" "hatch.toml: has a version key"
for BAD in '[version|not valid TOML' 'version = "x.py"|has a version key'; do
  new_repo; put "$W" pyproject.toml "$HATCH_PATH_OK"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" hatch.toml "${BAD%|*}"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "a hatch path with hatch.toml holding: ${BAD%|*} → exit 21" "$RC" 21
  has "…and the message says why" "hatch.toml: ${BAD##*|}"
done
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" Hatch.toml '[version]
path = "about.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "the same file named Hatch.toml → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$(dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" hatch.toml '[version]
path = "y.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path with no backend stated and a [version] table in hatch.toml → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n'; dyn_pyproject "$PASS_SCM" "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" hatch.toml '[version]
path = "y.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "setuptools stated, with a leftover hatch path and hatch.toml → exit 0: hatch is not the one building" "$RC" 0
hasnt "…and hatch.toml is not mentioned" "hatch.toml"
new_repo; put "$W" pyproject.toml "$(bs hatchling.build '"hatchling"'; printf '[project]\nname = "x"\nversion = "1.0.0"\n')"; put "$W" hatch.toml '[version]
path = "y.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a static [project].version with a [version] table in hatch.toml → exit 0: the tables are not consulted" "$RC" 0
new_repo; put "$W" pyproject.toml "$(bs hatchling.build '"hatchling", "hatch-vcs"'; printf '%s\n' "$PASS_HATCH_VCS")"; put "$W" hatch.toml '[version]
path = "about.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "no [project] table, source = \"vcs\" and a [version] table in hatch.toml → exit 0, as in 2.6.0" "$RC" 0
hasnt "…but no note says the version comes from git tags" "comes from git tags"
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" docs/hatch.toml '[version]
path = "about.py"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "hatch.toml in another directory only → exit 0" "$RC" 0
# a `custom` metadata hook is code in the tree (hatch_build.py) that may set any field
# listed in dynamic, the version included: the wheel carried the hook's 2.0.0 next to
# source = "vcs". Like setup.py, its presence is enough for the git-tag declaration not to
# count. A hook that is a named plugin is not looked at, and a hatch PATH is read as in
# 2.6.0 whatever hooks there are (both are known limits, written in the README).
HOOK='[tool.hatch.metadata.hooks.custom]'
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n%s\n' "$HATCH_VCS_OK" "$HOOK")"; commit "$W"
for E in 1.0.0 2.0.0; do
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$E"
  check "source = \"vcs\" with a custom metadata hook, --expect $E → exit 21" "$RC" 21
done
has "…the message names the hook" "a custom metadata hook"
hasnt "…and no note says the version comes from git tags" "comes from git tags"
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n%s\n' "$HATCH_VCS_OK" '[tool.hatch.metadata.hooks.fancy-pypi-readme]
content-type = "text/markdown"')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with a metadata hook that is a named plugin → exit 0" "$RC" 0
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" hatch.toml '[metadata.hooks.custom]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with the custom hook declared in hatch.toml → exit 21" "$RC" 21
has "…the message names the hook" "a custom metadata hook"
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n%s\n' "$HATCH_VCS_OK" "$HOOK")"; put "$W" hatch.toml '[metadata]
allow-direct-references = true'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a [metadata] table in hatch.toml replaces the one in pyproject.toml, its custom hook included → exit 0" "$RC" 0
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n%s\n' "$HATCH_PATH_OK" "$HOOK")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path with a custom metadata hook → exit 0, as in 2.6.0" "$RC" 0

# poetry-dynamic-versioning reads the version from a FILE when its table has a from-file
# table (the wheel carried the 2.0.0 of the file it names). The placeholder is still not
# read, but the declaration no longer says "git tags", so it does not count.
PDV_OWN="$(bs poetry_dynamic_versioning.backend '"poetry-core>=1.0.0", "poetry-dynamic-versioning>=1.0.0,<2.0.0"'; dyn_pyproject "$PASS_PDV")"
for FF in '[tool.poetry-dynamic-versioning.from-file]
source = "VERSION"' '[tool.poetry-dynamic-versioning.from-file]'; do
  new_repo; put "$W" pyproject.toml "$(printf '%s\n\n%s\n' "$PDV_OWN" "$FF")"; put "$W" VERSION '2.0.0'; commit "$W"
  for E in 1.0.0 2.0.0; do
    run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$E"
    check "poetry-dynamic-versioning with $(printf '%s' "$FF" | tail -n 1), --expect $E → exit 21" "$RC" 21
  done
  has "…the message names the table" "has a from-file table"
  hasnt "…and no note says the version comes from git tags" "comes from git tags"
done
new_repo; put "$W" pyproject.toml "$PDV_OWN"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "the same file without from-file → exit 0" "$RC" 0
has "…with the git-tag note" "comes from git tags (poetry-dynamic-versioning)"
new_repo; put "$W" pyproject.toml "$(bs poetry_dynamic_versioning.backend '"poetry-core>=1.0.0", "poetry-dynamic-versioning>=1.0.0,<2.0.0"'; printf '%s\n\n[tool.poetry-dynamic-versioning.from-file]\nsource = "VERSION"\n' "$PASS_PDV")"; put "$W" VERSION '2.0.0'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a poetry 1 file (no [project] table) with from-file → exit 0, as in 2.6.0" "$RC" 0
hasnt "…but no note says the version comes from git tags" "comes from git tags"
has "…the placeholder note is printed instead" "placeholder of poetry-dynamic-versioning"

# verify R5: with no [project] table, a [tool.poetry].version that IS read (no placeholder),
# and a git-tag declaration that would count, the file gave a source - the git-tag note
# would say the opposite
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n%s\n\n%s\n' "$PASS_POETRY2" "$PASS_SCM")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "no [project] table, a [tool.poetry].version and a [tool.setuptools_scm] table that counts → exit 0" "$RC" 0
has "…the poetry version is the source" "sources=poetry"
hasnt "…and no note says the version comes from git tags" "comes from git tags"

echo "== known overrides found in round 6: PKG-INFO, [tool.distutils.egg_info], two spellings of hatch.toml (#48 verify R6)"
# What exit 0 promises for a git-tag declaration (written on the issue on 2026-11-16): the
# helper recognises the declaration and found none of the known overrides
# below; it does not promise that the wheel carries the tag's version. Round 6 found three
# more overrides, each measured with a real build (tag v1.2.3).
#
# PKG-INFO next to pyproject.toml: hatchling takes every field `dynamic` lists from it, the
# version included (hatchling metadata/core.py core_raw_metadata): the wheel was 6.6.6 for
# source = "vcs" and for a hatch path that said 1.2.3. setuptools-scm took it too when it did
# not find the git repository (pyproject.toml in a subdirectory). poetry-core did not read it
# (both poetry layouts built 1.2.3).
PKGINFO='Metadata-Version: 2.1
Name: x
Version: 6.6.6'
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
for E in 1.0.0 6.6.6; do
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect "$E"
  check "source = \"vcs\" with PKG-INFO next to it, --expect $E → exit 21" "$RC" 21
done
has "…the message names PKG-INFO" "PKG-INFO"
hasnt "…and no note says the version comes from git tags" "comes from git tags"
new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "[tool.setuptools_scm] with PKG-INFO next to it → exit 21" "$RC" 21
has "…the message names PKG-INFO" "the directory also holds PKG-INFO"
new_repo; put "$W" pkg/pyproject.toml "$SCM_OK"; put "$W" pkg/PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir pkg --commit HEAD --name-style v --dry-run --expect 1.0.0
check "--dir pkg with pkg/PKG-INFO next to [tool.setuptools_scm] → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" pkg-info "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "the same file named pkg-info → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$HATCH_PATH_OK"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path under hatchling with PKG-INFO next to it → exit 21 (2.6.0 compared the file hatchling does not use)" "$RC" 21
has "…the message names PKG-INFO" "PKG-INFO: "
new_repo; put "$W" pyproject.toml "$(dyn_pyproject "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path with no backend stated and PKG-INFO → exit 21" "$RC" 21
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n[project]\nname = "x"\nversion = "1.0.0"\n\n%s\n' "$PASS_SCM")"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a static [project].version with PKG-INFO → exit 0: only fields in dynamic are taken from it" "$RC" 0
new_repo; put "$W" pyproject.toml "$PDV_OWN"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "poetry-dynamic-versioning with PKG-INFO → exit 0: poetry-core does not read it" "$RC" 0
has "…with the git-tag note" "comes from git tags (poetry-dynamic-versioning)"
new_repo; put "$W" pyproject.toml "$(bs poetry.core.masonry.api '"poetry-core>=2"'; dyn_pyproject "$PASS_POETRY2")"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "the poetry 2 layout with PKG-INFO → exit 0" "$RC" 0
new_repo; put "$W" pyproject.toml "$(bs hatchling.build '"hatchling", "hatch-vcs"'; printf '%s\n' "$PASS_HATCH_VCS")"; put "$W" PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "no [project] table, source = \"vcs\" and PKG-INFO → exit 0, as in 2.6.0" "$RC" 0
hasnt "…but no note says the version comes from git tags" "comes from git tags"
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" dist/x-1.0/PKG-INFO "$PKGINFO"; put "$W" x.egg-info/PKG-INFO "$PKGINFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "PKG-INFO in other directories only (an unpacked sdist, an egg-info) → exit 0" "$RC" 0

# [tool.distutils.egg_info] in pyproject.toml: setuptools adds its tag_build or tag_date to
# the version setuptools-scm computes (the wheel was 1.2.3.post9, and 1.2.3<date>). It is the
# pyproject spelling of setup.cfg's [egg_info], which stops the run by presence already.
for EG in 'tag_build = ".post9"' 'tag_date = true' ''; do
  new_repo; put "$W" pyproject.toml "$(printf '%s\n\n[tool.distutils.egg_info]\n%s\n' "$SCM_OK" "$EG")"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "[tool.setuptools_scm] with [tool.distutils.egg_info] ${EG:-(empty)} → exit 21" "$RC" 21
  has "…the message names the table" "[tool.distutils.egg_info]"
  hasnt "…and no note says the version comes from git tags" "comes from git tags"
done
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n[tool.distutils.bdist_wheel]\nuniversal = true\n' "$SCM_OK")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "[tool.setuptools_scm] with another distutils command's table → exit 0" "$RC" 0
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n[tool.distutils.egg_info]\ntag_build = ".post9"\n' "$HATCH_VCS_OK")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with [tool.distutils.egg_info] → exit 0: hatchling does not use it" "$RC" 0

# Two files whose names differ only in letter case (a case-sensitive file system allows it,
# and git keeps both): hatchling opens the exact name hatch.toml, while on a file system that
# ignores case only one of the two is checked out. The helper used to read the first one git
# lists (Hatch.toml) and never saw a version key in hatch.toml. Built with update-index,
# because this file system cannot hold both.
two_names() {   # two_names <work> <name1> <text1> <name2> <text2>: commit both without a work tree
  local b1 b2
  b1=$(printf '%s\n' "$3" | git -C "$1" hash-object -w --stdin)
  b2=$(printf '%s\n' "$5" | git -C "$1" hash-object -w --stdin)
  git -C "$1" update-index --add --cacheinfo "100644,$b1,$2" --cacheinfo "100644,$b2,$4"
  git -C "$1" commit -qm two-names && git -C "$1" push -q origin main 2>/dev/null
}
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; git -C "$W" add pyproject.toml
two_names "$W" Hatch.toml '[envs.default]' hatch.toml '[version]
path = "about.py"'
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with both Hatch.toml and hatch.toml → exit 21" "$RC" 21
has "…the message says why" "letter case"
new_repo; put "$W" pyproject.toml "$HATCH_PATH_OK"; put "$W" x.py '__version__ = "1.0.0"'; git -C "$W" add pyproject.toml x.py
two_names "$W" HATCH.TOML '[envs.default]' hatch.toml '[envs.lint]'
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a hatch path with HATCH.TOML and hatch.toml, neither with a version key → exit 21: which one is built from is not known" "$RC" 21

# round 6's mutation tests: three conditions no test pinned
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" hatch.toml 'version = ""'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "hatch.toml with an empty version value → exit 21: the key's presence is enough" "$RC" 21
has "…and the message says why" "hatch.toml: has a version key"
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" hatch.toml "x = $(printf '%*s' 5000 '' | tr ' ' '[')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "hatch.toml nested 5000 deep → exit 21" "$RC" 21
has "…as TOML that cannot be read" "hatch.toml: not valid TOML"
if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
new_repo; put "$W" pyproject.toml "$(printf '[build-system]\nrequires = ["setuptools>=64", "setuptools-scm>=8"]\nbuild-backend = "setuptools.build_meta"\n\n[project]\nname = "x"\n\n%s\n' "$PASS_SCM")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a [project] table with neither a version nor dynamic, and [tool.setuptools_scm] → exit 0" "$RC" 0
hasnt "…and no git-tag note: no back-end supplies a version there" "comes from git tags"

# an integer too long for Python to convert is a ValueError that is not a TOMLDecodeError
for WHERE in pyproject.toml hatch.toml; do
  new_repo
  if [ "$WHERE" = hatch.toml ]; then put "$W" pyproject.toml "$HATCH_VCS_OK"; fi
  put "$W" "$WHERE" "n = $(printf '%*s' 5000 '' | tr ' ' '9')"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "$WHERE with a 5000-digit integer → exit 21" "$RC" 21
  has "…as TOML that cannot be read" "$WHERE: not valid TOML"
  if printf '%s' "$OUT" | grep -q 'Traceback'; then bad "…printed a Python traceback" "$OUT"; else ok "…without a Python traceback"; fi
done

# verify R7: setuptools reads every [tool.distutils] command name lower-cased with "-" as "_"
# (_apply_pyprojecttoml.py, _copy_command_options), so these are the same table (measured:
# wheel 1.2.3.post9 while the helper exited 0 for egg-info)
for EGN in egg-info EGG_INFO Egg-Info; do
  new_repo; put "$W" pyproject.toml "$(printf '%s\n\n[tool.distutils.%s]\ntag_build = ".post9"\n' "$SCM_OK" "$EGN")"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "[tool.setuptools_scm] with [tool.distutils.$EGN] → exit 21" "$RC" 21
  has "…the message names the table" "[tool.distutils.egg_info]"
done
new_repo; put "$W" pyproject.toml "$(printf '%s\n\n[tool.distutils.egg_info]\ntag_build = ".post9"\n' "$PDV_OWN")"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "poetry-dynamic-versioning with [tool.distutils.egg_info] → exit 0: poetry does not use it" "$RC" 0
# verify R7: str.lower() left U+017F (long s) alone, and a file system that ignores case
# opens that file as setup.py (measured on APFS: wheel 9.9.9)
new_repo; put "$W" pyproject.toml "$SCM_OK"; put "$W" "$(printf '\305\277')etup.py" 'from setuptools import setup; setup(version="9.9.9")'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "[tool.setuptools_scm] with setup.py spelled with U+017F → exit 21" "$RC" 21
# a symbolic link named PKG-INFO is read by hatchling like the file it points to
new_repo; put "$W" pyproject.toml "$HATCH_VCS_OK"; put "$W" meta.txt "$PKGINFO"; ln -s meta.txt "$W/PKG-INFO"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "source = \"vcs\" with a symbolic link named PKG-INFO → exit 21" "$RC" 21
# the no-[project] note names both files, and poetry-dynamic-versioning keeps its git-tag note
new_repo; put "$W" pyproject.toml "$(bs setuptools.build_meta '"setuptools", "setuptools-scm"'; printf '[tool.setuptools_scm]\n')"; put "$W" setup.py 'from setuptools import setup; setup()'; put "$W" setup.cfg '[metadata]'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "no [project] table, [tool.setuptools_scm], setup.py and setup.cfg → exit 0, as in 2.6.0" "$RC" 0
has "…the note names both files" "setup.cfg, setup.py next to it can state the version, and this helper does not read them"
new_repo; put "$W" pyproject.toml "$(bs poetry_dynamic_versioning.backend '"poetry-core>=1.0.0", "poetry-dynamic-versioning>=1.0.0,<2.0.0"'; printf '%s\n' "$PASS_PDV")"; put "$W" setup.py 'from setuptools import setup; setup()'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a poetry 1 file with poetry-dynamic-versioning and a setup.py → exit 0" "$RC" 0
has "…its git-tag note stays" "comes from git tags (poetry-dynamic-versioning)"
has "…next to the note about setup.py" "setup.py next to it can state the version"

# what the git-tag note says, now that the promise is written down
new_repo; put "$W" pyproject.toml "$SCM_OK"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "[tool.setuptools_scm] alone → exit 0" "$RC" 0
has "…the note says what is not checked" "what the build makes of the tag is not checked"

echo "== two declarations the helper cannot read: each is reported, neither hides the other (#48 second pre-check)"
new_repo; put "$W" pyproject.toml "$(dyn_pyproject '[tool.setuptools.dynamic]
version = {attr = "x.__version__"}' '[tool.hatch.version]
source = "env"')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
check "a setuptools dynamic table and another hatch source → exit 21" "$RC" 21
has "…the setuptools table is reported" "[tool.setuptools.dynamic]"
has "…and so is the hatch source" "hatch version source"
new_repo; put "$W" pyproject.toml "$(dyn_pyproject '[tool.setuptools.dynamic]
version = {attr = "x.__version__"}' '[tool.hatch]
version = "x.py"')"; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
has "a setuptools dynamic table and a tool.hatch.version that is not a table: the first is reported" "[tool.setuptools.dynamic]"
has "…and so is the second" "tool.hatch.version is not a table"
new_repo; put "$W" pyproject.toml "$(dyn_pyproject '[tool.setuptools.dynamic]
version = {attr = "x.__version__"}' "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
has "a setuptools dynamic table does not stop the hatch path from being read" "sources=hatch:x.py"

echo "== messages that say what to do (#48 pre-check)"
new_repo; put "$W" pyproject.toml "$(dyn_pyproject '[tool.setuptools.dynamic]
version = {attr = "x.__version__"}' "$PASS_HATCH_PATH")"; put "$W" x.py '__version__ = "1.0.0"'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
has "a setuptools dynamic table next to a hatch path: the message says to delete the table" "delete the table"
hasnt "…and does not suggest a hatch path, which the file already has" "use a [tool.hatch.version] path"
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = "0.0.0"

[tool.poetry-dynamic-versioning]
enable = false'; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.2.3
check "a poetry placeholder with enable = false in the file is read as the version → exit 20" "$RC" 20
has "…and a note says what would make it a placeholder" "enable = true"

echo "== --at-bump finds the commit that set a poetry version (#48 verify R1)"
new_repo; put "$W" pyproject.toml '[tool.poetry]
version = "1.0.0"'; commit "$W" one
put "$W" pyproject.toml '[tool.poetry]
version = "1.1.0"'; commit "$W" bump; BUMP=$(git -C "$W" rev-parse --short HEAD)
put "$W" README.md later; commit "$W" later
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "exit 0" "$RC" 0
has "…and the tag goes on the bump commit" "name=v1.1.0 commit=$BUMP"

echo "== setuptools dynamic versions stop with a message that names them (#48)"
for SETUPTOOLS in 'attr = "x.__version__"' 'file = "VERSION"'; do
  new_repo; put "$W" pyproject.toml "[project]
name = \"x\"
dynamic = [\"version\"]

[tool.setuptools.dynamic]
version = {$SETUPTOOLS}"; commit "$W"
  run "$W" --dir . --commit HEAD --name-style v --dry-run --expect 1.0.0
  check "setuptools ${SETUPTOOLS%% *} → exit 21" "$RC" 21
  has "…and the message names the table" "[tool.setuptools.dynamic]"
done

echo "== no TOML parser — a python3 older than 3.11 without tomli (#48)"
# RELEASE_TAG_NO_TOML=1 switches the parser off inside the helper, as an old python3 would
no_toml() { local w="$1"; shift; OUT=$(cd "$w" && RELEASE_TAG_NO_TOML=1 "${RT_BASH:-bash}" "$HELPER" "$@" 2>&1); RC=$?; }
new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml '[tool.ruff]
line-length = 100
target-version = "py311"

[tool.mypy]
python_version = "3.11"

[tool.pytest.ini_options]
minversion = "8.0"

[tool.setuptools_scm]
version_file = "x/_version.py"'; commit "$W"
no_toml "$W" --dir . --commit HEAD --name-style v --dry-run
check "a pyproject.toml with no version key does not stop the run → exit 0" "$RC" 0
has "…plugin.json decides" "name=v1.2.3"
has "…and a note says why the pyproject was left out" "has no version key"
no_toml "$W" --dir . --commit HEAD --name-style v --dry-run --at-bump
check "…with --at-bump too → exit 0" "$RC" 0
for KEYLINE in 'project.version = "9.9.9"' '"version" = "9.9.9"' 'project = { version = "9.9.9" }' 'dynamic = ["version"]'; do
  new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml "$KEYLINE"; commit "$W"
  no_toml "$W" --dir . --commit HEAD --name-style v --dry-run
  check "a version key written as [$KEYLINE] → exit 21" "$RC" 21
done
new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml '[project]
name = "x"
version = "1.2.3"'; commit "$W"
no_toml "$W" --dir . --commit HEAD --name-style v --dry-run
check "a pyproject.toml that mentions a version cannot be read → exit 21" "$RC" 21
has "…and the message says what is needed" "tomli"
new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml '[tool.poetry]
Version = "9.9.9"'; commit "$W"
no_toml "$W" --dir . --commit HEAD --name-style v --dry-run
check "the word in another case is still a mention → exit 21" "$RC" 21
for ESC in u0076 U00000076 x76; do
  # the key is "version" with its first letter written as an escape: no `version` token in the text
  new_repo; plugin_json "$W" "" 1.2.3; put "$W" pyproject.toml "[project]
\"\\${ESC}ersion\" = \"9.9.9\""; commit "$W"
  if grep -q 'version' "$W/pyproject.toml"; then bad "the fixture for \\$ESC must not contain the word itself"; fi
  no_toml "$W" --dir . --commit HEAD --name-style v --dry-run
  check "a key spelled with a \\$ESC escape → exit 21" "$RC" 21
done

echo "== an old python3 first on PATH: the helper looks for a python3.N that has tomllib (#48)"
REAL_PY=$(command -v python3)
if "$REAL_PY" -I -c 'import tomllib' 2>/dev/null; then
  # oldpy/python3 stands in for an old python3: the helper's probe (-I -c 'import tomllib')
  # fails, and everything else runs without a parser
  mkdir -p "$T/oldpy" "$T/newpy" "$T/nopy"
  printf '%s\n' '#!/bin/sh' '[ "$*" = "-I -c import tomllib" ] && exit 1' \
    "RELEASE_TAG_NO_TOML=1 exec \"$REAL_PY\" \"\$@\"" > "$T/oldpy/python3"
  printf '%s\n' '#!/bin/sh' "exec \"$REAL_PY\" \"\$@\"" > "$T/newpy/python3.99"
  chmod +x "$T/oldpy/python3" "$T/newpy/python3.99"
  cp "$T/oldpy/python3" "$T/nopy/python3"
  new_repo; put "$W" pyproject.toml '[project]
name = "x"
version = "1.2.3"'; commit "$W"
  OUT=$(cd "$W" && PATH="$T/oldpy:$T/newpy:$PATH" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
  check "a python3.N further down PATH is used → exit 0" "$RC" 0
  has "…and the pyproject version is read" "name=v1.2.3"
  # a python3.N in the repository itself is not a candidate, even with the current directory on PATH
  printf '%s\n' '#!/bin/sh' "touch \"$T/ran-from-the-repo\"" "exec \"$REAL_PY\" \"\$@\"" > "$W/python3.98"; chmod +x "$W/python3.98"
  OUT=$(cd "$W" && PATH="$T/oldpy::.:/usr/bin:/bin" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
  if [ -e "$T/ran-from-the-repo" ]; then bad "a python3.N in the current directory was run" "$OUT"; else ok "a python3.N in the current directory is not run"; fi
  rm -f "$W/python3.98"
  # no candidate at all: only possible to show where the system directories hold no python3.N with tomllib
  SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  if [ -x /usr/bin/git ] && ! (for f in /usr/bin/python3.[0-9]* /bin/python3.[0-9]* /usr/sbin/python3.[0-9]* /sbin/python3.[0-9]*; do
         [ -x "$f" ] && "$f" -I -c 'import tomllib' 2>/dev/null && exit 0; done; exit 1); then
    OUT=$(cd "$W" && PATH="$T/nopy:$SYS_PATH" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
    check "no python3 on PATH has tomllib → exit 21" "$RC" 21
    has "…and the message says what is needed" "tomli"
  else
    echo "  - skipped: the system directories hold a python3.N with tomllib, so 'none on PATH' cannot be shown here"
  fi

  echo "== tomli in the user's site-packages is found although python3 runs isolated (#48 verify R1)"
  mkdir -p "$T/uhome" "$T/nohome"
  USER_SITE=$(HOME="$T/uhome" "$REAL_PY" -I -c 'import site; print(site.getusersitepackages())')
  case "$USER_SITE" in
    "$T/uhome"/*)
      mkdir -p "$USER_SITE/tomli"
      # a stand-in for the tomli package: the two names the helper uses
      printf '%s\n' 'from tomllib import loads, TOMLDecodeError' > "$USER_SITE/tomli/__init__.py"
      OUT=$(cd "$W" && HOME="$T/uhome" RELEASE_TAG_NO_TOML=tomllib "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
      check "tomllib hidden, tomli installed for the user → exit 0" "$RC" 0
      has "…and the pyproject version is read" "name=v1.2.3"
      if "$REAL_PY" -I -c 'import tomli' 2>/dev/null; then
        echo "  - skipped: this python3 has tomli in its own site-packages, so 'no tomli anywhere' cannot be shown"
      else
        OUT=$(cd "$W" && HOME="$T/nohome" RELEASE_TAG_NO_TOML=tomllib "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
        check "tomllib hidden and no tomli anywhere → exit 21" "$RC" 21
        has "…and the message says what is needed" "tomli"
        # a relative user base is the current directory, i.e. the repository under inspection (#48 verify R2)
        REL_SITE=$(cd "$W" && PYTHONUSERBASE=. "$REAL_PY" -I -c 'import site; print(site.getusersitepackages())')
        case "$REL_SITE" in
          /*) echo "  - skipped: this python3 makes the user site absolute ($REL_SITE)" ;;
          *)  mkdir -p "$W/$REL_SITE/tomli"
              printf '%s\n' 'import os' "open(os.environ['RT_MARK'], 'w').close()" 'from tomllib import loads, TOMLDecodeError' > "$W/$REL_SITE/tomli/__init__.py"
              OUT=$(cd "$W" && RT_MARK="$T/tomli-from-repo" HOME="$T/nohome" PYTHONUSERBASE=. RELEASE_TAG_NO_TOML=tomllib "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
              if [ -e "$T/tomli-from-repo" ]; then bad "a tomli inside the repository was imported through a relative user base" "$OUT"; else ok "a relative user base is refused: the repository cannot supply tomli"; fi
              check "…and the run is unreadable → exit 21" "$RC" 21 ;;
        esac
      fi ;;
    *) echo "  - skipped: this python3 does not place the user site under HOME ($USER_SITE)" ;;
  esac
else
  echo "  - skipped: this machine's python3 has no tomllib"
fi

echo "== --dry-run makes the lookups a real run makes, and creates nothing (#51)"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "nothing in the way → exit 0" "$RC" 0
has "…dry-run" "RELEASE_TAG: dry-run name=v1.2.3"
check "…no tag locally" "$(git -C "$W" tag -l)" ""
check "…no tag on the remote" "$(git -C "$W" ls-remote --tags origin)" ""
run "$W" --dir . --commit HEAD --name-style v          # the real tag, on this commit
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "the tag is already on this commit → exit 0" "$RC" 0
has "…exists, as the real run would say" "RELEASE_TAG: exists name=v1.2.3"
put "$W" README.md x; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "the tag is on another commit on the remote → exit 10, as the real run would" "$RC" 10
has "…not-bumped" "RELEASE_TAG: not-bumped name=v1.2.3"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"; git -C "$W" tag v1.2.3 HEAD; put "$W" README.md x; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "a local tag on another commit → exit 10" "$RC" 10
has "…not-bumped" "RELEASE_TAG: not-bumped name=v1.2.3"
check "…and nothing reached the remote" "$(git -C "$W" ls-remote --tags origin)" ""
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
git -C "$W" remote set-url origin "$T/no-such-remote.git"
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "the remote cannot be queried → exit 30" "$RC" 30
has "…and says so" "cannot query remote"
hasnt "…without a retry command for a tag that was never created" "retry with"
check "…and no local tag is created" "$(git -C "$W" tag -l)" ""

echo "== --dry-run checks what a real run needs, and says what it cannot predict (#51 verify R1)"
# a real run creates an annotated tag, which needs a committer identity. The fixtures export one, so
# take the variables away and let a repository setting forbid guessing one from the host name.
NOID=(env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL)
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"; git -C "$W" config user.useConfigOnly true
OUT=$(cd "$W" && "${NOID[@]}" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
check "no committer identity → a dry run exits 30" "$RC" 30
has "…says why" "no committer identity"
has "…and prints the push-failed line a real run prints" "RELEASE_TAG: push-failed name=v1.2.3"
check "…and creates no tag" "$(git -C "$W" tag -l)" ""
OUT=$(cd "$W" && "${NOID[@]}" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v 2>&1); RC=$?
check "the real run fails the same way → exit 30" "$RC" 30
check "…and has created no tag" "$(git -C "$W" tag -l)" ""
git -C "$W" tag v1.2.3 HEAD
OUT=$(cd "$W" && "${NOID[@]}" "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --dry-run 2>&1); RC=$?
check "a local tag is already on this commit (a real run creates nothing) → no identity needed, exit 0" "$RC" 0
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --dry-run
hasnt "signing is off → no note about signing" "tag signing is on"
git -C "$W" config tag.gpgSign true
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "tag.gpgSign on → still exit 0" "$RC" 0
has "…and says a dry run cannot check that signing works" "cannot check that signing works"
check "…and creates no tag" "$(git -C "$W" tag -l)" ""
git -C "$W" config --unset tag.gpgSign; git -C "$W" config tag.forceSignAnnotated true
run "$W" --dir . --commit HEAD --name-style v --dry-run
has "tag.forceSignAnnotated on → the same note" "cannot check that signing works"

# ---- --list-bumps (#55) ----
TAB=$(printf '\t')
# list_run <work> [helper args...]: stdout alone in LIST, stdout and stderr in OUT, the exit code in RC.
# Every list run also checks that no ref changed, in the work repo or in its bare remote.
list_run() {
  local w="$1"; shift
  local before; before=$(refs_snapshot "$w")
  LIST=$(cd "$w" && "${RT_BASH:-bash}" "$HELPER" "$@" 2>"$T/list.err"); RC=$?
  OUT="$LIST
$(cat "$T/list.err")"
  check "…no ref created, moved or deleted, locally or on the remote" "$(refs_snapshot "$w")" "$before"
}
refs_snapshot() {   # every ref of the work repo and of its origin (a bare repo on disk)
  local remote_dir; remote_dir=$(git -C "$1" remote get-url origin); remote_dir=${remote_dir#file://}
  git -C "$1" for-each-ref --format='%(objectname) %(refname)'
  echo --
  git --git-dir="$remote_dir" for-each-ref --format='%(objectname) %(refname)' || echo "cannot read $remote_dir"
}
# every stdout line has one of the three fixed shapes
list_format_ok() {
  local badl
  badl=$(printf '%s\n' "$LIST" | grep -vE "^BUMP${TAB}(version${TAB}[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?${TAB}([0-9a-f]{40}|-)${TAB}[A-Za-z0-9._+-]+${TAB}(same-commit|other-commit|no-tag|ambiguous)|skipped${TAB}[0-9]+|incomplete${TAB}(walk-limit|shallow))\$")
  if [ -z "$badl" ]; then ok "every stdout line is a BUMP line of a fixed shape"; else bad "lines of another shape on stdout" "$badl"; fi
}
bl() { local IFS=$TAB; printf 'BUMP%s%s\n' "$TAB" "$*"; }   # bl version 1.0.0 <sha> v1.0.0 no-tag → one expected line
sha_of() { git -C "$W" rev-parse "$1"; }

echo "== --list-bumps: three versions in a linear history, each with the oldest commit of its run (#55)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; L1=$(sha_of HEAD)
put "$W" .claude-plugin/plugin.json '{ "name": "q", "version": "1.0.0" }'; commit "$W" "c2 same version"
put "$W" a.txt 1; commit "$W" wip
plugin_json "$W" "" 1.1.0; commit "$W" c4; L4=$(sha_of HEAD)
put "$W" .claude-plugin/plugin.json '{ "name": "q", "version": "1.1.0" }'; commit "$W" "c5 same version"
plugin_json "$W" "" 1.2.0; commit "$W" c6; L6=$(sha_of HEAD)
put "$W" .claude-plugin/plugin.json '{ "name": "r", "version": "1.2.0" }'; commit "$W" "c7 same version"; LW=$(sha_of HEAD)
put "$W" b.txt 2; commit "$W" wip2
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "exit 0" "$RC" 0
check "one line per version, newest first, the oldest commit of each run; then the skipped count" "$LIST" \
  "$(bl version 1.2.0 "$L6" v1.2.0 no-tag; bl version 1.1.0 "$L4" v1.1.0 no-tag; bl version 1.0.0 "$L1" v1.0.0 no-tag; bl skipped 0)"
list_format_ok
hasnt "…no incomplete line" "incomplete"
run "$W" --dir . --commit "$L4" --name-style v
check "back-filling one listed commit with a normal run → exit 0" "$RC" 0
check "…the tag is on that commit" "$(remote_commit "$W" v1.1.0)" "$L4"
git -C "$W" tag v1.0.0 "$L1"; git -C "$W" push -q origin refs/tags/v1.0.0
git -C "$W" tag -a v1.2.0 -m x "$LW"; git -C "$W" push -q origin refs/tags/v1.2.0   # annotated, on a later commit of the same run
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the remote has tags: on the run's oldest commit (annotated or not) → same-commit; on another commit, even a later one of the same run → other-commit" "$LIST" \
  "$(bl version 1.2.0 "$L6" v1.2.0 other-commit; bl version 1.1.0 "$L4" v1.1.0 same-commit; bl version 1.0.0 "$L1" v1.0.0 same-commit; bl skipped 0)"
has "…the note says where the other tag is" "v1.2.0 on origin points at ${LW:0:7}, not at ${L6:0:7}"
git -C "$W" tag -d v1.0.0 >/dev/null
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "a tag only on the remote counts; the state is the remote's" "$(printf '%s\n' "$LIST" | grep "${TAB}1.0.0${TAB}" | cut -f6)" same-commit
list_run "$W" --dir . --commit "$L4" --name-style v --list-bumps
check "--commit is where the walk starts" "$LIST" \
  "$(bl version 1.1.0 "$L4" v1.1.0 same-commit; bl version 1.0.0 "$L1" v1.0.0 same-commit; bl skipped 0)"

echo "== --list-bumps: a commit that belongs to no version ends the run and is counted (#55)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; U1=$(sha_of HEAD)
put "$W" .claude-plugin/plugin.json '{ "name": "p", "version": '; commit "$W" broken; UB=$(sha_of HEAD)
plugin_json "$W" "" 1.1.0; commit "$W" c3; U3=$(sha_of HEAD)
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "nothing readable just before 1.1.0 → 1.1.0 is ambiguous (it may have been set there); 1.0.0 keeps its commit; skipped 1" "$LIST" \
  "$(bl version 1.1.0 - v1.1.0 ambiguous; bl version 1.0.0 "$U1" v1.0.0 no-tag; bl skipped 1)"
has "…the note names the skipped commit and why" "skipped ${UB:0:7}: a version source cannot be read"
has "…and says why 1.1.0 has no commit" "the version sources at ${UB:0:7}, just before the commits of 1.1.0, cannot all be read"
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "…--at-bump refuses the same version for the same reason (exit 21)" "$RC" 21
echo "== --list-bumps: an unreadable commit just before a run whose readable sources already say its version (#55 verify R1)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c0; A0=$(sha_of HEAD)
plugin_json "$W" "" 1.1.0; put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.1.0" } }'; commit "$W" "c1 bump, Version.swift unreadable"; A1=$(sha_of HEAD)
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; commit "$W" "c2 readable"
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "plugin.json was set to 1.1.0 at the unreadable commit → 1.1.0 is ambiguous, not on the next commit" "$LIST" \
  "$(bl version 1.1.0 - v1.1.0 ambiguous; bl version 1.0.0 "$A0" v1.0.0 no-tag; bl skipped 1)"
has "…the note names the unreadable commit" "the version sources at ${A1:0:7}, just before the commits of 1.1.0, cannot all be read"
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "…--at-bump agrees: it refuses to tag 1.1.0 (exit 21)" "$RC" 21
has "…for the same reason" "cannot all be read"
new_repo
plugin_json "$W" "" 1.0.0; put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.0.0" } }'; commit "$W" "c0 Version.swift unreadable"
plugin_json "$W" "" 1.1.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.1.0" }'; commit "$W" "c1 bump, all readable"; B1=$(sha_of HEAD)
put "$W" z.txt 1; commit "$W" later
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the readable source at the unreadable commit says another version → the run keeps its commit" "$LIST" \
  "$(bl version 1.1.0 "$B1" v1.1.0 no-tag; bl skipped 1)"
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "…--at-bump agrees: exit 0" "$RC" 0
has "…on the same commit" "commit=$(git -C "$W" rev-parse --short "$B1")"
new_repo
put "$W" .claude-plugin/plugin.json '{ "name": "p" }'; commit "$W" "no version field yet"
plugin_json "$W" "" 1.0.0; commit "$W" "the version is added"; N1=$(sha_of HEAD)
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "a commit before the run with no version source (nothing unreadable) → the run keeps its commit" "$LIST" \
  "$(bl version 1.0.0 "$N1" v1.0.0 no-tag; bl skipped 1)"
run "$W" --dir . --commit HEAD --name-style v --at-bump --dry-run
check "…--at-bump agrees: exit 0" "$RC" 0
has "…on the same commit" "commit=$(git -C "$W" rev-parse --short "$N1")"
new_repo
put "$W" .claude-plugin/plugin.json '{ "name": "p" }'; commit "$W" "no version yet"
plugin_json "$W" "" 1.0.0; commit "$W" c1
put "$W" .claude-plugin/plugin.json '{ "name": "p", "version": '; commit "$W" broken
plugin_json "$W" "" 1.0.0; commit "$W" fixed
plugin_json "$W" "" 2.0.0; put "$W" package.json '{ "version": "1.0.0" }'; commit "$W" "sources disagree"
put "$W" package.json '{ "version": "2.0.0" }'; commit "$W" agree; V2=$(sha_of HEAD)
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the same version on both sides of an unreadable commit → two runs, both ambiguous, no commit" "$LIST" \
  "$(bl version 2.0.0 "$V2" v2.0.0 no-tag; bl version 1.0.0 - v1.0.0 ambiguous; bl version 1.0.0 - v1.0.0 ambiguous; bl skipped 3)"
list_format_ok
has "…sources that disagree are skipped" "the version sources disagree (1.0.0, 2.0.0)"
has "…so is a commit with no version source" "no version source"
check "…the ambiguity is explained once" "$(printf '%s\n' "$OUT" | grep -c '1.0.0 appears in 2 separate runs')" 1
new_repo
plugin_json "$W" "" 1.0.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'; commit "$W" c1
put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.0.0" } }'; commit "$W" "one source unreadable"
put "$W" Sources/S/Version.swift 'enum V { static let version = "1.0.0" }'; commit "$W" fixed
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "one source unreadable while the readable one keeps the version → still skipped, so two runs" "$LIST" \
  "$(bl version 1.0.0 - v1.0.0 ambiguous; bl version 1.0.0 - v1.0.0 ambiguous; bl skipped 1)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; G1=$(sha_of HEAD)
plugin_json "$W" "" '1.0.0-a..b'; commit "$W" "no tag name"
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "a version git refuses as a tag name is skipped" "$LIST" "$(bl version 1.0.0 "$G1" v1.0.0 no-tag; bl skipped 1)"
has "…and the note says why" "v1.0.0-a..b is not a valid git tag name"

echo "== --list-bumps: bumped, reverted and bumped again → ambiguous (#55)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; R1=$(sha_of HEAD)
plugin_json "$W" "" 2.0.0; commit "$W" c2
plugin_json "$W" "" 1.0.0; commit "$W" revert
plugin_json "$W" "" 2.0.0; commit "$W" again
plugin_json "$W" "" 2.1.0; commit "$W" c5; R5=$(sha_of HEAD)
git -C "$W" tag v1.0.0 "$R1"; git -C "$W" push -q origin refs/tags/v1.0.0
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "every run of a version that comes back is ambiguous, with no commit, even when the remote has its tag" "$LIST" \
  "$(bl version 2.1.0 "$R5" v2.1.0 no-tag; bl version 2.0.0 - v2.0.0 ambiguous; bl version 1.0.0 - v1.0.0 ambiguous; bl version 2.0.0 - v2.0.0 ambiguous; bl version 1.0.0 - v1.0.0 ambiguous; bl skipped 0)"
list_format_ok

echo "== --list-bumps follows the first-parent history across a merge (#55)"
new_repo
dated() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$W" "${@:2}"; }
plugin_json "$W" "" 1.0.0; git -C "$W" add -A; dated 2026-01-01T00:00:00+0000 commit -qm C0; M0=$(sha_of HEAD)
git -C "$W" checkout -qb feat
plugin_json "$W" "" 1.1.0; git -C "$W" add -A; dated 2026-01-02T00:00:00+0000 commit -qm F1; MF=$(sha_of HEAD)
git -C "$W" checkout -q main
put "$W" a.txt 1; git -C "$W" add -A; dated 2026-01-03T00:00:00+0000 commit -qm M1
dated 2026-01-04T00:00:00+0000 merge -q --no-ff --no-edit feat; MM=$(sha_of HEAD)
git -C "$W" push -q origin main 2>/dev/null
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the merge commit sets 1.1.0 on this branch; the feature branch's commit is not listed" "$LIST" \
  "$(bl version 1.1.0 "$MM" v1.1.0 no-tag; bl version 1.0.0 "$M0" v1.0.0 no-tag; bl skipped 0)"
if printf '%s' "$OUT" | grep -qF "$MF"; then bad "…the feature branch's commit appears" "$OUT"; else ok "…the feature branch's commit does not appear"; fi

echo "== --list-bumps with --name-style plugin (#55)"
new_repo
plugin_json "$W" "plugins/foo/" 1.0.0; commit "$W" c1; P1=$(sha_of HEAD)
plugin_json "$W" "plugins/bar/" 7.0.0; commit "$W" "another plugin"
plugin_json "$W" "plugins/foo/" 1.1.0; commit "$W" c3; P3=$(sha_of HEAD)
git -C "$W" tag foo-v1.0.0 "$P1"; git -C "$W" tag v1.1.0 "$P3"; git -C "$W" push -q origin refs/tags/foo-v1.0.0 refs/tags/v1.1.0
list_run "$W" --dir plugins/foo --commit HEAD --name-style plugin --plugin foo --list-bumps
check "tags are named <plugin>-v<version>; a v<version> tag is someone else's; another plugin's versions are not listed" "$LIST" \
  "$(bl version 1.1.0 "$P3" foo-v1.1.0 no-tag; bl version 1.0.0 "$P1" foo-v1.0.0 same-commit; bl skipped 0)"
list_format_ok

echo "== --list-bumps at the walk limit says the list is incomplete (#55)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; K1=$(sha_of HEAD)
plugin_json "$W" "" 1.1.0; commit "$W" c2; K2=$(sha_of HEAD)
put "$W" .claude-plugin/plugin.json '{ "name": "q", "version": "1.1.0" }'; commit "$W" c3
plugin_json "$W" "" 1.2.0; commit "$W" c4; K4=$(sha_of HEAD)
plugin_json "$W" "" 1.3.0; commit "$W" c5; K5=$(sha_of HEAD)
RELEASE_TAG_MAX_WALK=3 list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "limit 3 of 5 → exit 0" "$RC" 0
check "…the run cut by the limit gets no commit, and the last line says incomplete" "$LIST" \
  "$(bl version 1.3.0 "$K5" v1.3.0 no-tag; bl version 1.2.0 "$K4" v1.2.0 no-tag; bl version 1.1.0 - v1.1.0 ambiguous; bl skipped 0; bl incomplete walk-limit)"
list_format_ok
has "…the note names the limit" "limit of 3 commits"
RELEASE_TAG_MAX_WALK=5 list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "limit 5 of 5 → the whole list, no incomplete line" "$LIST" \
  "$(bl version 1.3.0 "$K5" v1.3.0 no-tag; bl version 1.2.0 "$K4" v1.2.0 no-tag; bl version 1.1.0 "$K2" v1.1.0 no-tag; bl version 1.0.0 "$K1" v1.0.0 no-tag; bl skipped 0)"
put "$W" Sources/S/Version.swift 'enum V { static var version: String { "1.3.0" } }'; commit "$W" "unreadable, plugin.json still 1.3.0"
plugin_json "$W" "" 1.4.0; put "$W" Sources/S/Version.swift 'enum V { static let version = "1.4.0" }'; commit "$W" c7; K7=$(sha_of HEAD)
RELEASE_TAG_MAX_WALK=2 list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the walk ends on a skipped commit: the run before it keeps its commit; still incomplete" "$LIST" \
  "$(bl version 1.4.0 "$K7" v1.4.0 no-tag; bl skipped 1; bl incomplete walk-limit)"
for bad_walk in abc 0 00 -3 1.5; do
  RELEASE_TAG_MAX_WALK=$bad_walk list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
  has "RELEASE_TAG_MAX_WALK=$bad_walk → a note says it is not used" "RELEASE_TAG_MAX_WALK is not a positive whole number; using 500"
  hasnt "…and the walk uses 500: the whole list" "incomplete"
done
RELEASE_TAG_MAX_WALK=007 list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
hasnt "RELEASE_TAG_MAX_WALK=007 is a positive whole number → no note" "not a positive whole number"

echo "== --list-bumps in a shallow clone says the list is incomplete (#55)"
new_repo
plugin_json "$W" "" 1.0.0; commit "$W" c1; H1=$(sha_of HEAD)
plugin_json "$W" "" 2.0.0; commit "$W" c2; H2=$(sha_of HEAD)
put "$W" a.txt 1; commit "$W" c3; put "$W" b.txt 2; commit "$W" c4
git clone -q --branch main --depth 2 "file://$T/r$N/remote.git" "$T/r$N/shallow"
list_run "$T/r$N/shallow" --dir . --commit HEAD --name-style v --list-bumps
check "the shallow edge looks like the first commit: no commit for its version, and the last line says incomplete" "$LIST" \
  "$(bl version 2.0.0 - v2.0.0 ambiguous; bl skipped 0; bl incomplete shallow)"
has "…the note says how to get the whole list" "git fetch --unshallow"
git clone -q --branch main "file://$T/r$N/remote.git" "$T/r$N/full"
list_run "$T/r$N/full" --dir . --commit HEAD --name-style v --list-bumps
check "a full clone → the whole list" "$LIST" "$(bl version 2.0.0 "$H2" v2.0.0 no-tag; bl version 1.0.0 "$H1" v1.0.0 no-tag; bl skipped 0)"

echo "== --list-bumps: the remote cannot be queried → 30, no BUMP lines, whatever the history holds (#55, verify R1)"
for history in plain all-ambiguous no-version; do
  new_repo
  case "$history" in
    plain)         plugin_json "$W" "" 1.0.0; commit "$W" ;;
    all-ambiguous) for v in 1.0.0 2.0.0 1.0.0 2.0.0; do plugin_json "$W" "" "$v"; commit "$W" "$v"; done ;;
    no-version)    put "$W" .claude-plugin/plugin.json '{ "name": "p" }'; commit "$W" ;;
  esac
  git -C "$W" remote set-url origin "$T/no-such-remote.git"
  LIST=$(cd "$W" && "${RT_BASH:-bash}" "$HELPER" --dir . --commit HEAD --name-style v --list-bumps 2>"$T/list.err"); RC=$?
  OUT="$LIST
$(cat "$T/list.err")"
  check "$history: exit 30" "$RC" 30
  check "$history: …nothing on stdout" "$LIST" ""
  has "$history: …and says why" "cannot query remote"
  check "$history: …no tag created" "$(git -C "$W" tag -l)" ""
done

echo "== --list-bumps: usage (#55)"
new_repo; plugin_json "$W" "" 1.0.0; commit "$W"
run "$W" --dir . --commit HEAD --name-style v --list-bumps --at-bump;        check "with --at-bump → 2" "$RC" 2
run "$W" --dir . --commit HEAD --name-style v --list-bumps --expect 1.0.0;   check "with --expect → 2" "$RC" 2
run "$W" --dir . --commit HEAD --name-style plugin --list-bumps;             check "plugin style without --plugin → 2" "$RC" 2
run "$W" --dir . --commit HEAD --name-style v --list-bumps --dry-run;          check "with --dry-run → 2 (refused, not ignored)" "$RC" 2
has "…and says why" "cannot be combined with --dry-run"
run "$W" --dir . --commit HEAD --name-style v --dry-run --list-bumps;          check "in either order → 2" "$RC" 2

echo "== --list-bumps follows a hatch version file, bumped on its own (#55 verify R1)"
new_repo
printf '[project]\nname = "x"\ndynamic = ["version"]\n[tool.hatch.version]\npath = "x/__init__.py"\n' > "$W/pyproject.toml"
put "$W" x/__init__.py '__version__ = "1.0.0"'; commit "$W" c1; Y1=$(sha_of HEAD)
put "$W" x/__init__.py '__version__ = "1.1.0"'; commit "$W" "only the hatch file"; Y2=$(sha_of HEAD)
put "$W" z.txt 1; commit "$W" later
list_run "$W" --dir . --commit HEAD --name-style v --list-bumps
check "the commit that changed only the hatch file is where 1.1.0 was set" "$LIST" \
  "$(bl version 1.1.0 "$Y2" v1.1.0 no-tag; bl version 1.0.0 "$Y1" v1.0.0 no-tag; bl skipped 0)"

echo "== usage errors → 2"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --name-style v;                                   check "missing --commit" "$RC" 2
run "$W" --dir . --commit HEAD --name-style x;                     check "bad --name-style" "$RC" 2
run "$W" --dir . --commit HEAD --name-style plugin;                check "plugin style without --plugin" "$RC" 2
run "$W" --dir . --commit HEAD --name-style plugin --plugin 'a b'; check "bad plugin name" "$RC" 2
run "$W" --dir . --commit nope --name-style v;                     check "unknown commit" "$RC" 2
run "$W" --dir . --commit HEAD --name-style v --expect 1.2;        check "--expect not x.y.z" "$RC" 2

echo "== the helper parses under every bash it can meet (verify R2: /bin/bash is 3.2 on macOS)"
for b in /bin/bash bash; do
  command -v "$b" >/dev/null 2>&1 || continue
  if ERR=$("$b" -n "$HELPER" 2>&1); then ok "$b -n ($("$b" -c 'echo $BASH_VERSION'))"; else bad "$b -n fails" "$ERR"; fi
done
if [ -z "${RT_BASH:-}" ] && [ -x /bin/bash ] \
   && [ "$(/bin/bash -c 'echo $BASH_VERSION')" != "$(bash -c 'echo $BASH_VERSION')" ]; then
  echo "== the whole suite again, the helper run by /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')"
  if RT_BASH=/bin/bash bash "${BASH_SOURCE[0]}" > "$T/system-bash.log" 2>&1; then
    ok "every case passes under /bin/bash ($(tail -1 "$T/system-bash.log"))"
  else
    bad "cases fail under /bin/bash: $(tail -1 "$T/system-bash.log")" "$(grep '✗' "$T/system-bash.log")"
  fi
fi

echo
echo "release-tag${RT_BASH:+ (helper under $RT_BASH)}: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
