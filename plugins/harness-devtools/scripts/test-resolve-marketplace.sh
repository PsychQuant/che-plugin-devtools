#!/bin/bash
# Unit tests for resolve-marketplace.sh
#
# Run: bash scripts/test-resolve-marketplace.sh
# Exit 0 = all pass, 1 = any failure.
#
# Deliberately runs under /bin/bash (3.2 on macOS) — resolve-marketplace.sh must
# not use bash 4+ features (nameref, associative arrays). This mirrors the
# doc-update-config.sh `local -n` bug: shebang says #!/bin/bash, macOS gives you
# 3.2.57, and bash-4-only syntax fails silently mid-function.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "      expected: '$expected'"
    echo "      actual:   '$actual'"
  fi
}

assert_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc (expected non-zero exit, got 0)"
  else
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  fi
}

# ---------------------------------------------------------------------------

echo "Loading resolve-marketplace.sh ..."
# shellcheck source=./resolve-marketplace.sh
source "$SCRIPT_DIR/resolve-marketplace.sh"

echo
echo "resolve_marketplace_root:"
assert_eq "known marketplace → absolute path" \
  "$HOME/Developer/che-plugin-devtools" \
  "$(resolve_marketplace_root che-plugin-devtools)"

assert_eq "psychquant resolves" \
  "$HOME/Developer/psychquant-claude-plugins" \
  "$(resolve_marketplace_root psychquant-claude-plugins)"

assert_eq "che-local-plugins is nested inside che-claude-config" \
  "$HOME/Developer/che-claude-config/che-local-plugins" \
  "$(resolve_marketplace_root che-local-plugins)"

assert_fails "unknown marketplace returns non-zero" \
  resolve_marketplace_root no-such-marketplace

assert_fails "empty argument returns non-zero" \
  resolve_marketplace_root ""

echo
echo "list_marketplaces:"
# **不斷言確切數字。** 這裡原本是 `assert_eq "lists 4 marketplaces" "4"` ——
# 它不只沒抓到 registry 的覆蓋率缺口，還把缺口鎖住：任何人加第 5 個 marketplace
# 都會弄紅它。下界 + 「已知的都還在」才是這條該驗的東西。
COUNT=$(list_marketplaces | grep -c .)
if [ "$COUNT" -ge 4 ]; then
    PASS=$((PASS + 1)); echo "  ✓ lists at least the four originally hardcoded (got $COUNT)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ lists at least the four originally hardcoded"; echo "      actual: $COUNT"
fi

# Every listed name must itself resolve — guards against a name being added to
# the list but not to the case statement.
ORPHANS=""
for mp in $(list_marketplaces); do
  resolve_marketplace_root "$mp" >/dev/null 2>&1 || ORPHANS="$ORPHANS $mp"
done
assert_eq "every listed marketplace resolves" "" "$ORPHANS"

echo
echo "find_plugin_marketplace:"
# harness-devtools lives in this repo — the one certainty regardless of machine state.
# 三元組（#18）：第三欄是 manifest `plugins[].source` 解析出的 plugin 目錄，
# 不是 `$root/plugins/<name>` 的再約定。消費端用 IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR。
assert_eq "finds harness-devtools in che-plugin-devtools (name|root|plugin_dir)" \
  "che-plugin-devtools|$HOME/Developer/che-plugin-devtools|$HOME/Developer/che-plugin-devtools/plugins/harness-devtools" \
  "$(find_plugin_marketplace harness-devtools)"

assert_fails "unknown plugin returns non-zero" \
  find_plugin_marketplace definitely-not-a-real-plugin

assert_fails "empty plugin name returns non-zero" \
  find_plugin_marketplace ""

# 查一個 plugin 不該印出**別的** marketplace 的警告。find_plugin_marketplace 原本
# 對每個名稱各呼叫一次 resolve_marketplace_root，而後者在同名多候選時會 warn ——
# 於是查 macdoc 會噴出 che-apple-mail-mcp 的多重 checkout 警告。既有的 stderr 測試
# 只涵蓋 **source 當下**，涵蓋不到呼叫時，所以這條是另一個軸。
LOOKUP_NOISE=$(find_plugin_marketplace harness-devtools 2>&1 >/dev/null)
assert_eq "find_plugin_marketplace emits no stderr" "" "$LOOKUP_NOISE"

echo
echo
echo "discovery (#20) — registry is scanned, not enumerated:"

# 存在性先驗。沒有這兩條，下面用到 _marketplace_name_of / marketplace_candidates
# 的斷言在函式**不存在**時也會綠（呼叫失敗 → assert_fails 通過；無輸出 → grep
# 找不到東西）。假綠在函式日後被刪掉時同樣不會亮。
for fn in _marketplace_name_of marketplace_candidates; do
    if command -v "$fn" >/dev/null 2>&1 || type "$fn" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "  ✓ $fn is defined"
    else
        FAIL=$((FAIL + 1)); echo "  ✗ $fn is defined"
    fi
done

# 硬編的 4 筆漏掉本機 29 個 marketplace。macdoc 是觸發本 issue 的那一個：
# 它是正常運作的 self-hosted marketplace，plugin 也裝著，但 resolver 不認得。
assert_eq "macdoc resolves (was missing from the hardcoded case)" \
    "$HOME/Developer/macdoc" \
    "$(resolve_marketplace_root macdoc)"

# 不斷言確切數字 —— 那正是舊測試 `lists 4 marketplaces` 犯的錯（它把缺口鎖住，
# 任何人加第 5 個 marketplace 都會弄紅它）。下界即可。
DISCOVERED=$(list_marketplaces | grep -c .)
if [ "$DISCOVERED" -ge 20 ]; then
    PASS=$((PASS + 1)); echo "  ✓ discovers >= 20 marketplaces (got $DISCOVERED)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ discovers >= 20 marketplaces"; echo "      actual: $DISCOVERED"
fi

echo
echo "name extraction is bounded to the top-level key:"

# 樸素的「抓第一個 \"name\"」對這種 manifest 會靜默回傳 **plugin 的名字**當成
# marketplace 名。抽取必須限定在第一個 "plugins" 之前，取不到才退回真 JSON parser。
NAME_TMP=$(mktemp -d)
cat > "$NAME_TMP/plugins-first.json" <<'FIXTURE'
{
  "plugins": [ { "name": "some-plugin", "source": "./p" } ],
  "name": "real-marketplace-name"
}
FIXTURE
assert_eq "plugins-before-name manifest still yields the marketplace name" \
    "real-marketplace-name" \
    "$(_marketplace_name_of "$NAME_TMP/plugins-first.json")"

cat > "$NAME_TMP/normal.json" <<'FIXTURE'
{ "name": "ordinary", "plugins": [ { "name": "a-plugin" } ] }
FIXTURE
assert_eq "ordinary manifest yields its own name" \
    "ordinary" "$(_marketplace_name_of "$NAME_TMP/normal.json")"

assert_fails "missing manifest returns non-zero" \
    _marketplace_name_of "$NAME_TMP/does-not-exist.json"
rm -rf "$NAME_TMP"

echo
echo "multi-hit disambiguation:"

# che-local-plugins 有兩份 manifest 自報同名：父層 che-claude-config 是 aggregator
# （source 指進子層、自己沒有 plugins/），子層才是實體 marketplace。候選必須自帶
# plugins/ —— 這條規則讓上面那條既有斷言（解析到子層）繼續成立。
CANDS=$(marketplace_candidates che-local-plugins)
assert_eq "candidates exclude the aggregator parent (no plugins/ of its own)" \
    "" \
    "$(printf '%s\n' "$CANDS" | grep -x "$HOME/Developer/che-claude-config" || true)"

# git worktree 帶著同一份 marketplace.json。選中它會讓 plugin-update 的 Phase 0.5
# git gate 跑在 worktree 上 —— 正是 #16 要防的「gate 跑在錯的 repo 上」換一條路徑進來。
assert_eq "candidates exclude git worktrees" \
    "" \
    "$(marketplace_candidates che-local-plugins | grep -c '_wt-' | sed 's/^0$//')"

# 契約與姊妹檔 resolve-mcp-project.sh 的 mcp_project_candidates 對齊：
# 讓 caller 與測試看得到 shadowing，而不是靠推測。
assert_eq "candidates are one per line, resolve_marketplace_root takes the first" \
    "$(marketplace_candidates che-plugin-devtools | head -1)" \
    "$(resolve_marketplace_root che-plugin-devtools)"

echo
echo "marketplace layout independence:"

# **不是每個 marketplace 都有 plugins/ 目錄。** 單一 plugin 的 marketplace（rush、
# che-keychain、che-ical-mcp…）就是 repo 本身，manifest 的 source 寫 `./plugin`（單數）。
# 消歧規則若當成全域准入條件用，會把這一整類全部砍掉 —— 那是把 #20 的覆蓋率缺口
# 換一個機制重新造出來。所以 plugins/ 只在**同名多候選**時當 tie-break。
LAYOUT_TMP=$(mktemp -d)
mkdir -p "$LAYOUT_TMP/solo/.claude-plugin" "$LAYOUT_TMP/solo/plugin"
cat > "$LAYOUT_TMP/solo/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-solo", "plugins": [ { "name": "fixture-solo", "source": "./plugin" } ] }
JSON
# 同名兩份：父層無 plugins/、子層有 —— tie-break 必須選子層
mkdir -p "$LAYOUT_TMP/agg/.claude-plugin" "$LAYOUT_TMP/agg/real/.claude-plugin" "$LAYOUT_TMP/agg/real/plugins"
cat > "$LAYOUT_TMP/agg/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-dup", "plugins": [ { "name": "x", "source": "./real/plugins/x" } ] }
JSON
cat > "$LAYOUT_TMP/agg/real/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "fixture-dup", "plugins": [ { "name": "x", "source": "./plugins/x" } ] }
JSON

SAVED_ROOT="$MARKETPLACE_SEARCH_ROOT"
MARKETPLACE_SEARCH_ROOT="$LAYOUT_TMP"

assert_eq "single-plugin marketplace (no plugins/ dir) resolves" \
    "$LAYOUT_TMP/solo" \
    "$(resolve_marketplace_root fixture-solo)"

assert_eq "single-plugin marketplace is listed" \
    "fixture-solo" \
    "$(list_marketplaces | grep -x fixture-solo)"

assert_eq "plugins/-bearing candidate wins when two declare the same name" \
    "$LAYOUT_TMP/agg/real" \
    "$(resolve_marketplace_root fixture-dup)"

MARKETPLACE_SEARCH_ROOT="$SAVED_ROOT"
rm -rf "$LAYOUT_TMP"

echo
echo "plugin dir resolution (#18) — source comes from the manifest, not a layout guess:"

# **plugin 在哪裡，manifest 已經寫了。** `plugins[].source` 是 marketplace schema 既有的
# 欄位；在 #18 之前 find_plugin_marketplace 從不讀它，只探測 `$root/plugins/<name>`
# 是否存在 —— 於是 `source: "./plugin"` 的單一 plugin marketplace 一律 rc=1，而
# plugin-update 的 Step 0.1 把它讀成「不在任何 marketplace」。
#
# 三個 rc 各有語意，消費端靠它們決定 abort 訊息：
#   0  entry 在、source 是相對路徑、目錄存在 → 印絕對 dir
#   1  manifest 沒有這個 entry
#   2  entry 在，但 source 不是相對路徑（github: / URL / 絕對路徑）或目錄不存在
PD_TMP=$(mktemp -d)
mkdir -p "$PD_TMP/solo/.claude-plugin" "$PD_TMP/solo/plugin/.claude-plugin"
cat > "$PD_TMP/solo/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-solo", "plugins": [ { "name": "pd-solo", "source": "./plugin" } ] }
JSON
printf '{ "name": "pd-solo", "version": "0.0.1" }\n' > "$PD_TMP/solo/plugin/.claude-plugin/plugin.json"
mkdir -p "$PD_TMP/agg/.claude-plugin" "$PD_TMP/agg/plugins/x/.claude-plugin"
printf '{ "name": "x" }\n' > "$PD_TMP/agg/plugins/x/.claude-plugin/plugin.json"
cat > "$PD_TMP/agg/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-agg",
  "plugins": [
    { "name": "x",        "source": "./plugins/x" },
    { "name": "ghost",    "source": "./plugins/ghost" },
    { "name": "remote",   "source": "github:someone/remote" },
    { "name": "absolute", "source": "/tmp/absolute" }
  ] }
JSON

SAVED_ROOT="$MARKETPLACE_SEARCH_ROOT"
MARKETPLACE_SEARCH_ROOT="$PD_TMP"

assert_eq "resolve_plugin_dir: ./plugin (single-plugin layout)" \
    "$PD_TMP/solo/plugin" \
    "$(resolve_plugin_dir "$PD_TMP/solo" pd-solo)"

assert_eq "resolve_plugin_dir: ./plugins/x (aggregator layout)" \
    "$PD_TMP/agg/plugins/x" \
    "$(resolve_plugin_dir "$PD_TMP/agg" x)"

resolve_plugin_dir "$PD_TMP/agg" nope >/dev/null 2>&1; RC_NOENTRY=$?
assert_eq "resolve_plugin_dir: no entry → rc 1" "1" "$RC_NOENTRY"

resolve_plugin_dir "$PD_TMP/agg" ghost >/dev/null 2>&1; RC_GHOST=$?
assert_eq "resolve_plugin_dir: entry present but dir missing → rc 2" "2" "$RC_GHOST"

resolve_plugin_dir "$PD_TMP/agg" remote >/dev/null 2>&1; RC_REMOTE=$?
assert_eq "resolve_plugin_dir: github: source with nothing materialized → rc 5 (non-local, not broken)" "5" "$RC_REMOTE"

resolve_plugin_dir "$PD_TMP/agg" absolute >/dev/null 2>&1; RC_ABS=$?
assert_eq "resolve_plugin_dir: absolute source → rc 2" "2" "$RC_ABS"

assert_eq "find_plugin_marketplace: single-plugin layout yields name|root|plugin_dir" \
    "pd-solo|$PD_TMP/solo|$PD_TMP/solo/plugin" \
    "$(find_plugin_marketplace pd-solo)"

assert_eq "find_plugin_marketplace: aggregator layout yields name|root|plugin_dir" \
    "pd-agg|$PD_TMP/agg|$PD_TMP/agg/plugins/x" \
    "$(find_plugin_marketplace x)"

# entry 在但目錄不在：對 find_plugin_marketplace 是「不命中」（同名 plugin 可能在
# 另一個 checkout 是完整的），不是「命中一個壞路徑」。
assert_fails "find_plugin_marketplace: entry whose dir is missing is not a hit" \
    find_plugin_marketplace ghost

PD_NOISE=$( { resolve_plugin_dir "$PD_TMP/agg" ghost; resolve_plugin_dir "$PD_TMP/agg" nope; \
              find_plugin_marketplace pd-solo; find_plugin_marketplace ghost; } 2>&1 >/dev/null )
assert_eq "plugin dir resolution emits no stderr" "" "$PD_NOISE"

# ── R1 verify of #18 found six ways "cannot tell" or "legal but non-local" still
# read as "no", plus a code-execution hole through the path itself. Each one
# below broke before the fix; the comments say what the old code did.
# legacy-probed directories carry no plugin.json (materialized subtrees) but must look like a plugin
mkdir -p "$PD_TMP/agg/plugins/akashic/skills" "$PD_TMP/agg/plugins/newbie/skills" "$PD_TMP/agg/true" "$PD_TMP/agg/plugins/q/skills" "$PD_TMP/agg/plugins/emptydir"
cat > "$PD_TMP/agg/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-agg",
  "plugins": [
    { "name": "x",        "source": "./plugins/x" },
    { "name": "ghost",    "source": "./plugins/ghost" },
    { "name": "remote",   "source": "github:someone/remote" },
    { "name": "absolute", "source": "/tmp/absolute" },
    { "name": "akashic",  "source": { "source": "git-subdir", "url": "https://example.invalid/a.git", "path": "plugin" } },
    { "name": "orphan",   "source": { "source": "git-subdir", "url": "https://example.invalid/o.git", "path": "plugin" } },
    { "name": "empty",    "source": "" },
    { "name": "boolean",  "source": true },
    { "name": "trav",     "source": "../outside" },
    { "name": "quoted",   "source": "./plugins/q'+x" },
    { "name": "newline",  "source": "./plugins/q\nx" }
  ] }
JSON
mkdir -p "$PD_TMP/rootplugin/.claude-plugin" "$PD_TMP/claimant/.claude-plugin"
cat > "$PD_TMP/rootplugin/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-root", "plugins": [ { "name": "dot", "source": "." }, { "name": "dotslash", "source": "./" } ] }
JSON
printf '{ "name": "dot", "version": "0.0.1" }\n' > "$PD_TMP/rootplugin/.claude-plugin/plugin.json"   # root IS the plugin
# a manifest that declares `.` for a name it does not host (no plugin.json at its root)
cat > "$PD_TMP/claimant/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-claimant", "plugins": [ { "name": "x", "source": "." } ] }
JSON
mkdir -p "$PD_TMP/broken/.claude-plugin" "$PD_TMP/broken/plugins/present/.claude-plugin"
printf '{ "name": "pd-broken", "plugins": [ { "name": "present", "source": "./plugins/present" }, ] }\n' \
  > "$PD_TMP/broken/.claude-plugin/marketplace.json"     # trailing comma: the canonical hand-edit error

# object source (git-subdir) with its subtree materialized under plugins/<name> —
# akashic-mcp on this machine. Old code: rc 2 → "fix your manifest" for a legal manifest.
assert_eq "object source + materialized plugins/<name> → the materialized dir" \
    "$PD_TMP/agg/plugins/akashic" "$(resolve_plugin_dir "$PD_TMP/agg" akashic)"
resolve_plugin_dir "$PD_TMP/agg" orphan >/dev/null 2>&1; RC_ORPHAN=$?
assert_eq "object source with nothing materialized → rc 5" "5" "$RC_ORPHAN"
assert_eq "plugin_source_of prints the object source verbatim (rc 5 to the caller)" \
    '{"source": "git-subdir", "url": "https://example.invalid/o.git", "path": "plugin"}' \
    "$(plugin_source_of "$PD_TMP/agg" orphan)"

# entry-less directory: the "new plugin, add its entry" state Phase 2 Step 3 of
# plugin-update exists for. Old code: rc 1 → Step 0.1 abort, Step 3 unreachable.
assert_eq "no entry but plugins/<name> exists → still a hit (name|root|plugin_dir)" \
    "pd-agg|$PD_TMP/agg|$PD_TMP/agg/plugins/newbie" "$(find_plugin_marketplace newbie)"

# unreadable manifest: cannot tell ≠ no. Old code: rc 1 for both of these.
assert_eq "unparsable manifest + materialized dir → the dir" \
    "$PD_TMP/broken/plugins/present" "$(resolve_plugin_dir "$PD_TMP/broken" present)"
# the listed plugin, no materialized dir, manifest unparsable: the trailing-comma
# case from R1 — old code answered "not on this marketplace" (rc 1)
mkdir -p "$PD_TMP/broken2/.claude-plugin"
printf '{ "name": "pd-broken2", "plugins": [ { "name": "present", "source": "./plugin" }, ] }\n' \
  > "$PD_TMP/broken2/.claude-plugin/marketplace.json"
resolve_plugin_dir "$PD_TMP/broken2" present >/dev/null 2>&1; RC_BROKEN=$?
assert_eq "unparsable manifest that names the plugin + nothing materialized → rc 4" "4" "$RC_BROKEN"
resolve_plugin_dir "$PD_TMP/broken" absent >/dev/null 2>&1; RC_BROKEN_ABSENT=$?
assert_eq "unparsable manifest that never mentions the name → rc 1 (pre-filter; not listed anywhere)" "1" "$RC_BROKEN_ABSENT"

# repo-root-is-the-plugin: legal layout, resolves to root itself
assert_eq 'source "." resolves to the marketplace root' "$PD_TMP/rootplugin" "$(resolve_plugin_dir "$PD_TMP/rootplugin" dot)"
resolve_plugin_dir "$PD_TMP/rootplugin" dotslash >/dev/null 2>&1; RC_DOTSLASH=$?
assert_eq 'source "./" for a name the root plugin.json does not carry -> rc 2 (possession = the plugin.json name)' "2" "$RC_DOTSLASH"

# unusable local-looking sources → rc 2, never a directory (the quoted one was a
# confirmed arbitrary-code-execution path through `python3 -c "...'$PLUGIN_DIR'..."`)
for bad in empty boolean trav quoted newline; do
  resolve_plugin_dir "$PD_TMP/agg" "$bad" >/dev/null 2>&1; RC_BAD=$?
  assert_eq "unusable source ($bad) → rc 2" "2" "$RC_BAD"
done
resolve_plugin_dir "$PD_TMP/agg" "../x" >/dev/null 2>&1; RC_BADNAME=$?
assert_eq "plugin NAME with a path segment -> rc 6 (its own code: the manifest is not to blame)" "6" "$RC_BADNAME"
resolve_plugin_dir "$PD_TMP/agg" 'x"; echo pwned' >/dev/null 2>&1; RC_BADNAME2=$?
assert_eq "plugin NAME with shell metacharacters -> rc 6" "6" "$RC_BADNAME2"
assert_fails "find_plugin_marketplace refuses an invalid name without walking" find_plugin_marketplace 'x"; echo pwned'


# the manifest is the source of truth for names; paths map through it
# declared + materialized: newbie and q have directories but no entry; the plugin
# that most needs plugin-update (its entry is not written yet) must not vanish here
assert_eq "marketplace_plugin_names = declared names UNION plugins/ directories, sorted, deduped" \
    "absolute akashic boolean empty ghost newbie newline orphan q quoted remote trav x" \
    "$(marketplace_plugin_names "$PD_TMP/agg" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "plugin_names_for_paths sees an entry-less plugins/<name> directory" \
    "newbie" "$(printf 'plugins/newbie/skills/a/SKILL.md\n' | plugin_names_for_paths "$PD_TMP/agg")"
assert_eq "marketplace_index yields name<TAB>root for the fixtures" \
    "pd-agg" "$(marketplace_index | awk -F'\t' '$1 == "pd-agg" { print $1 }')"
assert_eq "plugin_names_for_paths maps ./plugin layout paths (not plugins/<x>/)" \
    "pd-solo" "$(printf 'plugin/skills/a/SKILL.md\nREADME.md\n' | plugin_names_for_paths "$PD_TMP/solo")"
assert_eq "plugin_names_for_paths: root-is-plugin owns every path (by design; see resolve_plugin_dir)" \
    "dot" "$(printf 'anything.md\n' | plugin_names_for_paths "$PD_TMP/rootplugin" | tr '\n' ' ' | sed 's/ $//')"
resolve_plugin_dir "$PD_TMP/claimant" x >/dev/null 2>&1; RC_CLAIM=$?
assert_eq 'source "." without plugin.json at the root -> rc 2 (declaration is not possession)' "2" "$RC_CLAIM"
assert_eq "plugin_names_for_paths: unrelated paths map to nothing" \
    "" "$(printf 'docs/x.md\n' | plugin_names_for_paths "$PD_TMP/agg")"

# python3 present but not runnable (macOS CLT stub) → legacy probe, not "not found"
FAKEBIN=$(mktemp -d); printf '#!/bin/sh\necho "xcode-select: note: No developer tools were found." >&2\nexit 1\n' > "$FAKEBIN/python3"; chmod +x "$FAKEBIN/python3"
assert_eq "broken python3 interpreter → legacy plugins/<name> probe still hits" \
    "$PD_TMP/agg/plugins/x" "$(PATH="$FAKEBIN:$PATH" resolve_plugin_dir "$PD_TMP/agg" x)"
PATH="$FAKEBIN:$PATH" resolve_plugin_dir "$PD_TMP/solo" pd-solo >/dev/null 2>&1; RC_FAKE=$?
assert_eq "broken python3 + ./plugin layout (nothing under plugins/) -> rc 3 (cannot tell), never rc 1" "3" "$RC_FAKE"
rm -rf "$FAKEBIN"
# no python3 at all (command -v fails) → same legacy probe
NOPY=$(bash -c 'command() { [ "$2" = python3 ] && return 1; builtin command "$@"; }; source "'"$SCRIPT_DIR"'/resolve-marketplace.sh"; resolve_plugin_dir "'"$PD_TMP"'/agg" x')
assert_eq "no python3 → legacy plugins/<name> probe" "$PD_TMP/agg/plugins/x" "$NOPY"

# R2 verify: symlink escape, field separator, equivalent spellings, sanitized source
mkdir -p "$PD_TMP/link/.claude-plugin" "$PD_TMP/outside"
ln -s "$PD_TMP/outside" "$PD_TMP/link/plugin"
cat > "$PD_TMP/link/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-link", "plugins": [ { "name": "esc", "source": "./plugin" }, { "name": "pipe", "source": "./pl|ugin" },
                                  { "name": "ctrl", "source": "./plugin\tx" } ] }
JSON
resolve_plugin_dir "$PD_TMP/link" esc >/dev/null 2>&1; RC_ESC=$?
assert_eq "source dir that is a symlink to outside the root -> rc 2 (physical containment)" "2" "$RC_ESC"
resolve_plugin_dir "$PD_TMP/link" pipe >/dev/null 2>&1; RC_PIPE=$?
assert_eq "source containing the | field separator -> rc 2" "2" "$RC_PIPE"
mkdir -p "$PD_TMP/norm/.claude-plugin" "$PD_TMP/norm/plugin/skills" "$PD_TMP/norm/plugin/.claude-plugin" "$PD_TMP/norm/plugin2/.claude-plugin" "$PD_TMP/norm/noname/.claude-plugin"
cat > "$PD_TMP/norm/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-norm", "plugins": [ { "name": "dotted", "source": "./plugin/." }, { "name": "doubled", "source": ".//plugin2//" }, { "name": "noname", "source": "./noname" } ] }
JSON
printf '{ "name": "dotted" }\n' > "$PD_TMP/norm/plugin/.claude-plugin/plugin.json"
printf '{ "name": "doubled" }\n' > "$PD_TMP/norm/plugin2/.claude-plugin/plugin.json"
printf '{ "version": "0.0.1" }\n' > "$PD_TMP/norm/noname/.claude-plugin/plugin.json"   # no name: NOT proof of possession
assert_eq 'source "./plugin/." normalizes to the plugin dir' "$PD_TMP/norm/plugin" "$(resolve_plugin_dir "$PD_TMP/norm" dotted)"
assert_eq 'source ".//plugin2//" normalizes to the plugin dir' "$PD_TMP/norm/plugin2" "$(resolve_plugin_dir "$PD_TMP/norm" doubled)"
assert_eq "normalized sources still map paths" "dotted" \
    "$(printf 'plugin/skills/a.md\n' | plugin_names_for_paths "$PD_TMP/norm" | tr '\n' ' ' | sed 's/ $//')"
resolve_plugin_dir "$PD_TMP/norm" noname >/dev/null 2>&1; RC_NONAME=$?
assert_eq "plugin.json without a name is not proof of possession -> rc 2 (fail closed)" "2" "$RC_NONAME"
assert_eq "a source with a control character is classified unusable and shown JSON-escaped (rc 2 to the caller)" \
    '"./plugin\tx"' "$(plugin_source_of "$PD_TMP/link" ctrl; :)"
resolve_plugin_dir "$PD_TMP/link" ctrl >/dev/null 2>&1; RC_CTRL=$?
assert_eq "control character in source -> rc 2" "2" "$RC_CTRL"
assert_eq "plugin_source_of shows a non-string source as JSON (rc 2 to the caller)" \
    "true" "$(plugin_source_of "$PD_TMP/agg" boolean; :)"

# R3 verify: possession, legacy symlink, nested marketplace, ctx hand-off, name filtering
mkdir -p "$PD_TMP/poss/.claude-plugin" "$PD_TMP/poss/docs" "$PD_TMP/poss/other/.claude-plugin" "$PD_TMP/poss/plugins"
cat > "$PD_TMP/poss/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-poss", "plugins": [ { "name": "typo", "source": "./docs" }, { "name": "wrongname", "source": "./other" }, { "name": "che-keychain", "source": "." } ] }
JSON
printf '{ "name": "somebody-else" }\n' > "$PD_TMP/poss/other/.claude-plugin/plugin.json"
printf '{ "name": "evil-thing" }\n' > "$PD_TMP/poss/.claude-plugin/plugin.json"
resolve_plugin_dir "$PD_TMP/poss" typo >/dev/null 2>&1; RC_TYPO=$?
assert_eq "manifest source pointing at a directory that is not a plugin (no plugin.json) -> rc 2" "2" "$RC_TYPO"
resolve_plugin_dir "$PD_TMP/poss" wrongname >/dev/null 2>&1; RC_WRONG=$?
assert_eq "manifest source pointing at a plugin whose plugin.json names something else -> rc 2" "2" "$RC_WRONG"
resolve_plugin_dir "$PD_TMP/poss" che-keychain >/dev/null 2>&1; RC_CLAIM2=$?
assert_eq 'root that IS some plugin cannot claim a foreign name with "." -> rc 2' "2" "$RC_CLAIM2"
ln -s "$PD_TMP/outside" "$PD_TMP/poss/plugins/escape"
assert_fails "legacy plugins/<name> that is a symlink to outside the root is refused (same containment as the manifest path)" \
    resolve_plugin_dir "$PD_TMP/poss" escape
assert_fails "…and find_plugin_marketplace does not return it as a hit" find_plugin_marketplace escape

# nested marketplace: the marketplace root is a SUBDIRECTORY of the git toplevel, and
# git prints paths relative to the toplevel (che-local-plugins inside che-claude-config)
if command -v git >/dev/null 2>&1; then
  mkdir -p "$PD_TMP/repo/sub/.claude-plugin" "$PD_TMP/repo/sub/plugins/nest/.claude-plugin"
  cat > "$PD_TMP/repo/sub/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-nested", "plugins": [ { "name": "nest", "source": "./plugins/nest" } ] }
JSON
  printf '{ "name": "nest" }\n' > "$PD_TMP/repo/sub/plugins/nest/.claude-plugin/plugin.json"
  git -C "$PD_TMP/repo" init -q 2>/dev/null
  assert_eq "plugin_names_for_paths aligns git-toplevel-relative paths to a nested marketplace root" \
      "nest" "$(printf 'sub/plugins/nest/skills/a.md\n' | plugin_names_for_paths "$PD_TMP/repo/sub")"
  assert_eq "plugin_names_for_paths: toplevel-relative path outside the nested root maps to nothing" \
      "" "$(printf 'plugins/nest/skills/a.md\n' | plugin_names_for_paths "$PD_TMP/repo/sub")"
fi

# Step 0.1 → later fences hand-off
CTX="$PD_TMP/ctx"
write_plugin_ctx "$CTX" pd-agg "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" x; RC_W=$?
assert_eq "write_plugin_ctx writes a valid triple" "0" "$RC_W"
CTX_LOADED=$(load_plugin_ctx "$CTX" x >/dev/null 2>&1 && printf '%s|%s|%s' "$MP_NAME" "$MP_ROOT" "$PLUGIN_DIR")
assert_eq "load_plugin_ctx restores and re-verifies the triple" "pd-agg|$PD_TMP/agg|$PD_TMP/agg/plugins/x" "$CTX_LOADED"
load_plugin_ctx "$CTX" ghost >/dev/null 2>&1; RC_L1=$?
assert_eq "load_plugin_ctx refuses a context written for another plugin -> rc 2" "2" "$RC_L1"
write_plugin_ctx "$CTX" "ok'; touch pwned; #" "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" x >/dev/null 2>&1; RC_W2=$?
assert_eq "write_plugin_ctx refuses a marketplace name outside [A-Za-z0-9._-] -> rc 6" "6" "$RC_W2"
printf 'MP_NAME=pd-agg\nMP_ROOT=%s\nPLUGIN_DIR=%s\nPLUGIN_NAME=x\nWRITTEN_EPOCH=%s\n' "$PD_TMP/solo" "$PD_TMP/agg/plugins/x" "$(date +%s)" > "$CTX"
load_plugin_ctx "$CTX" x >/dev/null 2>&1; RC_L2=$?
assert_eq "load_plugin_ctx refuses a root that is not a checkout of that marketplace (tampered file) -> rc 2" "2" "$RC_L2"
printf 'MP_NAME=pd-agg\nMP_ROOT=%s\nPLUGIN_DIR=%s\nPLUGIN_NAME=x\nWRITTEN_EPOCH=%s\n' "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" "$(( $(date +%s) - 90000 ))" > "$CTX"
load_plugin_ctx "$CTX" x >/dev/null 2>&1; RC_L8=$?
assert_eq "load_plugin_ctx refuses a context older than the TTL (left by an aborted run) -> rc 2" "2" "$RC_L8"
load_plugin_ctx "$PD_TMP/nope.ctx" x >/dev/null 2>&1; RC_L3=$?
assert_eq "load_plugin_ctx without a context file -> rc 1" "1" "$RC_L3"
load_plugin_ctx "$CTX" 'x"; echo pwned' >/dev/null 2>&1; RC_L4=$?
assert_eq "load_plugin_ctx with an invalid plugin name -> rc 6" "6" "$RC_L4"

# public name listing never hands back an unresolvable third-party string
mkdir -p "$PD_TMP/badnames/.claude-plugin" "$PD_TMP/badnames/plugins/fine"
cat > "$PD_TMP/badnames/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-badnames", "plugins": [ { "name": "fine", "source": "./plugins/fine" }, { "name": "bad name; rm -rf x", "source": "./plugins/fine" } ] }
JSON
assert_eq "marketplace_plugin_names drops names outside [A-Za-z0-9._-]" "fine" "$(marketplace_plugin_names "$PD_TMP/badnames" | tr '\n' ' ' | sed 's/ $//')"

# R4 verify: typo'd source is definite, empty legacy dir is not a plugin, broken plugin.json fails closed,
# context file is data (never sourced), refused when symlinked / foreign
mkdir -p "$PD_TMP/typo/.claude-plugin" "$PD_TMP/typo/plugins/x/.claude-plugin"
printf '{ "name": "x" }\n' > "$PD_TMP/typo/plugins/x/.claude-plugin/plugin.json"
cat > "$PD_TMP/typo/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-typo", "plugins": [ { "name": "x", "source": "./plugns/x" } ] }
JSON
resolve_plugin_dir "$PD_TMP/typo" x >/dev/null 2>&1; RC_TYPO2=$?
assert_eq "typo'd relative source is NOT rescued by an existing plugins/<name> -> rc 2 (definite error)" "2" "$RC_TYPO2"
resolve_plugin_dir "$PD_TMP/agg" emptydir >/dev/null 2>&1; RC_EMPTYDIR=$?
assert_eq "an empty plugins/<name> directory is not a plugin -> rc 1" "1" "$RC_EMPTYDIR"
mkdir -p "$PD_TMP/brokenpj/.claude-plugin"
printf '{ not json\n' > "$PD_TMP/brokenpj/.claude-plugin/plugin.json"
cat > "$PD_TMP/brokenpj/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-brokenpj", "plugins": [ { "name": "harness-devtools", "source": "." } ] }
JSON
resolve_plugin_dir "$PD_TMP/brokenpj" harness-devtools >/dev/null 2>&1; RC_BPJ=$?
assert_eq "unparsable plugin.json at a '.' root cannot claim a name -> rc 2 (fail closed)" "2" "$RC_BPJ"
for n in .hidden -flag; do
  resolve_plugin_dir "$PD_TMP/agg" "$n" >/dev/null 2>&1; RC_N=$?
  assert_eq "name '$n' (dotfile / option shaped) -> rc 6" "6" "$RC_N"
done

# context file: written into a private dir, data-only, never executed
CTXDIR="$PD_TMP/state"
CTX2="$CTXDIR/plugin-update-ctx-x"
write_plugin_ctx "$CTX2" pd-agg "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" x; RC_W3=$?
assert_eq "write_plugin_ctx creates the private dir and the file" "0" "$RC_W3"
assert_eq "context dir is mode 700" "700" "$(stat -f %Lp "$CTXDIR" 2>/dev/null || stat -c %a "$CTXDIR")"
assert_eq "context file is mode 600" "600" "$(stat -f %Lp "$CTX2" 2>/dev/null || stat -c %a "$CTX2")"
printf 'MP_NAME=pd-agg\nMP_ROOT=%s\nPLUGIN_DIR=%s\nPLUGIN_NAME=x\nWRITTEN_EPOCH=%s\ntouch "%s/EXECUTED"\n' "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" "$(date +%s)" "$PD_TMP" > "$CTX2"
load_plugin_ctx "$CTX2" x >/dev/null 2>&1; RC_L5=$?
assert_eq "a command line inside the context file is never executed (load parses, does not source)" "0:absent" "$RC_L5:$([ -e "$PD_TMP/EXECUTED" ] && echo EXECUTED || echo absent)"
printf 'MP_NAME=pd-agg\nMP_ROOT=%s\nPLUGIN_DIR=%s$(touch %s/EXECUTED2)\nPLUGIN_NAME=x\nWRITTEN_EPOCH=%s\n' "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" "$PD_TMP" "$(date +%s)" > "$CTX2"
load_plugin_ctx "$CTX2" x >/dev/null 2>&1; RC_L6=$?
assert_eq "shell-significant bytes in a context value are refused, not evaluated" "2:absent" "$RC_L6:$([ -e "$PD_TMP/EXECUTED2" ] && echo EXECUTED2 || echo absent)"
printf 'ORIGINAL SECRET\n' > "$PD_TMP/victim.txt"
ln -sf "$PD_TMP/victim.txt" "$CTX2"
write_plugin_ctx "$CTX2" pd-agg "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" x >/dev/null 2>&1
assert_eq "write_plugin_ctx onto a planted symlink replaces the link and leaves the target untouched" \
    "ORIGINAL SECRET" "$(cat "$PD_TMP/victim.txt")"
assert_eq "…and the context path is now a regular file" "regular" "$([ -L "$CTX2" ] && echo symlink || echo regular)"
ln -sf "$PD_TMP/victim.txt" "$CTXDIR/plugin-update-ctx-linked"
load_plugin_ctx "$CTXDIR/plugin-update-ctx-linked" x >/dev/null 2>&1; RC_L7=$?
assert_eq "load_plugin_ctx refuses a symlinked context -> rc 3" "3" "$RC_L7"
remove_plugin_ctx "$CTX2"
assert_eq "remove_plugin_ctx deletes the file" "gone" "$([ -e "$CTX2" ] && echo present || echo gone)"
assert_eq "plugin_ctx_path derives a per-plugin file under the state dir" \
    "$(plugin_ctx_dir)/plugin-update-ctx-x" "$(plugin_ctx_path x)"
assert_fails "plugin_ctx_path refuses an invalid name" plugin_ctx_path 'x;y'

# R5 verify: root-level plugin.json, one possession rule for both paths, index-based ctx re-verify
mkdir -p "$PD_TMP/rootpj/.claude-plugin" "$PD_TMP/rootpj/plugins/bare/skills"
printf '{ "name": "bare", "version": "1" }\n' > "$PD_TMP/rootpj/plugins/bare/plugin.json"   # manifest at the plugin ROOT (safari-browser layout)
cat > "$PD_TMP/rootpj/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-rootpj", "plugins": [ { "name": "bare", "source": "./plugins/bare" } ] }
JSON
assert_eq "a plugin whose plugin.json sits at its root (not .claude-plugin/) resolves" \
    "$PD_TMP/rootpj/plugins/bare" "$(resolve_plugin_dir "$PD_TMP/rootpj" bare)"
mkdir -p "$PD_TMP/rename/.claude-plugin" "$PD_TMP/rename/plugins/foo/.claude-plugin"
printf '{ "name": "foo-renamed" }\n' > "$PD_TMP/rename/plugins/foo/.claude-plugin/plugin.json"
printf '{ "name": "pd-rename", "plugins": [] }\n' > "$PD_TMP/rename/.claude-plugin/marketplace.json"
resolve_plugin_dir "$PD_TMP/rename" foo >/dev/null 2>&1; RC_REN=$?
assert_eq "legacy plugins/<name> whose own plugin.json names something else is NOT possessed (one rule for both paths; unlisted -> rc 1)" "1" "$RC_REN"
# nested same-name marketplaces: the parent (no plugins/) sorts first in the index; Step 0.1 resolves through it,
# and load_plugin_ctx must accept that root — marketplace_candidates' tie-break would drop it (che-local-plugins, #18 R5)
mkdir -p "$PD_TMP/nest/.claude-plugin" "$PD_TMP/nest/inner/.claude-plugin" "$PD_TMP/nest/inner/plugins/np/.claude-plugin"
printf '{ "name": "np" }\n' > "$PD_TMP/nest/inner/plugins/np/.claude-plugin/plugin.json"
cat > "$PD_TMP/nest/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-nest", "plugins": [ { "name": "np", "source": "./inner/plugins/np" } ] }
JSON
cat > "$PD_TMP/nest/inner/.claude-plugin/marketplace.json" <<'JSON'
{ "name": "pd-nest", "plugins": [ { "name": "np", "source": "./plugins/np" } ] }
JSON
NEST_HIT=$(find_plugin_marketplace np); IFS='|' read -r NMP NROOT NDIR <<< "$NEST_HIT"
write_plugin_ctx "$PD_TMP/state/plugin-update-ctx-np" "$NMP" "$NROOT" "$NDIR" np
load_plugin_ctx "$PD_TMP/state/plugin-update-ctx-np" np >/dev/null 2>&1; RC_NEST=$?
assert_eq "load_plugin_ctx accepts the very root find_plugin_marketplace chose for a nested same-name marketplace" "0:$NROOT" "$RC_NEST:$MP_ROOT"

PD_NOISE2=$( { resolve_plugin_dir "$PD_TMP/agg" orphan; resolve_plugin_dir "$PD_TMP/broken" absent; resolve_plugin_dir "$PD_TMP/agg" quoted; \
               marketplace_plugin_names "$PD_TMP/broken"; printf 'x\n' | plugin_names_for_paths "$PD_TMP/solo"; } 2>&1 >/dev/null )
assert_eq "new rc branches and helpers emit no stderr" "" "$PD_NOISE2"
# the one deliberate stderr: a name that cannot be resolved is REPORTED, not silently uncounted
PNP_WARN=$(printf 'plugins/ghost/a.md\n' | plugin_names_for_paths "$PD_TMP/agg" 2>&1 >/dev/null | grep -c "'ghost' did not resolve (rc 2)")
assert_eq "plugin_names_for_paths reports an unresolvable name on stderr with its rc" "1" "$PNP_WARN"

# R6 verify: manifest path helper, holders dedup by physical dir, load assigns only on success,
# TTL hardening, GNU-stat fallback, marketplace names allowlisted at the index
assert_eq "plugin_manifest_path finds .claude-plugin/plugin.json" \
    "$PD_TMP/agg/plugins/x/.claude-plugin/plugin.json" "$(plugin_manifest_path "$PD_TMP/agg/plugins/x")"
assert_eq "plugin_manifest_path finds a root-level plugin.json (safari-browser layout)" \
    "$PD_TMP/rootpj/plugins/bare/plugin.json" "$(plugin_manifest_path "$PD_TMP/rootpj/plugins/bare")"
mkdir -p "$PD_TMP/agg/plugins/nomani/skills"
plugin_manifest_path "$PD_TMP/agg/plugins/nomani" >/dev/null 2>&1; RC_PM=$?
assert_eq "plugin_manifest_path on a manifest-less plugin dir -> rc 1, nothing printed" "1:" "$RC_PM:$(plugin_manifest_path "$PD_TMP/agg/plugins/nomani" 2>/dev/null)"
assert_fails "plugin_manifest_path refuses a missing dir" plugin_manifest_path "$PD_TMP/agg/plugins/absent"
# load_plugin_ctx exports PLUGIN_MANIFEST alongside the triple
write_plugin_ctx "$PD_TMP/state/plugin-update-ctx-bare" pd-rootpj "$PD_TMP/rootpj" "$PD_TMP/rootpj/plugins/bare" bare
PLUGIN_MANIFEST=""; load_plugin_ctx "$PD_TMP/state/plugin-update-ctx-bare" bare >/dev/null 2>&1
assert_eq "load_plugin_ctx sets PLUGIN_MANIFEST from the same lookup possession used" "$PD_TMP/rootpj/plugins/bare/plugin.json" "$PLUGIN_MANIFEST"
# a FAILED load leaves the caller's variables untouched
MP_ROOT=sentinel; PLUGIN_DIR=sentinel
load_plugin_ctx "$PD_TMP/state/plugin-update-ctx-bare" ghost >/dev/null 2>&1
assert_eq "a failed load_plugin_ctx assigns nothing (rc 2 path)" "sentinel|sentinel" "$MP_ROOT|$PLUGIN_DIR"
# TTL: non-numeric env falls back to the default instead of disabling the check; future timestamp refused
PLUGIN_CTX_TTL_SECONDS=abc load_plugin_ctx "$PD_TMP/state/plugin-update-ctx-bare" bare >/dev/null 2>&1; RC_TTL1=$?
assert_eq "non-numeric PLUGIN_CTX_TTL_SECONDS falls back to the default (fresh context still loads)" "0" "$RC_TTL1"
sed -i.bak "s/^WRITTEN_EPOCH=.*/WRITTEN_EPOCH=$(( $(date +%s) + 86400 ))/" "$PD_TMP/state/plugin-update-ctx-bare"; rm -f "$PD_TMP/state/plugin-update-ctx-bare.bak"
load_plugin_ctx "$PD_TMP/state/plugin-update-ctx-bare" bare >/dev/null 2>&1; RC_TTL2=$?
assert_eq "a context timestamped in the future is refused -> rc 2" "2" "$RC_TTL2"
# plugin_holders: nested same-name marketplaces resolving to ONE physical dir = one holder
HOLD_NP=$(plugin_holders np | grep -c .)
assert_eq "plugin_holders collapses two index rows that resolve to the same physical dir (che-local-plugins shape)" "1" "$HOLD_NP"
assert_eq "plugin_holders keeps the first index row for a collapsed holder (same first-wins as find_plugin_marketplace)" "$(find_plugin_marketplace np)" "$(plugin_holders np)"
# two genuinely distinct checkouts of one marketplace = two holders; scoping by name works
mkdir -p "$PD_TMP/twin-a/.claude-plugin" "$PD_TMP/twin-a/plugin/.claude-plugin" "$PD_TMP/twin-b/.claude-plugin" "$PD_TMP/twin-b/plugin/.claude-plugin"
for t in twin-a twin-b; do
  printf '{ "name": "pd-twin", "plugins": [ { "name": "tw", "source": "./plugin" } ] }\n' > "$PD_TMP/$t/.claude-plugin/marketplace.json"
  printf '{ "name": "tw" }\n' > "$PD_TMP/$t/plugin/.claude-plugin/plugin.json"
done
assert_eq "plugin_holders lists two distinct checkouts as two holders" "2" "$(plugin_holders tw | grep -c .)"
assert_eq "plugin_holders scoped to a marketplace name only walks that name's rows" "0" "$(plugin_holders tw pd-nest 2>/dev/null | grep -c .)"
assert_fails "plugin_holders with no holder -> rc 1" plugin_holders nobody-here
assert_fails "plugin_holders refuses an invalid plugin name" plugin_holders 'a;b'
# a marketplace whose NAME is outside the allowlist never enters the index
mkdir -p "$PD_TMP/evilname/.claude-plugin" "$PD_TMP/evilname/plugins/victim/.claude-plugin"
printf '{ "name": "ok'"'"'; touch pwned; #", "plugins": [ { "name": "victim", "source": "./plugins/victim" } ] }\n' > "$PD_TMP/evilname/.claude-plugin/marketplace.json"
printf '{ "name": "victim" }\n' > "$PD_TMP/evilname/plugins/victim/.claude-plugin/plugin.json"
assert_eq "a marketplace name outside [A-Za-z0-9._-] is dropped at the index (list_marketplaces)" "0" "$(list_marketplaces | grep -c pwned)"
assert_fails "…and find_plugin_marketplace cannot return its plugins" find_plugin_marketplace victim
# _dir_mode under a GNU-shaped stat: `stat -f %Lp` prints file-system junk to stdout and exits 1
mkdir -p "$PD_TMP/gnubin"
cat > "$PD_TMP/gnubin/stat" <<'SH'
#!/bin/sh
case "$1" in
  -f) echo "stat: cannot stat '%Lp': No such file or directory" >&2; echo "  File: \"$2\""; echo "    ID: 100000  Namelen: 255  Type: apfs"; exit 1 ;;
  -c) exec /usr/bin/stat -f %Lp "$3" ;;
esac
exit 1
SH
chmod +x "$PD_TMP/gnubin/stat"
GNU_MODE=$(PATH="$PD_TMP/gnubin:$PATH" _dir_mode "$PD_TMP/state")
assert_eq "_dir_mode under a GNU-shaped stat yields just the octal mode" "700" "$GNU_MODE"
PATH="$PD_TMP/gnubin:$PATH" write_plugin_ctx "$PD_TMP/state/plugin-update-ctx-gnu" pd-agg "$PD_TMP/agg" "$PD_TMP/agg/plugins/x" x; RC_GNU=$?
assert_eq "write_plugin_ctx succeeds when stat is GNU-shaped" "0" "$RC_GNU"

MARKETPLACE_SEARCH_ROOT="$SAVED_ROOT"
rm -rf "$PD_TMP"

echo
echo "bash 3.2 compatibility:"
# The whole point: this file must be sourceable by macOS system bash with no
# stderr noise. `local -n` would emit "invalid option" here.
NOISE=$(/bin/bash -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && resolve_marketplace_root che-plugin-devtools >/dev/null" 2>&1)
assert_eq "sourcing under /bin/bash emits no stderr" "" "$NOISE"

echo
echo "zsh compatibility (#16):"
# **這一節是這個 bug 活下來的原因的補救。** 先前整份測試只跑 bash，而這個檔案是被
# `source` 的——跑它的是呼叫端的 shell，`#!/bin/bash` 不生效。Claude Code 的 Bash
# 工具跑在 zsh，而 zsh 預設不對 unquoted 變數做 word-split，於是
# `for mp in $MARKETPLACE_NAMES` 只迭代一次（整個字串當一個項目），
# `find_plugin_marketplace` 對**每一個** plugin 都回 rc=1。
#
# 破壞實作確認過會紅：把 MARKETPLACE_NAMES 改回空白分隔 + `for mp in $VAR`，
# 下面兩條在 zsh 那邊會失敗（bash 那邊仍然全綠——那正是重點）。
if command -v zsh >/dev/null 2>&1; then
  ZSH_HIT=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && find_plugin_marketplace harness-devtools" 2>/dev/null)
  assert_eq "sourcing under zsh finds harness-devtools (three fields)" \
    "che-plugin-devtools|$HOME/Developer/che-plugin-devtools|$HOME/Developer/che-plugin-devtools/plugins/harness-devtools" \
    "$ZSH_HIT"

  ZSH_COUNT=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && list_marketplaces | wc -l" 2>/dev/null | tr -d ' ')
  BASH_COUNT=$(list_marketplaces | wc -l | tr -d ' ')
  assert_eq "list_marketplaces yields the same count under zsh and bash" \
    "$BASH_COUNT" "$ZSH_COUNT"

  ZSH_NOISE=$(zsh -c "source '$SCRIPT_DIR/resolve-marketplace.sh' && resolve_marketplace_root che-plugin-devtools >/dev/null" 2>&1)
  assert_eq "sourcing under zsh emits no stderr" "" "$ZSH_NOISE"
else
  echo "  ⊘ zsh not on PATH — skipped (這台機器不是 macOS 預設環境?)"
fi

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
