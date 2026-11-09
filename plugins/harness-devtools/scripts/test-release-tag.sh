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
  OUT=$(cd "$w" && bash "$HELPER" "$@" 2>&1); RC=$?
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

echo "== usage errors → 2"
new_repo; plugin_json "$W" "" 1.2.3; commit "$W"
run "$W" --dir . --name-style v;                                   check "missing --commit" "$RC" 2
run "$W" --dir . --commit HEAD --name-style x;                     check "bad --name-style" "$RC" 2
run "$W" --dir . --commit HEAD --name-style plugin;                check "plugin style without --plugin" "$RC" 2
run "$W" --dir . --commit HEAD --name-style plugin --plugin 'a b'; check "bad plugin name" "$RC" 2
run "$W" --dir . --commit nope --name-style v;                     check "unknown commit" "$RC" 2

echo
echo "release-tag: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
