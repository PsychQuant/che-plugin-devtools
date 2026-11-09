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
has "retry command" "push origin refs/tags/v1.2.3"
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
run "$W" --dir . --commit HEAD --name-style v --dry-run
check "https fetch + ssh push to github.com/o/r → passes the check (dry-run exit 0)" "$RC" 0
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
