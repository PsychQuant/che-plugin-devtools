#!/usr/bin/env bash
# release-tag.sh — tag a release commit with its version and push the tag (#42).
#
# The one tag implementation for plugin-update, plugin-deploy, mcp-deploy and
# cli-deploy. Callers decide WHEN to tag; this script decides WHAT the tag is
# and whether it is safe to create.
#
# Usage:
#   release-tag.sh --dir <version-root> --commit <rev> --name-style v|plugin
#                  [--plugin <name>] [--remote <remote>] [--expect <x.y.z>]
#                  [--at-bump] [--dry-run]
#
#   --dir         directory whose version files are read (a plugin directory, or
#                 a binary repo's root); must be inside a git work tree
#   --commit      the commit to start from; versions are read from commits with
#                 `git cat-file blob`, never from the work tree (which may be dirty)
#   --name-style  v       → tag `v<version>`
#                 plugin  → tag `<plugin>-v<version>`
#   --remote      remote to push to (default: origin)
#   --expect      the version the caller is releasing (mcp-deploy, cli-deploy).
#                 Every version source found must equal it; when the tree has no
#                 version source at all (the version is computed at build time),
#                 the tag uses this value.
#   --at-bump     tag the commit that set the version, not --commit itself:
#                 walking back along the FIRST-PARENT history of --commit (the
#                 branch's own commits: with merge-commit PRs the tag goes on the
#                 merge commit) over commits that touch any path of the closed
#                 list below (deleted ones included), the oldest commit
#                 of the run in which every source already equals the current
#                 version (plugin-update, plugin-deploy). Without it the tag goes
#                 on --commit. When that commit cannot be determined — the newest
#                 candidate already disagrees, or the walk reaches its limit
#                 (500 commits; RELEASE_TAG_MAX_WALK overrides it for tests) —
#                 the run is unreadable (21): a guessed commit is never tagged.
#                 Later commits that change --dir are counted in a note, since
#                 the tag will not include them.
#   --dry-run     resolve the version and print the decision line; create nothing
#
# Version sources — a CLOSED list of seven, read relative to --dir. Do not add an
# eighth by resemblance. Every source found must agree, and a source that is
# present but cannot be read stops the run:
#   1. .claude-plugin/plugin.json or plugin.json         "version"
#   2. pyproject.toml                                    [project].version (static)
#   3. pyproject.toml dynamic version                    the file at [tool.hatch.version].path, read
#                                                        exactly as hatchling's regex source reads it
#                                                        (path normalised, strict UTF-8 with any BOM
#                                                        kept, its default pattern or the configured
#                                                        one, first match); another hatch source →
#                                                        unreadable
#      (2 and 3 need python3 >= 3.11 for tomllib: with an older python3 first on
#      PATH — /usr/bin/python3 on macOS is 3.9 — any pyproject.toml makes the run
#      unreadable; #48)
#   4. package.json                                      "version"
#   5. Sources/*/Version.swift                           static let|var version|current [: String] = "x.y.z"
#                                                        (no such declaration → not a source; a
#                                                        declaration whose value is not one whole
#                                                        string literal → unreadable)
#   6. mcpb/manifest.json                                "version"
#   7. Sources/*/Server.swift                            version: "x.y.z" as a whole argument (none →
#                                                        not a source; a version string that is not
#                                                        the whole argument, or two different values
#                                                        → unreadable). Only a string that starts
#                                                        with digits.digits counts: "v1.2.3" or "dev"
#                                                        is not a source. Every such `version:` in
#                                                        the file counts, so one that is not the
#                                                        package version (a response field, say)
#                                                        stops the run: 20 when it is the only
#                                                        one, 21 when it sits next to the real
#                                                        one. Give it a named constant or move
#                                                        it out of Server.swift
#   A JSON source (1, 4, 6) without a "version" field is not a source. The Swift
#   sources are read with comments removed; block comments nest.
#
# The version must also make a valid git tag name (`git check-ref-format`), which
# is checked before anything is created, so --dry-run and a real run agree.
#
# Runs under bash 3.2 (/bin/bash on macOS): the Python below is read into a
# variable from a top-level heredoc, because bash 3.2 mis-parses a heredoc inside
# $( … ) whose text has quotes in it (#42 verify R2).
#
# Output: one decision line on stdout, details on stderr:
#   RELEASE_TAG: <status> name=<tag> commit=<short> version=<x.y.z> sources=<a,b,…>
#
# Exit codes:
#   0   tagged and pushed (status tagged), the remote already has this tag on
#       this commit (status exists), or --dry-run (status dry-run)
#   10  a tag with this name already points at another commit (status
#       not-bumped): this version was released before, or an earlier release
#       stopped after its tag was pushed. Nothing is created or moved.
#   20  version sources disagree, or disagree with --expect (status mismatch)
#   21  no version source (and no --expect), a source that cannot be read — a
#       pyproject.toml with python3 < 3.11 included — or --at-bump cannot
#       determine the commit that set the version (status unreadable)
#   30  the remote could not be queried, the push failed, or the pushed tag is
#       not on the remote afterwards (status push-failed). A local tag is kept so
#       the printed retry command works. Also when the remote's push URL differs
#       from its fetch URL — checked before anything is created or pushed.
#   2   usage error
#
# Never moves or deletes a tag and never uses --force: a wrong tag on the remote
# is the user's call to remove.
set -u

PROG="release-tag.sh"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
die_usage() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

DIR=""; COMMIT=""; STYLE=""; PLUGIN=""; REMOTE="origin"; EXPECT=""; AT_BUMP=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        [ $# -ge 2 ] || die_usage "--dir needs a value";        DIR=$2; shift 2 ;;
    --commit)     [ $# -ge 2 ] || die_usage "--commit needs a value";     COMMIT=$2; shift 2 ;;
    --name-style) [ $# -ge 2 ] || die_usage "--name-style needs a value"; STYLE=$2; shift 2 ;;
    --plugin)     [ $# -ge 2 ] || die_usage "--plugin needs a value";     PLUGIN=$2; shift 2 ;;
    --remote)     [ $# -ge 2 ] || die_usage "--remote needs a value";     REMOTE=$2; shift 2 ;;
    --expect)     [ $# -ge 2 ] || die_usage "--expect needs a value";     EXPECT=$2; shift 2 ;;
    --at-bump)    AT_BUMP=1; shift ;;
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
if [ -n "$EXPECT" ]; then
  [[ "$EXPECT" =~ $SEMVER_RE ]] || die_usage "--expect must be x.y.z (optionally -pre)"
fi
[ -d "$DIR" ] || die_usage "--dir is not a directory: $DIR"

TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || die_usage "--dir is not inside a git work tree: $DIR"
PREFIX=$(git -C "$DIR" rev-parse --show-prefix 2>/dev/null) || die_usage "cannot resolve --dir inside the repository"
SHA=$(git -C "$TOP" rev-parse -q --verify "${COMMIT}^{commit}" 2>/dev/null) || die_usage "--commit does not name a commit: $COMMIT"

# ---- 1. versions (Python: JSON and TOML need a real parser) ----
# Each output line is TAB-separated and every field is printed through safe(): a
# value from the repository (a path in pyproject.toml, a file name) must never be
# able to add a field or a line — that is how a TAB in a hatch path once became
# the tag name (#42 verify R1).
MAX_WALK=${RELEASE_TAG_MAX_WALK:-500}
case "$MAX_WALK" in ''|*[!0-9]*|0) MAX_WALK=500 ;; esac
# Read into a variable from a TOP-LEVEL heredoc, then run with -c: bash 3.2 cannot
# parse a heredoc inside $( … ) when its text contains quotes (#42 verify R2).
IFS= read -r -d '' PYSRC <<'PY' || true
import json, posixpath, re, subprocess, sys

top, sha, prefix, at_bump = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
MAX_WALK = int(sys.argv[5])
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?")   # used with fullmatch: no trailing newline
# Version.swift: the declaration, and the declaration whose WHOLE initializer is one
# string literal — no interpolation or escapes inside, nothing after it but the end of
# the line, `;` or `}`, and no continuation (`+`, `.method`, `?`, …) on the next line
# (#42 verify R3: `"1.0.0" + "-beta"` once read as 1.0.0). Comments are removed first.
SWIFT_DECL = re.compile(r'\bstatic\s+(?:let|var)\s+(?:version|current)\b')
SWIFT_VALUE = re.compile(r'\bstatic\s+(?:let|var)\s+(?:version|current)\s*(?::\s*String\s*)?=\s*"([^"\\\n]*)"'
                         r'(?=[ \t]*(?:;|\}|\n|$))(?![ \t]*\n\s*[-+.?\[(&|*%<>=!/])')

def swift_code(text):
    """Swift source with // and /* */ comments removed. String literals are skipped
    while scanning, so a URL inside a string is not taken for a comment (#42 verify R4).
    A multi-line (triple-quoted) string keeps its delimiters and line breaks but its text becomes
    blanks: text that looks like a version declaration inside it is not code (#42
    verify R8), and a version written as a multi-line string is still not a plain
    literal."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            end = n if j < 0 else j
            out.append('"""' + re.sub(r"[^\n]", " ", text[i + 3:end]) + ('"""' if j >= 0 else ""))
            i = n if j < 0 else j + 3
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(text[i:j]); i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            # Swift block comments nest (#42 verify R6)
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1; j += 2
                elif text.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append(" "); i = j
        else:
            out.append(text[i]); i += 1
    return "".join(out)

def dig(d, *keys):
    """d[k1][k2]... when every level is a table; None otherwise."""
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d

# hatchling/version/core.py (read 2026-11-10): the regex version source searches the
# file with this pattern, or [tool.hatch.version].pattern, under re.MULTILINE and takes
# the FIRST match's `version` group. The tag carries the version string hatch reads,
# so the helper reads the file the same way: from `__version__ = "1.0.0" + "-beta"`
# hatch reads 1.0.0 (#42 verify R6; rounds 4-5 had read it more strictly than hatch
# itself does). packaging may still normalise a pre-release when the wheel is built
# (1.0.0-beta → 1.0.0b0), as it does for a static [project].version.
HATCH_DEFAULT_PATTERN = r'(?i)^(__version__|VERSION) *= *([\'"])v?(?P<version>.+?)\2'

def hatch_config(doc):
    cfg = dig(doc, "tool", "hatch", "version")
    return cfg if isinstance(cfg, dict) else None

def hatch_path_of(cfg):
    """The configured path, normalised as hatchling does (os.path.normpath of
    root/path, so `./x.py`, `x//y.py` and `x/./y.py` name the same file — #42 verify
    R7), or None: characters outside [A-Za-z0-9._/-], a `..` part, or an absolute path
    (hatchling would read a file outside the repository)."""
    path = cfg.get("path") if cfg else None
    if (isinstance(path, str) and re.fullmatch(r"[A-Za-z0-9._/-]+", path)
            and ".." not in path.split("/") and not path.startswith("/")):
        norm = posixpath.normpath(path)
        if norm not in (".", ""):
            return norm
    return None

def hatch_read(text, cfg):
    """(version, problem): the version hatchling's regex source reads from text."""
    source = cfg.get("source", "regex")
    if source != "regex":
        return None, f"hatch version source {safe(source)!r} is not supported (only regex)"
    pattern = cfg.get("pattern", "")
    if not isinstance(pattern, str):
        return None, "[tool.hatch.version].pattern is not a string"
    try:
        m = re.search(pattern or HATCH_DEFAULT_PATTERN, text, flags=re.MULTILINE)
    except (re.error, RecursionError, MemoryError):
        return None, "[tool.hatch.version].pattern is not a valid regex"
    if not m:
        return None, "hatch's pattern finds no version in the file"
    if "version" not in m.groupdict():
        return None, "[tool.hatch.version].pattern has no group named version"
    return m.group("version"), None

def hatch_path(pp_text):
    """The [tool.hatch.version].path of a pyproject.toml text, or None (--at-bump walk)."""
    try:
        import tomllib
        return hatch_path_of(hatch_config(tomllib.loads(pp_text or "")))
    except Exception:
        return None

# Server.swift: `version: "x"` counts only when the string literal is the whole
# argument, i.e. followed by `,` `)` `]` or `}` (#42 verify R5). Every `version:` whose
# string starts like a version is counted, escapes and interpolation included, so one
# that is not a whole plain literal is a problem rather than invisible (#42 verify R6).
SERVER_ANY = re.compile(r'\bversion:\s*"(?=[0-9]+\.[0-9]+)')
SERVER_VALUE = re.compile(r'\bversion:\s*"([^"\\\n]*)"(?=\s*[,)\]}])')
VERSIONISH = re.compile(r"[0-9]+\.[0-9]+")

def oneline(s):
    """A message line: control characters out, ASCII only (a non-UTF-8 locale must not
    break the run). Values from the repository are already passed through safe() where
    the message is built, so their ? marks stay (#42 verify R3, R4)."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(s)).encode("ascii", "replace").decode("ascii")
# every path of the closed list, for the --at-bump walk (a deleted source counts too)
SOURCE_SPECS = [".claude-plugin/plugin.json", "plugin.json", "pyproject.toml", "package.json",
                "mcpb/manifest.json", "Sources/*/Version.swift", "Sources/*/Server.swift"]

def safe(s):
    return re.sub(r"[^A-Za-z0-9._/:@+-]", "?", str(s))

def literal(path):
    return ":(literal)" + path

def glob_escape(path):
    return re.sub(r"([][*?])", r"[\1]", path)

def git(*args):
    # errors="replace": a version file may legally hold bytes that are not UTF-8 (a
    # latin-1 comment); that must not crash the run (#42 verify R6)
    return subprocess.run(["git", "-C", top, "-c", "core.quotePath=false", *args],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")

def read_sources(commit):
    """Return (found, problems, notes, paths) for the version sources at commit."""
    found, problems, notes, paths = [], [], [], []

    def show(rel):
        # cat-file blob, not show: `git show <sha>:<path>` prints the commit and exits 0
        # for a missing path containing `[` (#42 verify R3)
        r = git("cat-file", "blob", f"{commit}:{prefix}{rel}")
        return r.stdout if r.returncode == 0 else None

    def hatch_text(rel):
        """(text, problem) of the hatch version file, decoded the way hatchling opens
        it — encoding="utf-8": strict, and a BOM stays as U+FEFF — not with git()'s
        replacement characters (#42 verify R7)."""
        r = subprocess.run(["git", "-C", top, "cat-file", "blob", f"{commit}:{prefix}{rel}"],
                           capture_output=True)
        if r.returncode != 0:
            return None, "file not found at this commit"
        try:
            text = r.stdout.decode("utf-8")
        except UnicodeDecodeError:
            return None, "not UTF-8, so hatchling cannot read it either"
        # open() in text mode also turns \r\n and a lone \r into \n (#42 verify R8)
        return text.replace("\r\n", "\n").replace("\r", "\n"), None

    def listed(rel_dir):
        r = git("ls-tree", "-r", "-z", "--name-only", commit, "--", prefix + rel_dir)
        if r.returncode != 0:
            return []
        return [p[len(prefix):] for p in r.stdout.split("\0") if p]

    def add(name, value, rel):
        if isinstance(value, str) and SEMVER.fullmatch(value):
            found.append((name, value)); paths.append(prefix + rel)
        else:
            problems.append(f"{safe(name)}: version {safe(value)!r} is not x.y.z")

    def json_version(rel, name):
        """A JSON file without a "version" field is not a version source (plugin.json,
        package.json, mcpb/manifest.json alike — #42 verify R5, R6). A UTF-8 BOM is
        dropped first."""
        text = show(rel)
        if text is None:
            return False
        try:
            data = json.loads(text.lstrip("\ufeff"))
        except (ValueError, RecursionError):
            problems.append(f"{name}: not valid JSON"); return True
        if isinstance(data, dict) and "version" in data:
            add(name, data["version"], rel)
        return True

    if not json_version(".claude-plugin/plugin.json", "plugin.json"):
        json_version("plugin.json", "plugin.json")

    pp = show("pyproject.toml")
    if pp is not None:
        try:
            import tomllib
        except ImportError:
            problems.append("pyproject.toml: Python 3.11+ (tomllib) is needed to read it")
        else:
            try:
                doc = tomllib.loads(pp)
            except (tomllib.TOMLDecodeError, RecursionError):
                problems.append("pyproject.toml: not valid TOML"); doc = None
            if doc is not None:
                proj = doc.get("project", {}) if isinstance(doc.get("project"), dict) else {}
                dynamic = proj.get("dynamic", []) if isinstance(proj.get("dynamic", []), list) else []
                if "version" in proj:
                    add("pyproject", proj["version"], "pyproject.toml")
                elif "version" in dynamic:
                    cfg = hatch_config(doc)
                    raw = cfg.get("path") if cfg else None
                    path = hatch_path_of(cfg)
                    if not isinstance(raw, str) or not raw:
                        problems.append("pyproject.toml: dynamic version is not a [tool.hatch.version] path")
                    elif path is None:
                        problems.append(f"pyproject.toml: [tool.hatch.version].path {safe(raw)!r} is not a relative path inside the repository made of [A-Za-z0-9._/-]")
                    else:
                        src, why = hatch_text(path)
                        if why is None:
                            v, why = hatch_read(src, cfg)
                        if why:
                            problems.append(f"hatch:{path}: {why}")
                        else:
                            add(f"hatch:{path}", v, path)

    json_version("package.json", "package.json")

    for path in listed("Sources/"):
        parts = path.split("/")
        if len(parts) != 3:
            continue
        if parts[2] == "Version.swift":
            text = swift_code(show(path) or "")
            literals = SWIFT_VALUE.findall(text)
            vals = sorted(set(literals))
            if len(vals) > 1:
                problems.append(f"{safe(path)}: several different versions {[safe(v) for v in vals]}")
            elif len(SWIFT_DECL.findall(text)) > len(literals):
                # a version/current declaration whose value is not a string literal:
                # skipping it would let --expect stand in for a version the file
                # does state (#42 verify R2)
                problems.append(f"{safe(path)}: declares version/current but not as a string literal")
            elif vals:
                add(safe(path), vals[0], path)
            else:
                notes.append(f"{safe(path)}: no static version/current declaration; not a version source")
        elif parts[2] == "Server.swift":
            code = swift_code(show(path) or "")
            started = len(SERVER_ANY.findall(code))
            whole = [v for v in SERVER_VALUE.findall(code) if VERSIONISH.match(v)]
            vals = sorted(set(whole))
            if started > len(whole):
                problems.append(f"{safe(path)}: version: is not a plain string literal")
            elif len(vals) > 1:
                problems.append(f"{safe(path)}: several different versions {[safe(v) for v in vals]}")
            elif vals:
                add(safe(path), vals[0], path)

    json_version("mcpb/manifest.json", "mcpb/manifest.json")
    return found, problems, notes, paths

found, problems, notes, paths = read_sources(sha)
for name, value in found:
    print(f"SOURCE\t{safe(name)}\t{safe(value)}")
for p in problems:
    print(f"PROBLEM\t{oneline(p)}")
for n in notes:
    print(f"NOTE\t{oneline(n)}")

# --at-bump: walk back along the first-parent history over commits that touch any
# path of the closed list (deleted sources included — a commit that drops a stale
# source can be the one where the rest first agree); the release commit is the
# oldest commit of the newest run in
# which every source equals the current version. When that cannot be determined
# the run stops: a guessed commit would get a permanent tag (#42 verify R2).
values = {v for _, v in found}
if at_bump and found and not problems and len(values) == 1:
    current = next(iter(values))
    # every hatch path the pyproject.toml ever named, so a renamed version file's
    # history is walked too (#42 verify R5)
    old_hatch = []
    rp = git("rev-list", f"--max-count={MAX_WALK}", sha, "--", literal(prefix + "pyproject.toml"))
    for c in (rp.stdout.split() if rp.returncode == 0 else []):
        r_pp = git("cat-file", "blob", f"{c}:{prefix}pyproject.toml")
        hp = hatch_path(r_pp.stdout) if r_pp.returncode == 0 else None
        if hp:
            old_hatch.append(prefix + hp)
    # pathspec magic: the directory part is literal even when its name has [ ] * ?
    # (#42 verify R6); the Sources/*/ part keeps its one-level wildcard
    specs = list(dict.fromkeys(
        [(":(glob)" + glob_escape(prefix) + s) if "*" in s else literal(prefix + s) for s in SOURCE_SPECS]
        + [literal(x) for x in paths + old_hatch]))
    # --first-parent: the branch's own history. Across a merge, rev-list would
    # interleave both sides by date and the run could end on the other branch's bump
    # commit (#42 verify R7); with merge-commit PRs the tag lands on the merge commit,
    # the first commit on this branch whose sources agree.
    r = git("rev-list", "--first-parent", f"--max-count={MAX_WALK + 1}", sha, "--", *specs)
    candidates = r.stdout.split() if r.returncode == 0 else []
    release, stopped, unclear = None, False, None
    for c in candidates:
        f2, p2, _, _ = read_sources(c)
        vals2 = {v for _, v in f2}
        if f2 and not p2 and vals2 == {current}:
            release = c
            continue
        stopped = True
        # (a JSON manifest with no "version" field is not a source, so a commit before
        # the version existed is a definite boundary — #42 verify R4, R5, R6)
        if p2 and not (vals2 - {current}):
            # a source here cannot be read and every readable one already equals the
            # current version: it cannot be told whether the version was set here or
            # earlier (#42 verify R3)
            unclear = c
        break
    shallow = git("rev-parse", "--is-shallow-repository").stdout.strip() == "true"
    if r.returncode != 0:
        print(f"PROBLEM\tcannot walk the history of the version sources")
    elif unclear:
        print(f"PROBLEM\t--at-bump: the version sources at {unclear[:7]} cannot all be read, so it cannot tell whether {safe(current)} was already set there; not tagging a guess")
    elif not stopped and shallow:
        # the walk ran into the shallow boundary, which looks like the start of history
        print(f"PROBLEM\t--at-bump: this is a shallow clone and its history ends before the commit that set {safe(current)} can be confirmed; run git fetch --unshallow and retry")
    elif not stopped and len(candidates) > MAX_WALK:
        print(f"PROBLEM\t--at-bump reached its walk limit of {MAX_WALK} commits without finding where {safe(current)} was set; not tagging a guess")
    elif release is None:
        print(f"PROBLEM\t--at-bump cannot find the commit that set {safe(current)}; not tagging a guess")
    else:
        print(f"RELEASE\t{release}")
        if release != sha:
            later = git("rev-list", "--count", f"{release}..{sha}", "--", literal(prefix) if prefix else ".")
            n = later.stdout.strip() if later.returncode == 0 else "?"
            if n != "0":
                where = safe(prefix.rstrip("/")) if prefix else "the repository"
                print(f"NOTE\tthe tag goes on {release[:7]}, where {safe(current)} was set; commits after the tagged one that change {where}: {safe(n)}")
PY
SOURCES_OUT=$(python3 -I -c "$PYSRC" "$TOP" "$SHA" "$PREFIX" "$AT_BUMP" "$MAX_WALK") \
  || { echo "RELEASE_TAG: unreadable name=? commit=$(git -C "$TOP" rev-parse --short "$SHA") version=? sources=?"; echo "$PROG: python3 failed while reading versions" >&2; exit 21; }

field() { printf '%s\n' "$SOURCES_OUT" | awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}'; }
SOURCES=$(field SOURCE 2 | paste -sd, -)
VERSIONS=$(field SOURCE 3 | sort -u)
PROBLEMS=$(field PROBLEM 2)
NOTES=$(field NOTE 2)
RELEASE=$(field RELEASE 2)
[ -n "$NOTES" ] && printf '%s\n' "$NOTES" | sed "s/^/$PROG: note: /" >&2
if [ -n "$RELEASE" ]; then
  RELEASE=$(git -C "$TOP" rev-parse -q --verify "${RELEASE}^{commit}" 2>/dev/null) || RELEASE=""
fi
TARGET=${RELEASE:-$SHA}
SHORT=$(git -C "$TOP" rev-parse --short "$TARGET")

if [ -n "$PROBLEMS" ]; then
  echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=${SOURCES:-none}"
  printf '%s\n' "$PROBLEMS" | sed "s/^/$PROG: /" >&2
  exit 21
fi
if [ -z "$VERSIONS" ]; then
  if [ -n "$EXPECT" ]; then
    echo "$PROG: note: no version source under ${PREFIX:-the repository root} at $SHORT — using --expect $EXPECT" >&2
    VERSIONS=$EXPECT; SOURCES="--expect"
  else
    echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=none"
    echo "$PROG: no version source under ${PREFIX:-the repository root} at $SHORT" >&2
    exit 21
  fi
fi
if [ "$(printf '%s\n' "$VERSIONS" | grep -c .)" -gt 1 ]; then
  echo "RELEASE_TAG: mismatch name=? commit=$SHORT version=? sources=$SOURCES"
  printf '%s\n' "$SOURCES_OUT" | awk -F'\t' -v p="$PROG" '$1=="SOURCE"{printf "%s: %s = %s\n", p, $2, $3}' >&2
  exit 20
fi
VERSION=$VERSIONS
if [ -n "$EXPECT" ] && [ "$VERSION" != "$EXPECT" ]; then
  echo "RELEASE_TAG: mismatch name=? commit=$SHORT version=$VERSION sources=$SOURCES"
  echo "$PROG: the version files say $VERSION but this release is $EXPECT — bump them (see the skill's version list) and retry" >&2
  exit 20
fi
# Defence in depth: whatever came out of Python, the tag name is built only from
# values that pass these checks.
[[ "$VERSION" =~ $SEMVER_RE ]] || { echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=$SOURCES"; echo "$PROG: resolved version is not x.y.z" >&2; exit 21; }

case "$STYLE" in
  v)      NAME="v$VERSION" ;;
  plugin) NAME="$PLUGIN-v$VERSION" ;;
esac
case "$NAME" in *[!A-Za-z0-9._+-]*) echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=? sources=$SOURCES"; echo "$PROG: tag name has unexpected characters" >&2; exit 21 ;; esac
# git's own rules (no `..`, no trailing `.` or `.lock`, …): checked here so that
# --dry-run fails the same way the real run would (#42 verify R2)
git check-ref-format "refs/tags/$NAME" \
  || { echo "RELEASE_TAG: unreadable name=? commit=$SHORT version=$VERSION sources=$SOURCES"; echo "$PROG: $NAME is not a valid git tag name" >&2; exit 21; }
# the annotated tag's message names the repository (from the remote URL), not the
# checkout directory — a worktree directory is called idd-42 (#42 verify R1)
if [ -n "$PLUGIN" ]; then
  LABEL=$PLUGIN
else
  LABEL=$(git -C "$TOP" remote get-url "$REMOTE" 2>/dev/null | sed -E 's#/+$##; s#\.git$##; s#.*[/:]##')
  case "$LABEL" in ''|*[!A-Za-z0-9._-]*) LABEL=$(basename "$TOP") ;; esac
fi
LINE_TAIL="name=$NAME commit=$SHORT version=$VERSION sources=$SOURCES"

# The tag is looked up with ls-remote (the fetch URL) but pushed with `git push`
# (the push URL). If a remote pushes somewhere else, the lookup and the push talk to
# different repositories and the tag is published before anything notices (#42
# verify R3). Refuse before any push; the URLs are not printed (they may carry
# credentials). A --remote that is a URL or path, not a remote name, has one URL.
# The same repository written as https, ssh:// or scp form (the usual pushInsteadOf
# setup: fetch over https, push over ssh) is not a different repository (#42 verify R4).
norm_url() { printf '%s\n' "$1" | sed -E 's#/+$##; s#\.git$##; s#^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?##; s#^[^/@:]+@([^/:]+):#\1/#'; }
if FETCH_URL=$(git -C "$TOP" remote get-url "$REMOTE" 2>/dev/null); then
  PUSH_URLS=$(git -C "$TOP" remote get-url --push --all "$REMOTE" 2>/dev/null) || PUSH_URLS="?"
  PUSH_NORM=$(printf '%s\n' "$PUSH_URLS" | while IFS= read -r u; do norm_url "$u"; done | sort -u)
  if [ "$PUSH_NORM" != "$(norm_url "$FETCH_URL")" ]; then
    echo "RELEASE_TAG: push-failed $LINE_TAIL"
    echo "$PROG: remote '$REMOTE' has a push URL for a different repository than its fetch URL (remote.$REMOTE.pushurl or url.*.pushInsteadOf) - the tag would go where the checks never looked; nothing tagged or pushed. Fix the remote settings and retry." >&2
    exit 30
  fi
fi

if [ "$DRY" = 1 ]; then
  echo "RELEASE_TAG: dry-run $LINE_TAIL"
  exit 0
fi

RETRY="git -C $(printf '%q' "$TOP") push --no-follow-tags $REMOTE refs/tags/$NAME"
push_failed() {
  echo "RELEASE_TAG: push-failed $LINE_TAIL"
  echo "$PROG: $1" >&2
  echo "$PROG: retry with: $RETRY" >&2
  exit 30
}
# the commit a remote tag points at (peeled for annotated tags); empty when absent
remote_target() {
  local out peeled direct
  out=$(git -C "$TOP" ls-remote --tags "$REMOTE" "refs/tags/$NAME" "refs/tags/$NAME^{}") || return 1
  peeled=$(printf '%s\n' "$out" | awk -v n="refs/tags/$NAME^{}" '$2==n{print $1}')
  direct=$(printf '%s\n' "$out" | awk -v n="refs/tags/$NAME" '$2==n{print $1}')
  printf '%s\n' "${peeled:-$direct}"
}

# ---- 2. does the tag already exist? remote first, then local ----
REMOTE_AT=$(remote_target) || push_failed "cannot query remote '$REMOTE'"
if [ -n "$REMOTE_AT" ]; then
  if [ "$REMOTE_AT" = "$TARGET" ]; then
    echo "RELEASE_TAG: exists $LINE_TAIL"
    exit 0
  fi
  echo "RELEASE_TAG: not-bumped $LINE_TAIL"
  echo "$PROG: $NAME already points at $(git -C "$TOP" rev-parse --short "$REMOTE_AT" 2>/dev/null || echo "$REMOTE_AT") on $REMOTE — this version was released before, or an earlier release stopped after pushing its tag; nothing tagged" >&2
  exit 10
fi
LOCAL_AT=$(git -C "$TOP" rev-parse -q --verify "refs/tags/$NAME^{commit}" 2>/dev/null || true)
if [ -n "$LOCAL_AT" ] && [ "$LOCAL_AT" != "$TARGET" ]; then
  echo "RELEASE_TAG: not-bumped $LINE_TAIL"
  echo "$PROG: a local tag $NAME already points at $(git -C "$TOP" rev-parse --short "$LOCAL_AT") — not moving it; nothing tagged" >&2
  exit 10
fi

# ---- 3. create (unless a local tag on this commit is waiting to be pushed), push, read back ----
if [ -z "$LOCAL_AT" ]; then
  git -C "$TOP" tag -a "$NAME" -m "$LABEL $VERSION" "$TARGET" \
    || { echo "RELEASE_TAG: push-failed $LINE_TAIL"; echo "$PROG: git tag failed" >&2; exit 30; }
fi
# --no-follow-tags: an explicit refspec does not switch off push.followTags, which would
# also send every other local annotated tag reachable from this one (#42 verify R8)
git -C "$TOP" push --no-follow-tags "$REMOTE" "refs/tags/$NAME" >&2 || push_failed "git push of $NAME to '$REMOTE' failed"
AFTER=$(remote_target) || push_failed "cannot read $NAME back from '$REMOTE'"
[ "$AFTER" = "$TARGET" ] || push_failed "$NAME is not on '$REMOTE' at $SHORT after the push"
echo "RELEASE_TAG: tagged $LINE_TAIL"
