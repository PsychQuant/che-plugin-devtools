#!/usr/bin/env bash
# release-tag.sh — tag a release commit with its version and push the tag (#42).
#
# The one tag implementation for plugin-update, plugin-deploy, mcp-deploy and
# cli-deploy. Callers decide WHEN to tag; this script decides WHAT the tag is
# and whether it is safe to create.
#
# Usage:
#   release-tag.sh --dir <version-root> --commit <rev> --name-style v|plugin
#                  [--plugin <name>] [--remote <remote>] [--dry-run]
#
#   --dir         directory whose version files are read (a plugin directory, or
#                 a binary repo's root); must be inside a git work tree
#   --commit      the release commit; versions are read from THIS commit with
#                 `git show`, never from the work tree (which may be dirty)
#   --name-style  v       → tag `v<version>` (binary repos, single-plugin repos)
#                 plugin  → tag `<plugin>-v<version>` (repos holding several plugins)
#   --remote      remote to push to (default: origin)
#   --dry-run     resolve the version and print the decision line; create nothing
#
# Version sources — a CLOSED list of seven, read relative to --dir. Do not add an
# eighth by resemblance; every source found must agree, and a source that is
# present but cannot be read stops the run:
#   1. .claude-plugin/plugin.json or plugin.json         "version"
#   2. pyproject.toml                                    [project].version (static)
#   3. pyproject.toml dynamic version                    [tool.hatch.version].path → __version__ = "x.y.z"
#   4. package.json                                      "version"
#   5. Sources/*/Version.swift                           static let version|current = "x.y.z"
#   6. mcpb/manifest.json                                "version"
#   7. Sources/*/Server.swift                            version: "x.y.z" (two different values → unreadable)
#
# Output: one decision line on stdout, details on stderr:
#   RELEASE_TAG: <status> name=<tag> commit=<short> version=<x.y.z> sources=<a,b,…>
#
# Exit codes:
#   0   tagged and pushed (status tagged), the remote already has this tag on
#       this commit (status exists), or --dry-run (status dry-run)
#   10  a tag with this name already points at another commit: the version was
#       not bumped since that release. Nothing is created or moved.
#   20  version sources disagree (status mismatch)
#   21  no version source, or a source that cannot be read (status unreadable)
#   30  the remote could not be queried, the push failed, or the pushed tag is
#       not on the remote afterwards (status push-failed). A local tag is kept so
#       the printed retry command works.
#   2   usage error
#
# Never moves or deletes a tag and never uses --force: a wrong tag on the remote
# is the user's call to remove.
set -u

PROG="release-tag.sh"
die_usage() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

DIR=""; COMMIT=""; STYLE=""; PLUGIN=""; REMOTE="origin"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        [ $# -ge 2 ] || die_usage "--dir needs a value";        DIR=$2; shift 2 ;;
    --commit)     [ $# -ge 2 ] || die_usage "--commit needs a value";     COMMIT=$2; shift 2 ;;
    --name-style) [ $# -ge 2 ] || die_usage "--name-style needs a value"; STYLE=$2; shift 2 ;;
    --plugin)     [ $# -ge 2 ] || die_usage "--plugin needs a value";     PLUGIN=$2; shift 2 ;;
    --remote)     [ $# -ge 2 ] || die_usage "--remote needs a value";     REMOTE=$2; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    *)            die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$DIR" ]    || die_usage "--dir is required"
[ -n "$COMMIT" ] || die_usage "--commit is required"
case "$STYLE" in
  v) ;;
  plugin)
    [ -n "$PLUGIN" ] || die_usage "--name-style plugin needs --plugin <name>" ;;
  *) die_usage "--name-style must be v or plugin" ;;
esac
if [ -n "$PLUGIN" ]; then
  case "$PLUGIN" in .*|-*|*[!A-Za-z0-9._-]*) die_usage "--plugin must match [A-Za-z0-9._-] and not start with . or -" ;; esac
fi
case "$REMOTE" in ''|-*|*[!A-Za-z0-9._/-]*) die_usage "--remote is not a valid remote name" ;; esac
[ -d "$DIR" ] || die_usage "--dir is not a directory: $DIR"

TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || die_usage "--dir is not inside a git work tree: $DIR"
PREFIX=$(git -C "$DIR" rev-parse --show-prefix 2>/dev/null) || die_usage "cannot resolve --dir inside the repository"
SHA=$(git -C "$TOP" rev-parse -q --verify "${COMMIT}^{commit}" 2>/dev/null) || die_usage "--commit does not name a commit: $COMMIT"
SHORT=$(git -C "$TOP" rev-parse --short "$SHA")

# ---- 1. versions at the commit (Python: JSON and TOML need a real parser) ----
SOURCES_OUT=$(python3 -I - "$TOP" "$SHA" "$PREFIX" <<'PY'
import json, re, subprocess, sys

top, sha, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$")
found, problems = [], []

def show(rel):
    r = subprocess.run(["git", "-C", top, "show", f"{sha}:{prefix}{rel}"],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def listed(rel_dir):
    r = subprocess.run(["git", "-C", top, "ls-tree", "-r", "--name-only", sha, "--", prefix + rel_dir],
                       capture_output=True, text=True)
    return [p[len(prefix):] for p in r.stdout.splitlines()] if r.returncode == 0 else []

def add(name, value):
    if isinstance(value, str) and SEMVER.match(value):
        found.append((name, value))
    else:
        problems.append(f"{name}: version {value!r} is not x.y.z")

def json_version(rel, name, required):
    text = show(rel)
    if text is None:
        return False
    try:
        data = json.loads(text)
    except ValueError as e:
        problems.append(f"{name}: not valid JSON ({e})"); return True
    if not isinstance(data, dict) or "version" not in data:
        if required:
            problems.append(f"{name}: no \"version\" field")
        return True
    add(name, data["version"]); return True

# 1. plugin manifest (either location)
if not json_version(".claude-plugin/plugin.json", "plugin.json", True):
    json_version("plugin.json", "plugin.json", True)

# 2/3. pyproject
pp = show("pyproject.toml")
if pp is not None:
    try:
        import tomllib
    except ImportError:
        problems.append("pyproject.toml: Python 3.11+ (tomllib) is needed to read it")
    else:
        try:
            doc = tomllib.loads(pp)
        except tomllib.TOMLDecodeError as e:
            problems.append(f"pyproject.toml: not valid TOML ({e})"); doc = None
        if doc is not None:
            proj = doc.get("project", {}) if isinstance(doc.get("project"), dict) else {}
            dynamic = proj.get("dynamic", []) if isinstance(proj.get("dynamic", []), list) else []
            if "version" in proj:
                add("pyproject", proj["version"])
            elif "version" in dynamic:
                path = (((doc.get("tool") or {}).get("hatch") or {}).get("version") or {}).get("path")
                if not isinstance(path, str) or not path:
                    problems.append("pyproject.toml: dynamic version is not a [tool.hatch.version] path")
                else:
                    src = show(path)
                    vals = sorted(set(re.findall(r'(?m)^__version__\s*=\s*["\']([^"\']+)["\']', src or "")))
                    if src is None:
                        problems.append(f"hatch:{path}: file not found at this commit")
                    elif len(vals) != 1:
                        problems.append(f"hatch:{path}: expected one __version__, found {vals or 'none'}")
                    else:
                        add(f"hatch:{path}", vals[0])

# 4. package.json (a package without "version" is not a version source)
json_version("package.json", "package.json", False)

# 5/7. Swift
for path in listed("Sources/"):
    parts = path.split("/")
    if len(parts) != 3:
        continue
    if parts[2] == "Version.swift":
        vals = sorted(set(re.findall(r'static\s+let\s+(?:version|current)\s*=\s*"([^"]+)"', show(path) or "")))
        if len(vals) != 1:
            problems.append(f"{path}: expected one static let version/current, found {vals or 'none'}")
        else:
            add(path, vals[0])
    elif parts[2] == "Server.swift":
        vals = sorted(set(v for v in re.findall(r'\bversion:\s*"([^"]+)"', show(path) or "")
                          if re.match(r"^[0-9]+\.[0-9]+", v)))
        if len(vals) > 1:
            problems.append(f"{path}: several different versions {vals}")
        elif vals:
            add(path, vals[0])

# 6. mcpb manifest
json_version("mcpb/manifest.json", "mcpb/manifest.json", True)

for name, value in found:
    print(f"SOURCE\t{name}\t{value}")
for p in problems:
    print(f"PROBLEM\t{p}")
PY
) || { echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=?" ; echo "$PROG: python3 failed while reading versions" >&2; exit 21; }

SOURCES=$(printf '%s\n' "$SOURCES_OUT" | awk -F'\t' '$1=="SOURCE"{print $2}' | paste -sd, -)
VERSIONS=$(printf '%s\n' "$SOURCES_OUT" | awk -F'\t' '$1=="SOURCE"{print $3}' | sort -u)
PROBLEMS=$(printf '%s\n' "$SOURCES_OUT" | awk -F'\t' '$1=="PROBLEM"{print $2}')

if [ -n "$PROBLEMS" ]; then
  echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=${SOURCES:-none}"
  printf '%s\n' "$PROBLEMS" | sed "s/^/$PROG: /" >&2
  exit 21
fi
if [ -z "$VERSIONS" ]; then
  echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=none"
  echo "$PROG: no version source under ${PREFIX:-the repository root} at $SHORT" >&2
  exit 21
fi
if [ "$(printf '%s\n' "$VERSIONS" | grep -c .)" -gt 1 ]; then
  echo "RELEASE_TAG: mismatch name=? commit=$SHORT version=? sources=$SOURCES"
  printf '%s\n' "$SOURCES_OUT" | awk -F'\t' -v p="$PROG" '$1=="SOURCE"{printf "%s: %s = %s\n", p, $2, $3}' >&2
  exit 20
fi
VERSION=$VERSIONS

case "$STYLE" in
  v)      NAME="v$VERSION"; LABEL=$(basename "$TOP") ;;
  plugin) NAME="$PLUGIN-v$VERSION"; LABEL=$PLUGIN ;;
esac
LINE_TAIL="name=$NAME commit=$SHORT version=$VERSION sources=$SOURCES"

if [ "$DRY" = 1 ]; then
  echo "RELEASE_TAG: dry-run $LINE_TAIL"
  exit 0
fi

RETRY="git -C '$TOP' push $REMOTE refs/tags/$NAME"
push_failed() {
  echo "RELEASE_TAG: push-failed $LINE_TAIL"
  echo "$PROG: $1" >&2
  echo "$PROG: retry with: $RETRY" >&2
  exit 30
}
# the commit a remote tag points at (peeled for annotated tags); empty when absent
remote_target() {
  local out
  out=$(git -C "$TOP" ls-remote --tags "$REMOTE" "refs/tags/$NAME" "refs/tags/$NAME^{}") || return 1
  local peeled direct
  peeled=$(printf '%s\n' "$out" | awk -v n="refs/tags/$NAME^{}" '$2==n{print $1}')
  direct=$(printf '%s\n' "$out" | awk -v n="refs/tags/$NAME" '$2==n{print $1}')
  printf '%s\n' "${peeled:-$direct}"
}

# ---- 2. does the tag already exist? remote first, then local ----
REMOTE_AT=$(remote_target) || push_failed "cannot query remote '$REMOTE'"
if [ -n "$REMOTE_AT" ]; then
  if [ "$REMOTE_AT" = "$SHA" ]; then
    echo "RELEASE_TAG: exists $LINE_TAIL"
    exit 0
  fi
  echo "RELEASE_TAG: not-bumped $LINE_TAIL"
  echo "$PROG: $NAME already points at $(git -C "$TOP" rev-parse --short "$REMOTE_AT" 2>/dev/null || echo "$REMOTE_AT") on $REMOTE — the version was not bumped since then; nothing tagged" >&2
  exit 10
fi
LOCAL_AT=$(git -C "$TOP" rev-parse -q --verify "refs/tags/$NAME^{commit}" 2>/dev/null || true)
if [ -n "$LOCAL_AT" ] && [ "$LOCAL_AT" != "$SHA" ]; then
  echo "RELEASE_TAG: not-bumped $LINE_TAIL"
  echo "$PROG: a local tag $NAME already points at $(git -C "$TOP" rev-parse --short "$LOCAL_AT") — not moving it; nothing tagged" >&2
  exit 10
fi

# ---- 3. create (unless a local tag on this commit is waiting to be pushed), push, read back ----
if [ -z "$LOCAL_AT" ]; then
  git -C "$TOP" tag -a "$NAME" -m "$LABEL $VERSION" "$SHA" \
    || { echo "RELEASE_TAG: push-failed $LINE_TAIL"; echo "$PROG: git tag failed" >&2; exit 30; }
fi
git -C "$TOP" push "$REMOTE" "refs/tags/$NAME" >&2 || push_failed "git push of $NAME to '$REMOTE' failed"
AFTER=$(remote_target) || push_failed "cannot read $NAME back from '$REMOTE'"
[ "$AFTER" = "$SHA" ] || push_failed "$NAME is not on '$REMOTE' at $SHORT after the push"
echo "RELEASE_TAG: tagged $LINE_TAIL"
