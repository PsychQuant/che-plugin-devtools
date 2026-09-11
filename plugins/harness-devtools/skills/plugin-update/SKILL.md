---
name: plugin-update
description: 更新 Plugin 到最新版本（marketplace.json 同步 + marketplace update + plugin update + 安裝檢查）。當修改了任何 plugin 原始碼後需要同步、或用戶提到「更新 plugin」、「同步 plugin」、「plugin 沒生效」、「reload plugins」時使用。
argument-hint: [plugin-name]
allowed-tools:
  - Bash(git:*)
  - Bash(claude:*)
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(python3:*)
  - Read
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

# Plugin Update — 同步與更新流程

修改 plugin 原始碼後，確保變更生效的完整流程。

## 為什麼需要這個？

Plugin 修改後有 6 個環節容易漏掉：
1. 忘了更新 `marketplace.json` 中的版本號（新 plugin 忘了加 entry）
2. 忘了 commit/push 到 git remote
3. 忘了同步 marketplace cache（`claude plugin marketplace update`）
4. 忘了 update 已安裝的 plugin（`claude plugin update`）
5. 忘了重啟 Claude Code 使快取生效
6. **忘了同步 `README.md`**（版本 bump 但 README 仍在舊版、沒提新工具 / 新 skill，使用者看文件以為功能沒做完）

此 skill 自動檢查並執行所有步驟。

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 stage-level todo list，每完成一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

```
TaskCreate(name="detect_marketplace", description="Phase 0: 找到 plugin 所屬的 marketplace repo")
TaskCreate(name="sync_intent_gate", description="Phase 0.3 (v1.17.0+): pre-flight intent check — detect binary-backed plugin; if no shell changes AND binary not bumped AND binary already at last release, abort early (no-op short-circuit)")
TaskCreate(name="git_state_gate", description="Phase 0.5 (v1.16.0+ #60): preview git status / unpushed commits / divergence + 5-case AskUserQuestion (abort default for non-clean states); idd-all unattended → auto-abort")
TaskCreate(name="detect_changes", description="Phase 1: 確認 plugin + 最近 commits（git status 已由 Phase 0.5 gate）")
TaskCreate(name="check_external_deps", description="Phase 1.5: 偵測 MCP/CLI 依賴，不同步時 AskUserQuestion")
TaskCreate(name="sync_marketplace_json", description="Phase 2: 比對 plugin.json 和 marketplace.json 版本，commit+push")
TaskCreate(name="check_readme_freshness", description="Phase 2.5: 檢查 README 是否跟上版本 / 新工具，過時時 AskUserQuestion")
TaskCreate(name="marketplace_update", description="Phase 3: claude plugin marketplace update")
TaskCreate(name="plugin_install_or_update", description="Phase 4: claude plugin install/update @marketplace")
TaskCreate(name="verify_and_report", description="Phase 5: claude plugin list 驗證 + 提醒重啟")
```

**若 Phase 1.5 使用者選「順便更新」**，補加一筆：
```
TaskCreate(name="invoke_dependency_skill", description="Phase 1.5 auto-sync: 呼叫 /harness-devtools:mcp-deploy 或 /harness-devtools:cli-upgrade")
```

**為什麼強制**：plugin-update 有 5 個常被漏掉的環節（marketplace.json 沒更新、沒 push、cache 沒 sync、plugin 沒 update、沒重啟），task list 讓每一步都有可見證據。

---

## Phase 0: 偵測 Marketplace

先確定 plugin 所在的 marketplace repo。

### 已知的 marketplace

**路徑一律由 `scripts/resolve-marketplace.sh` 解析——不要在這裡或任何 skill 裡寫死。**

新增 marketplace 時只改 `resolve-marketplace.sh` 一處；`scripts/test-resolve-marketplace.sh`
會斷言每個列出的名稱都解析得到。要看機器上有哪些 marketplace：`list_marketplaces`（或
`claude plugin marketplace list`）；要 pin 一個已知名稱：`resolve_marketplace_root <name>`——
但那只給 root，plugin 目錄仍要經 `resolve_plugin_dir`，見下方前導。

### Step 0.1: Marketplace Resolution Gate（v2.2.0+ #16）

**這道 gate 必須在 Phase 0.3 之前，因為 0.3 與 0.5 兩道 gate 都預設它已經成立。**

`find_plugin_marketplace` 找不到時 `return 1` 且**不輸出任何東西**。先前這裡直接
`IFS="|" read <<< "$(find_plugin_marketplace ...)"`，於是 `MP_NAME` / `MP_ROOT` 靜默
變成空字串，而後面每一個 phase 都建立在那兩個空字串上：

| Phase | 用法 | 空值時 |
|---|---|---|
| 0.3 | `$PLUGIN_DIR`（三元組第三欄，每個 block 重新解析）| 空 → 偵測全部落空 → `IS_BINARY_BACKED=false`，binary gate 整個失效 |
| 0.5 | `cd "$MP_ROOT"` | `cd ""` 是 no-op → **git state gate 跑在使用者當下所在的 repo 上** |
| 2 | 讀寫 `$MP_ROOT/.claude-plugin/marketplace.json` | 讀不到 |

**0.5 那條最危險**：使用者剛改完 plugin 原始碼、就在那個 repo 裡跑 `/plugin-update`
是最自然的動作，而那個 repo 通常真的有未推送的 commit——於是 gate 會 preview 錯誤
repo 的狀態並問「要 push 嗎」，而那個問句看起來完全合理。

**整段是一個 fence**：解析與 gate 在同一個 shell 裡，gate 讀得到它要檢查的變數。

```bash
# 代入前先肉眼核對只含 [A-Za-z0-9._-]（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME" in
    *[![:alnum:]._-]*|''|.|..)
        echo "✗ Phase 0.1: plugin 名稱 '$(printf '%s' "$PLUGIN_NAME" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-80)' 含非法字元。" >&2
        echo "  名稱會進路徑與 pathspec，只接受 [A-Za-z0-9._-]。這不是 marketplace 的問題。" >&2
        exit 1 ;;
esac

# 三元組（#18）：第三欄是 manifest plugins[].source 解析出的 plugin 目錄。
# **必須先檢查回傳碼再拆欄位**。
RESOLVED=$(find_plugin_marketplace "$PLUGIN_NAME") || RESOLVED=""
IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$RESOLVED"

if [ -z "$MP_ROOT" ] || [ ! -d "$MP_ROOT" ]; then
    echo "✗ Phase 0.1: plugin '$PLUGIN_NAME' 不在任何已註冊的 marketplace 裡。" >&2
    echo "  已搜尋：$(list_marketplaces | tr '\n' ' ')" >&2
    echo "" >&2
    echo "  plugin-update 只同步**已上架**的 plugin。你要的可能是：" >&2
    echo "    · plugin 檔案已存在（例如在它自己的原始碼 repo 裡）但還沒上架" >&2
    echo "      → /harness-devtools:plugin-deploy $PLUGIN_NAME" >&2
    echo "    · plugin 還不存在" >&2
    echo "      → /harness-devtools:plugin-create" >&2
    echo "" >&2
    echo "  若它是 binary-backed（MCP server / CLI），plugin-deploy 的 Step 2.5 會在" >&2
    echo "  release 沒有 binary asset 時 BLOCK，所以更前面要先在 binary 的原始碼 repo 跑：" >&2
    echo "    → /harness-devtools:mcp-deploy   （或 CLI 專案用 /harness-devtools:cli-deploy）" >&2
    echo "" >&2
    # 沒命中的幾種樣子要分開講（#18）：manifest 根本沒這個 entry（上面的建議才對）、
    # entry 在但 source 不可用（rc 2：修 manifest）、此機器沒有可用 python3（rc 3：
    # 只有 plugins/<name> 佈局能偵測）、manifest 讀不動（rc 4：修 JSON）、source 是
    # 合法但非本地的寫法（rc 5：git-subdir 物件 / URL——manifest 沒壞，plugin-update
    # 只處理本地佈局）。後四種都不是「沒上架」，上面兩個建議對它們都是錯的方向。
    # 走一次 marketplace_index（name<TAB>root，與 find_plugin_marketplace 同一份遍歷，
    # 被 shadow 的 checkout 也在），不逐名重建索引。印出的每個值都是第三方檔案內容：
    # 去控制字元、截斷。
    clean() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200; }
    while IFS="$(printf '\t')" read -r mp root; do
        [ -n "$root" ] || continue
        resolve_plugin_dir "$root" "$PLUGIN_NAME" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 1 ] && continue
        src=$(plugin_source_of "$root" "$PLUGIN_NAME" 2>/dev/null)
        mp=$(clean "$mp"); root=$(clean "$root")
        case "$rc" in
            0) echo "  ℹ '$mp' ($root) 其實解析得到——find_plugin_marketplace 沒回它，代表它在走訪時被前面的 root 遮住或 root 含分隔符；請檢查 marketplace_candidates '$mp'。" >&2 ;;
            2) echo "  ⚠ '$mp' ($root) 的 manifest 列了 '$PLUGIN_NAME'，但 source（untrusted，已截斷）= '$src'" >&2
               echo "    不是可用的相對路徑（空、非字串、絕對、..、引號、|、控制字元、目錄不存在、symlink 逃出 root、'.' 佈局缺 plugin.json）。先修該 manifest。" >&2 ;;
            3) echo "  ⚠ '$mp' ($root)：此機器沒有可用的 python3，讀不了 manifest；只有 plugins/$PLUGIN_NAME 這種佈局偵測得到，而它不存在。" >&2 ;;
            4) echo "  ⚠ '$mp' ($root) 的 marketplace.json 讀不動（權限 / JSON 解析失敗 / 形狀不對），且 plugins/$PLUGIN_NAME 未物化。" >&2
               echo "    這不是「沒上架」——先修 JSON（常見：多餘逗號）。" >&2 ;;
            5) echo "  ℹ '$mp' ($root) 列了 '$PLUGIN_NAME'，source（untrusted，已截斷）= '$src'" >&2
               echo "    是合法但非本地的寫法（git-subdir 物件 / URL），且 plugins/$PLUGIN_NAME 未物化。" >&2
               echo "    manifest 沒壞；plugin-update 只處理本地佈局。要更新它，先把 subtree 物化到 plugins/$PLUGIN_NAME。" >&2 ;;
            *) echo "  ⚠ '$mp' ($root)：resolve_plugin_dir 回了未預期的 rc $rc。" >&2 ;;
        esac
    done <<EOF
$(marketplace_index)
EOF
    exit 1
fi

if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
    # find_plugin_marketplace 命中就一定帶第三欄；走到這裡代表 resolver 契約被改了
    # （例如有人把它退回兩欄），不是 marketplace 的問題。一樣 abort——見下段。
    echo "✗ Phase 0.1: find_plugin_marketplace 回了 '$(printf '%s' "$RESOLVED" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200)'，第三欄不是目錄。" >&2
    echo "  resolve-marketplace.sh 的契約是 name|root|plugin_dir（#18）；請對它跑" >&2
    echo "  scripts/test-resolve-marketplace.sh。" >&2
    exit 1
fi

# 之後每個 block 都要代入這兩個值（見下方「前導」）：記下來。
echo "→ Step 0.1 OK: marketplace=$MP_NAME root=$MP_ROOT plugin_dir=$PLUGIN_DIR"
```

**`PLUGIN_DIR` 也 gate，理由和 `MP_ROOT` 一樣（#18）**：在 #18 之前這個 skill 有 17 處自己
把路徑組成 `$MP_ROOT/plugins/$PLUGIN_NAME`。對 `source: "./plugin"` 的單一 plugin
marketplace（che-keychain、che-apple-mail-mcp、che-ical-mcp）那個目錄不存在，而後面每一個
「檔案在不在」的偵測都把不存在讀成「沒有」——`IS_BINARY_BACKED=false`、`binary_version`
空、README 六信號全跳過——和 `MP_ROOT` 為空時一模一樣，只是這次 `MP_ROOT` 是對的。
路徑現在只有一個來源：manifest 的 `plugins[].source`，由 `resolve_plugin_dir` 解析。

**這是 abort，不是 warn。** 繼續下去的每一條路徑都是對錯的目標動手，而其中一條會
主動邀請使用者 push 一個不相干的 repo。

**每個 bash block 自己重新解析（#18）**：agent 是分次呼叫 Bash 工具執行這份 SKILL.md
的，shell 變數不跨呼叫存活。Step 0.1 設好的 `MP_ROOT` / `PLUGIN_DIR` 到 Phase 0.3 那個
shell 已經不存在——空的 `$PLUGIN_DIR/.mcp.json` 測的是 `/.mcp.json`，答案是「沒有」，而
「沒有」正是本 issue 要消滅的那種靜默失敗。所以之後**每一個**用到 `$MP_ROOT` /
`$PLUGIN_DIR` 的 block 都以同一段前導開頭。前導把 Step 0.1 印出的 `MP_NAME` 也代入並
用 `resolve_marketplace_root` pin 住（不再重走 `find_plugin_marketplace`）：同名多
checkout 時，Step 0.1 決定的那份才是後面 `git push` 的那份。這不是「重組路徑」：路徑仍然
只從 manifest 來，只是每個 shell 各拿一次。**表格儲存格與散文裡的 `<PLUGIN_DIR>` 是敘述，
不是可執行的指令；可執行的形式只在帶前導的 fence 裡。**

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
```

> **為什麼 Phase 2 Step 3「新 Plugin 需加入 entry」不涵蓋這個情形**：那一步處理的是
> 「plugin 檔案**已經在** marketplace repo 的 `plugins/` 底下，但 `marketplace.json`
> 還沒有它的 entry」。首次上架缺的是**把 plugin 放進 marketplace repo** 這一步，而
> 那是 `plugin-deploy` 的工作。兩者字面上都像「新 plugin」，但缺的東西不同。

---

## Phase 0.3: Sync Intent Gate（v1.17.0+, no-op short-circuit）

> **為什麼這 phase 在 Phase 0.5 之前**：Phase 0.5 鎖的是 git state 的「敢不敢 push」決定。**0.3 鎖的是更上游的問題：你跑 plugin-update 到底是想 sync 什麼？** 如果這個問題的答案是「沒有」，跑下去純粹是 no-op + 浪費 user 時間 + 風險誤 push 別人的 unrelated commits（在 marketplace monorepo 場景特別容易發生）。
>
> **歷史脈絡**：早期 plugin-update 預設「跑了就是有東西要 sync」，binary-backed plugin 沒改 shell + binary 沒新 release 時走完整個 flow 卻什麼都沒同步是常見坑。今天 (v1.17.0 #66) 的 root cause 是 user 從 binary repo 跑 plugin-update 但 binary 沒 release、shell 沒改 — 純運氣靠 Phase 0.5 抓到 unrelated unpushed commits 才 abort。0.3 把這個運氣升格成顯式 gate。
>
> **Relationship to Phase 0.5**：0.3 處理「該不該動」，0.5 處理「怎麼安全 push」。0.3 abort → 不進 0.5；0.3 pass → 0.5 接手。

### Step 1: 偵測 binary-backed plugin

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }

# Signal: .mcp.json 或 bin/*-wrapper.sh with GITHUB_REPO → MCP binary plugin
IS_BINARY_BACKED=false
if [ -f "$PLUGIN_DIR/.mcp.json" ]; then
    IS_BINARY_BACKED=true
elif ls "$PLUGIN_DIR/bin/"*-wrapper.sh 2>/dev/null | xargs grep -l GITHUB_REPO 2>/dev/null | head -1 > /dev/null; then
    IS_BINARY_BACKED=true
fi

# Signal: hooks/session-start.sh curls GitHub API → CLI-binary plugin
if grep -q 'api.github.com.*releases' "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null; then
    IS_BINARY_BACKED=true
fi
```

**非 binary-backed plugin（純 skill / rule / agent）**：跳過 Phase 0.3，直接走 Phase 0.5。Pure-shell plugin 沒有「binary version drift」這層問題，sync intent 比較單純（要嘛 shell 改了要 push，要嘛沒改 → Phase 0.5 自然 abort）。

### Step 2: 收集 sync 候選變更（binary-backed only）

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }

# 路徑一律走 sys.argv，不內嵌進 python 原始碼：$PLUGIN_DIR 來自 manifest（第三方檔案），
# 內嵌成 open('$PLUGIN_DIR/...') 時路徑裡一個 ' 就是任意程式碼執行（#18 R1 security）。
# (a) 從 plugin.json 取 binary_version + shell version
SHELL_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_DIR/.claude-plugin/plugin.json")
BINARY_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("binary_version", ""))' "$PLUGIN_DIR/.claude-plugin/plugin.json")

# (b) 比對 marketplace.json — 落後嗎？
MP_VERSION=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["plugins"]:
    if p["name"] == sys.argv[2]:
        print(p.get("version", ""))
        break
' "$MP_ROOT/.claude-plugin/marketplace.json" "$PLUGIN_NAME")
MP_DRIFT=$([ "$MP_VERSION" != "$SHELL_VERSION" ] && echo yes || echo no)

# (c) Shell 檔案最近 N 個 commits 是否觸到此 plugin？
# pathspec 用絕對 $PLUGIN_DIR（git 接受 worktree 內的絕對路徑；同檔 Phase 2.5 亦然），並帶
# --literal-pathspecs（目錄名含 * ? [ 時不得當 glob）。不要相對化：${PLUGIN_DIR#$MP_ROOT/} 把
# MP_ROOT 當 glob、對 repo 即 plugin 的佈局會變空字串。root-sourced plugin（source "."）的
# pathspec 是整個 repo：對它這個信號等於「repo 30 天內有沒有 commit」，是佈局語意，不是誤報。
cd "$MP_ROOT"
SHELL_RECENT_TOUCHES=$(git --literal-pathspecs log --since="30 days ago" --name-only --pretty=format: \
    -- "$PLUGIN_DIR/" 2>/dev/null \
    | grep -v '^$' | sort -u | head -10)

# (d) BINARY repo: main 是否有 unreleased commits（信號移植自 #66 Phase 1.5 強化）
# 這裡只做 detection；warn 文案在 Step 4 統一輸出
if [ -n "$BINARY_VERSION" ]; then
    BINARY_REPO_PATH=$(detect_binary_repo "$PLUGIN_DIR")  # 由 Phase 1.5 detection 邏輯共用
    if [ -d "$BINARY_REPO_PATH" ]; then
        BINARY_UNRELEASED=$(git -C "$BINARY_REPO_PATH" log "v$BINARY_VERSION..main" --oneline 2>/dev/null | wc -l | tr -d ' ')
    fi
fi
```

> **`detect_binary_repo` heuristic**：從 wrapper script 抓 `GITHUB_REPO`（e.g. `PsychQuant/che-apple-mail-mcp`），然後在常見路徑下找 local clone：`$HOME/Developer/<repo>` / `$HOME/Developer/che-mcps/<repo>` / `$HOME/code/<repo>`。找不到就跳過 binary-repo-drift 信號（不 fail-stop — 信號是 best-effort）。

### Step 3: Sync intent 判斷

把 Step 2 收集到的信號濃縮成「真的有東西要 sync 嗎？」的 boolean：

| 信號命中 | sync intent | 解讀 |
|---------|------------|------|
| marketplace.json 版本落後 plugin.json (`MP_DRIFT=yes`) | YES | shell 已 bump 但 marketplace 沒同步 — 經典 plugin-update use case |
| 30 天內有 plugin 檔案 commits（`SHELL_RECENT_TOUCHES` 非空）| YES | shell 真的有改動 |
| Binary repo `main` 超前 last release ≥ 1 commits | MAYBE | 提示「binary 有 unreleased commits — 是不是該先 mcp-deploy / release？」|
| 全部都沒命中 | **NO** | nothing to sync — short-circuit abort |

### Step 4: AskUserQuestion 4-case dispatch

#### Case A: Nothing to sync → abort

當 (a) `MP_DRIFT=no` AND (b) `SHELL_RECENT_TOUCHES` 為空 AND (c) `BINARY_UNRELEASED=0`：

```bash
echo "✗ Phase 0.3: Nothing to sync."
echo "  - marketplace.json @ $MP_VERSION matches plugin.json @ $SHELL_VERSION"
echo "  - no plugin file changes in last 30 days"
echo "  - binary v$BINARY_VERSION matches latest release"
echo ""
echo "  If you intended to force a marketplace cache refresh anyway,"
echo "  bypass plugin-update and run: claude plugin marketplace update {marketplace_name}"
exit 0
```

#### Case B: Binary unreleased commits 是唯一信號 → AskUserQuestion

當 (a) `MP_DRIFT=no` AND (b) `SHELL_RECENT_TOUCHES` 為空 AND (c) `BINARY_UNRELEASED >= 1`：

```
question: "Binary repo `main` 累積 $BINARY_UNRELEASED 個未 release 的 commits (last release: v$BINARY_VERSION)。Shell 沒改、marketplace.json 已同步。怎麼處理？"
options:
  - "abort, release binary first (default, recommended)"
    description: "exit; cd <binary-repo>; ./scripts/release.sh v<next>; 完成後 bump plugin.json binary_version + 重跑 plugin-update"
  - "proceed anyway (force shell sync only)"
    description: "略過 binary release 提醒，繼續走 Phase 0.5+ 同步 shell（binary 仍是舊版）— 只適合純 documentation / shell-side bug fix 的情境"
  - "abort"
    description: "exit; 不動 anything"
```

選 `abort, release binary first` / `abort` → exit 0。
選 `proceed anyway` → 繼續 Phase 0.5。

#### Case C: Sync intent confirmed → 通過 0.3，直接進 0.5

當 `MP_DRIFT=yes` OR `SHELL_RECENT_TOUCHES` 非空：正常 sync use case，print 簡短摘要後進入 Phase 0.5。

```bash
echo "→ Phase 0.3: sync intent confirmed"
[ "$MP_DRIFT" = "yes" ] && echo "  - marketplace.json drift: $MP_VERSION → $SHELL_VERSION"
[ -n "$SHELL_RECENT_TOUCHES" ] && echo "  - recent shell changes: $(echo "$SHELL_RECENT_TOUCHES" | wc -l) files"
[ "$BINARY_UNRELEASED" -gt 0 ] 2>/dev/null && echo "  - binary main has $BINARY_UNRELEASED unreleased commits (see Phase 1.5 for warn detail)"
```

#### Case D: idd-all unattended → auto-decide

當 plugin-update 在 `idd-all` orchestrator 下 invoke：
- Nothing to sync (Case A) → 同樣 abort（idd-all 在最終 report 標 "plugin-update skipped: no sync intent"）
- Binary unreleased only (Case B) → auto-abort（unattended 不該 force shell sync）+ structured error
- Sync intent confirmed (Case C) → 繼續 Phase 0.5（0.5 自己有 unattended handler）

設計同 Phase 0.5 Step 4：user-attendance-required gates 在 unattended mode 統一走 abort + audit trail。

---

## Phase 0.5: Git State Preview & Confirmation Gate（v1.16.0+ #60）

> **為什麼這 phase 在 Phase 1 之前**:Phase 1+ 會 `git add` / `git commit` / `git push` / `claude plugin marketplace update`,**任何 state-mutating 操作開始前**,user 必須明確表態現在的 git state 是不是該 push 的。
>
> 既有 (pre-v1.16.0) 行為:Phase 1 Step 2 印出 `git status` 後接 narrative reminder text 「請先 commit + push」,但**沒實際 gate**,AI executor 可以印 reminder 後繼續。新 phase 把這個決定升格成 **AskUserQuestion** explicit dispatch,跟 skill 內既有 [Phase 1.5: External Binary Dependency Check](#phase-15-external-binary-dependency-check若有) + [Phase 2.5: README Freshness Check](#phase-25-readme-freshness-check) 同 pattern(用 section refs 而非 line numbers,避免後續 insert 後 stale)。
>
> **Relationship to IDD `pr_policy`**:`pr_policy` 控制 development-time PR-vs-direct-commit 決定(during `idd-implement`)。Phase 0.5 控制 release-time push-or-abort 決定(during `plugin-update`)。**Different lifecycle moments;Phase 0.5 不 consult / 不 override `pr_policy`**。

### Step 1: Read-only Preview Block

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cd "$MP_ROOT"

# Resolve upstream once + abort on missing/unusual configs (v1.16.0 fix #60-verify P1)
# - No upstream tracking → abort with structured error (don't silently proxy to origin/main)
# - Detached HEAD → abort
# - Incomplete rebase/merge → abort
if [ ! -e "$(git rev-parse --git-dir)/HEAD" ] || ! git symbolic-ref -q HEAD >/dev/null; then
    echo "✗ Detached HEAD or invalid HEAD; checkout a branch first." >&2
    exit 1
fi
GITDIR=$(git rev-parse --git-dir)
if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ] || [ -e "$GITDIR/MERGE_HEAD" ] || [ -e "$GITDIR/CHERRY_PICK_HEAD" ]; then
    echo "✗ Repo in incomplete rebase/merge/cherry-pick state; resolve before plugin-update." >&2
    exit 1
fi
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
    echo "✗ No upstream tracking branch. Set with 'git branch --set-upstream-to=origin/<branch>' first." >&2
    exit 1
}
# UPSTREAM is now the canonical source for all comparisons (e.g. origin/main, upstream/feat-xyz)

echo "=== Git State Preview ==="
echo ""
echo "--- branch ---"
git branch --show-current
echo "(upstream: $UPSTREAM)"
echo ""
echo "--- working tree ---"
git status --short
echo "(empty = clean)"
echo ""
echo "--- unpushed commits (\"$UPSTREAM\"..HEAD) ---"
git log --oneline "$UPSTREAM"..HEAD
echo "(empty = none)"
echo ""
echo "--- divergence count (upstream <-> HEAD) ---"
git rev-list --left-right --count "$UPSTREAM"...HEAD
echo "(left = origin behind us; right = we ahead of origin; '0 0' = synced; '0 N' = ahead; 'M 0' = pure-behind; 'M N' = diverged)"
```

**Read-only by contract**:本 step **只 print + read**,不 mutate。Phase 1+ 才允許 `git add` / `git commit` / `git push`。

> **Why resolve `UPSTREAM` upfront**(v1.16.0 fix #60-verify P1):earlier draft used `origin/$(... | sed 's|^origin/||' || echo main)` chain which silently fell back to `origin/main` on no-upstream / fork remote workflow,defeating the L128 spec contract. New version aborts cleanly + uses single `$UPSTREAM` variable consistently.

### Step 2: State Detection (priority-ordered, v1.16.0 fix #60-verify P1)

從 preview output 判斷以下 case。**Detection 是 priority-ordered,先測 divergence,再測 dirty/clean × unpushed**:

| Priority | State | Detection signal |
|----------|-------|------------------|
| 1 (highest) | **Origin diverged** (Case E) | divergence `M N` with **M ≥ 1 AND N ≥ 1** — branches diverged, not just one-sided |
| 2 | **Pure behind** (Case E') | divergence `M 0` with **M ≥ 1 AND N = 0** — fast-forward case, short-circuit to fetch + ff merge (no need to AskUserQuestion;just `git pull --ff-only` then re-evaluate) |
| 3 | **Dirty + N unpushed** (Case D) | divergence `0 N` AND `git status --short` non-empty |
| 4 | **Dirty + 0 unpushed** (Case C) | divergence `0 0` AND `git status --short` non-empty |
| 5 | **Clean + N unpushed** (Case B) | divergence `0 N` AND `git status --short` empty |
| 6 (lowest) | **Clean + 0 unpushed** (Case A) | divergence `0 0` AND `git status --short` empty |

> **Why divergence wins** (priority 1-2 first):dirty + diverged 同時成立時,先處理 divergence(無法 push 在落後的 branch);user 可以 fetch + rebase 後再決定 dirty 怎麼處理。原 draft 把 dirty 跟 diverged 並列導致雙重匹配,新版用 priority order 消除歧義。
>
> **Pure-behind (Case E') 是新增 case** — origin 比 local 多 commits 但 local 無 unpushed,這是 `git pull --ff-only` 的乾淨情境;原 draft 漏列。

**Edge cases all → abort with structured error**(由 Step 1 preview block 的開頭 guard 處理):
- Detached HEAD → already aborted in Step 1
- No upstream tracking → already aborted in Step 1
- Incomplete rebase / merge / cherry-pick → already aborted in Step 1

### Step 3: AskUserQuestion 5-case Dispatch

依 detected state 跑對應的 AskUserQuestion。**Default option = `abort` for any state with multiple sensible actions**;`push as-is` 只在 unambiguous clean+unpushed case 是 default。

#### Case A: Clean + 0 unpushed

不需要 dispatch,直接 abort:

```bash
echo "✗ Nothing to push — working tree is clean and 0 unpushed commits."
echo "  If you intended to update the marketplace anyway (e.g. just trigger 'claude plugin marketplace update' on origin),"
echo "  bypass plugin-update and run that command directly."
exit 0
```

#### Case B: Clean + N unpushed → AskUserQuestion

```
question: "$N unpushed commits on $BRANCH. Push them to origin and proceed with marketplace sync?"
options:
  - label: "push N as-is (default)"
    description: "git push origin $BRANCH → continue to Phase 1+"
  - label: "interactive rebase first"
    description: "abort plugin-update; run 'git rebase -i origin/$BRANCH' manually then re-run plugin-update"
  - label: "abort"
    description: "exit; nothing changed"
```

選 `push N as-is` → Phase 1+ continue。
選其他 → exit 0。

#### Case C: Dirty + 0 unpushed → AskUserQuestion

```
question: "Working tree has uncommitted changes, 0 unpushed commits. What to do?"
options:
  - label: "abort (default)"
    description: "exit; manually 'git add ...' + 'git commit -m ...' the changes you want to push, then re-run plugin-update"
  - label: "stage all + commit + push"
    description: "git add -A then prompt for commit message → commit → push → continue"
  - label: "manually stage subset + commit + push"
    description: "abort; run 'git add' interactively, then re-run plugin-update"
```

預設 `abort` — skill 不擅自決定要 commit 什麼。

#### Case D: Dirty + N unpushed → AskUserQuestion

```
question: "$N unpushed commits AND working tree has uncommitted changes. What to do?"
options:
  - label: "abort (default)"
    description: "ambiguous state; exit and let user choose: amend dirty into HEAD? new commit? push without dirty? Re-run after deciding."
  - label: "push N existing commits, leave dirty for later"
    description: "git push origin $BRANCH → continue (dirty stays uncommitted)"
  - label: "amend dirty into HEAD then push"
    description: "git add -A then git commit --amend --no-edit (dirty staged + merged into HEAD) → push → continue"
  - label: "commit dirty as new commit then push N+1"
    description: "stage all + prompt for commit message → push → continue"
```

預設 `abort` — 4 種 sensible 動作對應不同意圖,user 必須明確選。

#### Case E: Origin diverged → AskUserQuestion

```
question: "Origin is ahead by M commits AND HEAD has N unpushed (diverged). Resolve manually."
options:
  - label: "abort (default)"
    description: "exit; run 'git fetch + git rebase origin/$BRANCH' or 'git merge origin/$BRANCH' then re-run plugin-update"
  - label: "fetch + rebase + push"
    description: "git fetch + git rebase origin/$BRANCH (linear history) → push → continue (may have conflicts)"
  - label: "fetch + merge + push"
    description: "git fetch + git merge origin/$BRANCH (preserve both branches' history) → push → continue (may have conflicts)"
```

預設 `abort` — conflict resolution 是 user 的工作,不是 skill 的。

### Step 4: idd-all Unattended Mode Handler

當 plugin-update 在 `idd-all` orchestrator 下被 invoke(env var or args detect,e.g. `IDD_ALL_UNATTENDED=1`):

1. 仍跑 Step 1 preview block(printed for audit)
2. **Auto-abort** with structured error:
   ```
   ✗ plugin-update Phase 0.5 cannot prompt under unattended mode.
     Detected state: $STATE.
     User must run /plugin-update <name> manually after IDD chain completes.
   ```
3. Return exit code non-zero(e.g. 75 = "abort by gate")so `idd-all` 在 final report 標 "plugin-update skipped under unattended mode"

設計同 `idd-diagnose` Step 3.4 F unattended-mode pattern:auto-default to safe path + audit trail entry。**Plan tier 的 EnterPlanMode + plugin-update 的 Phase 0.5 都是 user-attendance-required gates**,unattended mode 統一走 abort + audit。

### Step 5: Cross-plugin Commits Warning（v1.16.0 Tier A:warn-only)

當 Step 3 選擇 `push N as-is` / `push N+1`,檢查 unpushed commits 有沒有 touch 預期外的 plugin / 完全沒 touch target plugin。target 就是本次引數 `PLUGIN_NAME`（前導代入）；沒帶名稱的 invocation 先走 Phase 1 Step 1 的推斷、拿到名稱後再回來跑本 step。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cd "$MP_ROOT"
TARGET_PLUGIN="$PLUGIN_NAME"
# UPSTREAM 是 Step 1 那個 shell 的變數，這裡重算；空的 "$UPSTREAM"..HEAD 是 git 合法的空集合
# （rc 0、零輸出），會讓這道 gate 安靜地死掉（#18 R2）。
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
  || { echo "✗ no upstream tracking branch — Step 1 should have aborted" >&2; exit 1; }

# 收集 unpushed commits touch 到的 plugin 名(去重)——經 manifest 對映，不猜 plugins/<x>/ 佈局
# （單一 plugin marketplace 的檔案在 plugin/ 底下；repo 即 plugin 的佈局擁有全部路徑，
# 所以 root-sourced plugin 對任何 commit 都算被 touch——那是佈局語意，case (a) 對它不成立。#18）
TOUCHED=$(git log --name-only --pretty=format: "$UPSTREAM"..HEAD \
  | plugin_names_for_paths "$MP_ROOT")
TOUCHED_COUNT=$(echo -n "$TOUCHED" | grep -c . || true)

# Three cases:
#   (a) TOUCHED_COUNT = 0 — 無 plugin 被 touch (commits 只改 root files / 沒碰任何 manifest 宣告的 plugin 目錄) — 危險!
#   (b) TOUCHED_COUNT = 1 AND 該 plugin = $TARGET_PLUGIN — happy path,silent
#   (c) TOUCHED_COUNT ≥ 1 但 (a) (b) 都不成立 — 跨 plugin 或不對 target,warn

if [ "$TOUCHED_COUNT" = "0" ]; then
    # Empty-set case (v1.16.0 fix #60-verify P2 #5): commits 沒碰任何 plugin
    echo "⚠ Heads-up: unpushed commits touch NO plugin declared in marketplace.json."
    echo "   Commits in question:"
    git log --oneline "$UPSTREAM"..HEAD | sed 's/^/     /'
    echo "   Pushing will publish marketplace.json / docs / root-only changes."
    echo "   If you intended to update '$TARGET_PLUGIN' specifically, abort and re-check commits."
elif [ "$TOUCHED_COUNT" = "1" ] && [ "$TOUCHED" = "$TARGET_PLUGIN" ]; then
    : # Happy path — single-plugin commit matching target. No warning.
else
    # Cross-plugin or wrong target
    echo "⚠ Heads-up: unpushed commits touch plugin(s) other than (or in addition to) target '$TARGET_PLUGIN':"
    echo "$TOUCHED" | sed 's/^/   - /'
    echo "   Pushing will publish all of them via marketplace update."
    echo "   (warn-only; active scope guard 留給 follow-up issue #65 處理)"
fi
```

**Tier A scope = warn-only(3 cases:empty / happy / cross-plugin)**;**Tier C scope guard(active 拒絕 push,refuse + suggest interactive rebase)留給 follow-up issue #65 處理**。

### Step 6: Pass to Phase 1

通過 Phase 0.5 gate(user 選 push,或 idd-all unattended fail-fast 已 abort)後,進 Phase 1 with 已驗證的 git state。

---

## Phase 1: 偵測變更

### Step 1: 確定 Plugin

如果用戶指定了 plugin 名稱，直接使用。否則從 git 推斷：

```bash
# 這一步還沒有 plugin 名（要推斷的就是它），所以不用前導：對機器上每個 marketplace root 各看一次。
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
while IFS="$(printf '\t')" read -r mp root; do
    [ -n "$root" ] || continue
    hits=$(git --literal-pathspecs -C "$root" diff --name-only HEAD~3 2>/dev/null | plugin_names_for_paths "$root")
    [ -n "$hits" ] && printf '%s\n' "$hits" | awk -v m="$mp" '{ print m ": " $0 }'
done <<EOF
$(marketplace_index)
EOF
```

列出最近變更的 plugin（經 manifest 對映，`./plugin`、entry-less `plugins/<name>` 與 repo-即-plugin 佈局都算得到），請用戶確認要更新哪些；確認後以該名稱與其 marketplace 名跑 Step 0.1。

### Step 2: 檢查 Git 狀態

> **Skipped(v1.16.0+ #60)**:Git state preview + commit/push decision 已在 [**Phase 0.5: Git State Preview & Confirmation Gate**](#phase-05-git-state-preview--confirmation-gate-v1160-60) 處理。
>
> 走到 Phase 1 等於 Phase 0.5 已 gate 過 + user 明確選擇了 push(或 abort 的話根本不會走到這裡)。
>
> Pre-v1.16.0 此 step 印 `git status` 後接 narrative reminder 「請先 commit + push」,**沒實際 gate**;新版升格成 Phase 0.5 explicit AskUserQuestion 5-case dispatch。歷史脈絡見 #60。

---

## Phase 1.5: External Binary Dependency Check（若有）

Plugin 如果依賴外部 binary（MCP server、CLI 工具），plugin-update 只會同步 shell
（wrapper / skill / command），**不會** 自動更新 binary。這個 phase 偵測並提示。

### Step 1: 偵測依賴類型

| 訊號 | 類型 | 判斷方式 |
|------|------|---------|
| `.mcp.json` 存在 | **MCP binary** | `<PLUGIN_DIR>/.mcp.json` 存在 |
| `bin/*-wrapper.sh` 有 `GITHUB_REPO` | **MCP binary** | `<PLUGIN_DIR>/bin/*.sh` 內 grep 到 `GITHUB_REPO` |
| `hooks/session-start.sh` curl GitHub API | **CLI tool** | `<PLUGIN_DIR>/hooks/` 內 grep 到 `api.github.com.*releases` |
| Skill / hook 引用 `~/bin/$BINARY` | **CLI tool** | `<PLUGIN_DIR>/{skills,hooks}/` 內 grep 到 `$HOME/bin/` 或 `~/bin/` |

（`<PLUGIN_DIR>` 是敘述；可執行的判斷在 Phase 0.3 Step 1 帶前導的 fence。）

### Step 2: MCP 情境 — 兩個信號（asset present + repo drift）

兩個獨立信號：

1. **Latest release 有沒有對應 asset** — 救「release 漏上傳 binary」這類 #13-style 失誤
2. **Binary repo main 是否超前 last release**（v1.17.0+ 新增信號）— 救「main 累積大量 [Unreleased] 改動但沒 cut release」這類盲點

兩個信號獨立、各自 warn。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
for wrapper in "$PLUGIN_DIR"/bin/*-wrapper.sh; do
    [ -f "$wrapper" ] || continue
    BINARY_NAME=$(grep '^BINARY_NAME=' "$wrapper" | head -1 | cut -d'"' -f2)
    GITHUB_REPO=$(grep '^GITHUB_REPO=' "$wrapper" | head -1 | cut -d'"' -f2)
    # **抽不到就報出來，不是靜默 continue**（#17）。實測 12 個 wrapper 只有 3 個
    # 抽得到，也就是這個信號對四分之三的 plugin 從沒跑過。這裡是 warn 不是
    # BLOCK（plugin-update 的定位是協助），但**沉默與「檢查過沒問題」不可區分**。
    if [ -z "$BINARY_NAME" ]; then
        echo "❓ $wrapper 判定不出 BINARY_NAME — Signal 1 對它沒驗證任何東西"
        continue
    fi

    # === Signal 1: asset present in latest release? ===
    HAS_BINARY=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
        | grep '"browser_download_url"' | grep -c "/$BINARY_NAME\"" || true)

    if [ "$HAS_BINARY" = "0" ]; then
        echo "⚠️  $BINARY_NAME not in $GITHUB_REPO latest release"
        echo "   Plugin will install but wrapper auto-download will fail."
        echo "   → cd <MCP-source-repo> && /harness-devtools:mcp-deploy"
    fi

    # === Signal 2: binary repo main has unreleased commits? (v1.17.0+) ===
    # plugin.json declares binary_version (#77 schema, post-staleness-detection);
    # compare with binary repo's main HEAD to surface accumulated [Unreleased] backlog.
    BINARY_VERSION=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("binary_version") or d.get("version"))
' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null)

    # detect_binary_repo: try common local-clone paths derived from GITHUB_REPO
    REPO_BASENAME=$(basename "$GITHUB_REPO")
    BINARY_REPO_PATH=""
    for candidate in \
        "$HOME/Developer/$REPO_BASENAME" \
        "$HOME/Developer/che-mcps/$REPO_BASENAME" \
        "$HOME/code/$REPO_BASENAME"; do
        if [ -d "$candidate/.git" ]; then
            BINARY_REPO_PATH="$candidate"
            break
        fi
    done

    if [ -n "$BINARY_REPO_PATH" ] && [ -n "$BINARY_VERSION" ]; then
        # Verify the tag exists locally (might need `git fetch --tags` first if stale)
        if git -C "$BINARY_REPO_PATH" rev-parse "refs/tags/v$BINARY_VERSION" >/dev/null 2>&1; then
            UNRELEASED=$(git -C "$BINARY_REPO_PATH" log "v$BINARY_VERSION..main" --oneline 2>/dev/null | wc -l | tr -d ' ')
            if [ "$UNRELEASED" -gt 0 ] 2>/dev/null; then
                echo "⚠️  $REPO_BASENAME main has $UNRELEASED unreleased commits since v$BINARY_VERSION"
                echo "   plugin.json pins binary_version=$BINARY_VERSION; wrapper auto-download will fetch that."
                echo "   Recent unreleased commits:"
                git -C "$BINARY_REPO_PATH" log "v$BINARY_VERSION..main" --oneline 2>/dev/null | head -5 | sed 's/^/      /'
                echo "   → cd $BINARY_REPO_PATH && ./scripts/release.sh v<next>"
                echo "     then bump $PLUGIN_DIR/.claude-plugin/plugin.json binary_version + re-run plugin-update"
            fi
        else
            # Local tag missing — could mean: never fetched, or release made on remote-only.
            # Best-effort: skip rather than misreport.
            echo "ℹ️  $REPO_BASENAME local repo found but tag v$BINARY_VERSION missing — run 'git fetch --tags' to enable Signal 2"
        fi
    fi
done
```

**何時 Signal 2 沉默**：
- Plugin.json 無 `binary_version` 欄位且 `version` 不是 v-semver
- 本機沒有 binary repo 的 clone（試過 `~/Developer/` / `~/Developer/che-mcps/` / `~/code/` 三個 fallback）
- Local clone 沒有對應的 `v$BINARY_VERSION` tag（建議使用者跑 `git fetch --tags`）

設計理由：Signal 2 是 best-effort warn — 對能取得的資訊提示，缺資料時 silent skip。**不 abort plugin-update**（這是 Phase 0.3 的工作）；Phase 1.5 維持「prompt then sync」的協助型行為。

### Step 3: CLI 情境 — 比對本機 binary 和 latest release 版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
# 從 session-start.sh 抓 GitHub repo
GFH_REPO=$(grep -oE '[A-Za-z0-9_-]+/[A-Za-z0-9_-]+' "$PLUGIN_DIR"/hooks/session-start.sh | head -1)
BINARY_NAME=$(basename $(grep -oE '\$HOME/bin/[A-Za-z0-9_-]+' "$PLUGIN_DIR"/hooks/session-start.sh | head -1))

LOCAL_VERSION=$("$HOME/bin/$BINARY_NAME" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
LATEST_VERSION=$(curl -sL "https://api.github.com/repos/$GFH_REPO/releases/latest" \
    | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

if [ "$LOCAL_VERSION" != "$LATEST_VERSION" ]; then
    echo "⚠️  $BINARY_NAME local v$LOCAL_VERSION, latest v$LATEST_VERSION"
    echo "   → /harness-devtools:cli-upgrade $BINARY_NAME"
fi
```

### Step 4: 行為決策 — AskUserQuestion 主動同步

偵測到依賴且不同步時，**主動問使用者要不要一起更新**，不只是 warn。
plugin-update 是日常同步操作——連帶更新底層 binary 通常是想要的行為。

**AskUserQuestion 格式**：

```
question: "此 plugin 依賴 $BINARY（$BINARY_TYPE），目前本機/release 不同步。要順便更新 binary 嗎？"
options:
  - "順便更新" — 自動觸發底層 skill（MCP → mcp-deploy / CLI → cli-upgrade）
  - "只更新 plugin shell" — 略過 binary，只跑 marketplace.json sync + reload
  - "中止" — 停止 plugin-update，讓我手動處理
```

**若使用者選「順便更新」**：

| 依賴類型 | 自動觸發 | 時機 |
|---------|---------|------|
| MCP binary | `/harness-devtools:mcp-deploy` | 在此 phase 內執行，完成後才繼續 Phase 2 |
| CLI tool | `/harness-devtools:cli-upgrade $BINARY` | 同上 |

**狀況表**：

| 狀況 | 動作 |
|------|------|
| 無依賴（純 skill / rule plugin） | 跳過此 phase |
| 有依賴且已同步 | 顯示 ✅，繼續 Phase 2 |
| 有依賴但不同步 | **AskUserQuestion**：要順便更新 binary 嗎？ |

**為什麼 plugin-update 是 prompt-then-sync 而 plugin-deploy 是 block**：

| Skill | 觸發頻率 | 行為 | 理由 |
|-------|---------|------|------|
| `plugin-deploy` Step 2.5 | 偶爾（發版時）| **BLOCK** | Release 沒 binary = 新使用者裝 plugin 就壞，不能放過 |
| `plugin-update` Phase 1.5 | 頻繁（日常同步）| **ASK + AUTO-SYNC** | 開發者通常想要一次更新完，但要尊重「只改 shell 不動 binary」的情境 |

### Step 5: 執行 auto-sync（若使用者選擇）

**MCP 情境**：

```bash
# 找到 MCP source repo（通常在 ~/Developer/ 下）
MCP_SOURCE=$(find ~/Developer -maxdepth 3 -name "Package.swift" -exec grep -l "$BINARY_NAME" {} \; | head -1 | xargs dirname 2>/dev/null)

if [ -n "$MCP_SOURCE" ]; then
    cd "$MCP_SOURCE"
    # 呼叫 mcp-deploy skill（建議用 Skill tool，不是 shell）
    echo "Invoking /harness-devtools:mcp-deploy in $MCP_SOURCE..."
    # Skill invocation: Skill(skill="mcp-tools:mcp-deploy")
else
    echo "MCP source repo not found. Please run /harness-devtools:mcp-deploy manually from the MCP repo."
fi
```

**CLI 情境**：

```bash
# cli-upgrade 已知如何找 repo（從 ~/bin/$BINARY 偵測）
# Skill invocation: Skill(skill="cli-tools:cli-upgrade", args="$BINARY_NAME")
```

完成後回到 Phase 2 繼續 marketplace.json sync。

---

## Phase 2: 更新 marketplace.json（關鍵！）

`marketplace.json` 位於 `$MP_ROOT/.claude-plugin/marketplace.json`，是 marketplace 的 plugin index。
**如果這個檔案沒更新，`claude plugin marketplace update` 不會看到新版本。**

### Step 1: 列出 marketplace 中所有 plugin 版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cd "$MP_ROOT"
cat .claude-plugin/marketplace.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data['plugins']:
    print(f\"  {p['name']}: {p['version']}\")
"
```

### Step 2: 對比 plugin.json 的實際版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cat "$PLUGIN_DIR"/.claude-plugin/plugin.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"plugin.json: {d['version']}\")
"
```

如果 marketplace.json 的版本落後 plugin.json，用 Edit 工具更新 marketplace.json。

### Step 3: 新 Plugin 需加入 entry

如果是全新的 plugin（不在 marketplace.json 中），需要在 `plugins` 陣列加入新 entry：

```json
{
  "name": "{plugin_name}",
  "version": "1.0.0",
  "description": "{description}",
  "author": { "name": "Che Cheng" },
  "source": "./plugins/{plugin_name}",
  "category": "{category}"
}
```

`source` 寫 plugin 目錄相對於 marketplace root 的路徑。上面是 aggregator 佈局
（`plugins/` 底下一個目錄一個 plugin）；單一 plugin 的 marketplace——repo 本身就是
plugin，manifest 只有一個 entry——慣例是 `"source": "./plugin"`。**之後所有 phase 都從
這個欄位解析路徑**（`resolve_plugin_dir`，#18），所以它寫錯，Step 0.1 會 abort 並指名
這個 entry，不會靜默當成「沒有」。

category 常用值：`development`、`productivity`、`creative`

### Step 4: Commit + Push marketplace.json

marketplace.json 的變更也需要 commit + push，才能被 `marketplace update` 抓到。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cd "$MP_ROOT"
git add .claude-plugin/marketplace.json
git commit -m "chore: update marketplace.json for {plugin_name} v{version}"
git push
```

---

## Phase 2.5: README Freshness Check

版本 bump 後，`README.md` 常常被遺忘。這個 phase 在 marketplace sync 之前做最後一道檢查：**使用者看到的文件有沒有跟上程式碼**。

### 為什麼要做這步

`plugin.json` / `marketplace.json` 的版本升了，但 README 還寫著舊工具數量、舊 feature 列表——使用者從 marketplace 裝 plugin 看到的是 stale README，會以為新功能沒做完。這不是 hard failure（plugin 還是能跑），但是 silent UX failure（使用者困惑）。

### Step 1: Staleness 偵測

掃 `$PLUGIN_DIR/README.md`，**六個訊號任一命中 = 可疑 stale**。
新增的信號 4-6 是 v1.15.0 從跨 28 plugin 大規模 audit 中萃取的盲點 —
舊三信號漏掉「tool count drift / component inventory drift / multi-version
catch-up gap」這三類常見 staleness。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
README="$PLUGIN_DIR/README.md"
NEW_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_DIR/.claude-plugin/plugin.json")

# README 是否有任何版本追蹤標記（給 Suppression A 用）
HAS_VERSION_SECTION=false
if grep -qE '## (Version|Changelog)|# Changelog|v[0-9]+\.[0-9]+' "$README" 2>/dev/null; then
    HAS_VERSION_SECTION=true
fi

# 信號 1: README 沒出現新版本字串
if [ "$HAS_VERSION_SECTION" = "true" ] && ! grep -q "v$NEW_VERSION\|$NEW_VERSION" "$README" 2>/dev/null; then
    echo "⚠️  signal-1: README has version markers but doesn't mention v$NEW_VERSION"
    STALE_README=true
fi

# 信號 2: README 最後一次修改早於 plugin.json / skills / hooks 最近修改
# 套用兩個 suppression 避免誤判：
#   A. README 完全沒有版本追蹤內容 → mtime drift 沒意義（純 skill plugin / glue plugin）
#   B. 所有「比 README 新的 commits」都是 wrapper-only / marketplace.json sync 等
#      不影響使用者可見 surface 的 plumbing 改動 → 不算 stale
README_MTIME=$(git --literal-pathspecs log -1 --format=%ct -- "$PLUGIN_DIR/README.md" 2>/dev/null)
CODE_MTIME=$(git --literal-pathspecs log -1 --format=%ct -- "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_DIR/skills" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/rules" "$PLUGIN_DIR/commands" 2>/dev/null)
if [ -n "$README_MTIME" ] && [ -n "$CODE_MTIME" ] && [ "$README_MTIME" -lt "$CODE_MTIME" ]; then
    if [ "$HAS_VERSION_SECTION" = "false" ]; then
        # Suppression A — 沒版本追蹤標記，mtime drift 沒意義
        :
    else
        # Suppression B — 過濾掉純 wrapper / marketplace 同步 commits
        # 找出 README mtime 之後、touch 此 plugin 的所有 commits
        SUBSTANTIVE_COMMITS=$(git --literal-pathspecs log --since="@$README_MTIME" --format='%s' \
            -- "$PLUGIN_DIR/" 2>/dev/null | \
            grep -vE '^(fix|chore|docs)\(.*\): (add version-aware auto-download|sync marketplace\.json|update repo URLs|bump.*version|wrapper)' | \
            grep -vE 'wrapper.sh\b|marketplace\.json sync|plugin\.json version' | \
            head -5)
        if [ -n "$SUBSTANTIVE_COMMITS" ]; then
            echo "⚠️  signal-2: README older than substantive code changes:"
            echo "$SUBSTANTIVE_COMMITS" | sed 's/^/      /'
            STALE_README=true
        fi
    fi
fi

# 信號 3: 若有 CHANGELOG.md，檢查最新 entry 是否已出現在 README
CHANGELOG="$PLUGIN_DIR/CHANGELOG.md"
if [ -f "$CHANGELOG" ]; then
    LATEST_CL_VERSION=$(grep -oE '^## \[?[0-9]+\.[0-9]+\.[0-9]+\]?' "$CHANGELOG" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$LATEST_CL_VERSION" ] && ! grep -q "$LATEST_CL_VERSION" "$README"; then
        echo "⚠️  signal-3: CHANGELOG latest v$LATEST_CL_VERSION not in README"
        STALE_README=true
    fi
fi

# 信號 4: Component inventory drift（v1.15.0 新增；移植自 plugin-deploy）
# 實際 skills / agents / commands 是否都在 README 提到。
# 漏掉 = 使用者看 README 不知道有這個 skill。
#
# 篩選規則（v1.15.0）：只計算「真實組件」 —
#   skills/<name>/   必須含 SKILL.md（空目錄是實驗殘留，不算 skill）
#   agents/*.md      檔案必須存在
#   commands/*.md    檔案必須存在
ACTUAL_SKILLS=$(find "$PLUGIN_DIR/skills/" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | xargs -n1 dirname 2>/dev/null | xargs -n1 basename 2>/dev/null | sort)
ACTUAL_AGENTS=$(find "$PLUGIN_DIR/agents/" -maxdepth 1 -name '*.md' 2>/dev/null | xargs -n1 basename -s .md 2>/dev/null | sort)
ACTUAL_COMMANDS=$(find "$PLUGIN_DIR/commands/" -maxdepth 1 -name '*.md' 2>/dev/null | xargs -n1 basename -s .md 2>/dev/null | sort)
MISSING_COMPONENTS=()
# 認可的引用格式（任一命中即視為「README 提到這個 component」）：
#   `name`              — backtick-quoted reference
#   /name               — bare slash command form
#   /plugin-name:name   — plugin-namespace form (typical in installed clients)
#   @name               — agent reference
#   - **name**          — markdown bold list entry
for s in $ACTUAL_SKILLS; do
    grep -qE "\`$s\`|/${s}\b|/[a-z0-9_-]+:${s}\b|^- \*\*$s\*\*" "$README" 2>/dev/null || MISSING_COMPONENTS+=("skill:$s")
done
for a in $ACTUAL_AGENTS; do
    grep -qE "\`$a\`|@$a\b|/[a-z0-9_-]+:${a}\b|^- \*\*$a\*\*" "$README" 2>/dev/null || MISSING_COMPONENTS+=("agent:$a")
done
for c in $ACTUAL_COMMANDS; do
    grep -qE "/${c}\b|\`/${c}\`|/[a-z0-9_-]+:${c}\b" "$README" 2>/dev/null || MISSING_COMPONENTS+=("command:$c")
done
if [ ${#MISSING_COMPONENTS[@]} -gt 0 ]; then
    echo "⚠️  signal-4: README missing ${#MISSING_COMPONENTS[@]} components: ${MISSING_COMPONENTS[*]}"
    STALE_README=true
fi

# 信號 5: Tool count drift（v1.15.0 新增）
# README 多半會在標題寫「(N tools)」「N MCP Tools」「Tool 數量: N」。
# 把這個 N 抓出來跟 plugin.json description 中宣稱的 tool 數比對。
# README 落後最容易在這露餡（che-ical-mcp v0.8.2 → v1.7.2 README 寫 20 tools 實際 28）。
DESC=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("description", ""))' "$PLUGIN_DIR/.claude-plugin/plugin.json")
DESC_TOOLS=$(echo "$DESC" | grep -oE '[0-9]+ ?(?:個 )?(?:MCP )?(?:tools|工具)' | head -1 | grep -oE '^[0-9]+')
README_TOOLS=$(grep -oE 'Available Tools \([0-9]+\)|\([0-9]+ (?:MCP )?tools\)|\*\*[0-9]+ MCP Tools\*\*|[0-9]+ 個工具' "$README" 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ -n "$DESC_TOOLS" ] && [ -n "$README_TOOLS" ] && [ "$DESC_TOOLS" != "$README_TOOLS" ]; then
    echo "⚠️  signal-5: README tool count ($README_TOOLS) != plugin.json description ($DESC_TOOLS)"
    STALE_README=true
fi

# 信號 6: Version history multi-version gap（v1.15.0 新增）
# 如果 README 有 Version History 表格，掃「最近 90 天」的 git log 找出 bump commits，
# 確保表格涵蓋這段時間出貨的版本 — 不只是「latest 有沒有」（信號 1）而是「中間是否漏版本」。
# 範圍只看 90 天避免 major rewrite（plugin v1.x → v2.x README 改寫）誤觸發。
if grep -q '## Version History\|### Changelog' "$README" 2>/dev/null; then
    SHIPPED_VERSIONS=$(git --literal-pathspecs log --since="90 days ago" --format='%s' -- "$PLUGIN_DIR/" 2>/dev/null | \
        grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -8)
    MISSING_VERSIONS=()
    for v in $SHIPPED_VERSIONS; do
        v_clean=${v#v}
        grep -q "$v_clean\|v$v_clean" "$README" 2>/dev/null || MISSING_VERSIONS+=("$v_clean")
    done
    # 進一步限制：只計算「同 major 版本」的 missing（避免 major rewrite 誤判）
    CURRENT_MAJOR=$(echo "$NEW_VERSION" | cut -d. -f1)
    SAME_MAJOR_MISSING=()
    for v in "${MISSING_VERSIONS[@]}"; do
        v_major=$(echo "$v" | cut -d. -f1)
        [ "$v_major" = "$CURRENT_MAJOR" ] && SAME_MAJOR_MISSING+=("$v")
    done
    if [ ${#SAME_MAJOR_MISSING[@]} -gt 1 ]; then
        # 容忍漏 1 個（可能是 patch/internal），漏 2+ 個就明顯 stale
        echo "⚠️  signal-6: README Version History missing ${#SAME_MAJOR_MISSING[@]} same-major versions: ${SAME_MAJOR_MISSING[*]}"
        STALE_README=true
    fi
fi
```

**設計理由速覽**：

| 信號 | 解決的 false negative | 觀察來源 |
|------|---------------------|---------|
| 1 (legacy) | README 整個版本記錄沒同步 | 原始版本 |
| 2 (legacy + suppressions) | mtime drift；現避免誤判 wrapper-only 改動 | 大規模 audit 發現 4/11 是 false positive |
| 3 (legacy) | CHANGELOG bump 但 README 沒同步 | 原始版本 |
| 4 (new) | 新增的 skill / agent / command 沒寫進 README | issue-driven-dev：5 個 skill 列表，實際 10 個 |
| 5 (new) | README 寫的工具數比實際少 | che-ical-mcp：寫 20 工具，實際 28 |
| 6 (new) | Version History 表格漏中間 N 個版本 | che-duckdb-mcp：v2.0 → v2.2.1 中間漏 4 版 |

### Step 2: 行為決策 — AskUserQuestion

偵測到 stale 時，**不要直接繼續**。用 AskUserQuestion 讓使用者決定：

```
question: "README.md 看起來沒跟上 v$NEW_VERSION（沒提到新版本 / 新工具 / 比程式碼舊）。要怎麼處理？"
options:
  - "更新 README" — 我會讀 CHANGELOG + recent commits 幫忙起草，你審閱後 commit
  - "已經沒問題" — README 其實是對的（純內部重構、不對外新增 surface），繼續 deploy
  - "先略過，稍後手動處理" — 繼續 deploy 但留一條 warning 在最終 report
```

| 選項 | 行為 |
|------|------|
| 更新 README | Read CHANGELOG.md + 在帶前導的 fence 內 `git --literal-pathspecs -C "$MP_ROOT" log --oneline -n 10 -- "$PLUGIN_DIR/"` → 提出 README diff → 使用者確認後 Edit + commit + push |
| 已經沒問題 | 繼續 Phase 3，不記 warning |
| 先略過 | 繼續 Phase 3，**Phase 5 最終 report 要顯眼標註** README 待補 |

### 狀況表

| 狀況 | 動作 |
|------|------|
| README 不存在 | 跳過（plugin-deploy 才會強制補） |
| README 存在且 fresh（六個信號都通過）| 顯示 ✅，繼續 Phase 3 |
| README 存在但 stale | **AskUserQuestion**（三選項） |
| 只有 signal-2 命中且 Suppression A/B 啟動 | 視為 fresh（避免誤判 wrapper-only / no-version-section plugins） |

### 為什麼是 ASK 而不是 BLOCK

| Skill | 觸發頻率 | README 行為 | 理由 |
|-------|---------|-----------|------|
| `plugin-update` Phase 2.5 | 頻繁（日常同步）| **ASK** | 有時純修 typo / hook / internal refactor，不需要動 README |
| `plugin-deploy` Step 2 | 偶爾（發版時）| **列入 checklist 並 offer 修復** | 正式發布時使用者第一眼看 README，stale 就是差的第一印象 |

---

## Phase 3: 同步 Marketplace Cache

### Step 1: 更新 marketplace cache

```bash
claude plugin marketplace update {marketplace_name}
```

這會從 source（git remote 或本地目錄）重新拉取 plugin index。

### Step 2: 驗證

```bash
claude plugin list 2>&1 | grep -A3 "{plugin_name}"
```

---

## Phase 4: 更新已安裝的 Plugin

### 注意：必須加 `@marketplace_name` 後綴

```bash
# 已安裝 → 更新
claude plugin update {plugin_name}@{marketplace_name}

# 未安裝 → 安裝
claude plugin install {plugin_name}@{marketplace_name}
```

先檢查是否已安裝：
```bash
claude plugin list 2>&1 | grep "{plugin_name}"
```

---

## Phase 5: 驗證與提醒

### Step 1: 確認最終狀態

```bash
claude plugin list 2>&1 | grep -A5 "{plugin_name}"
```

檢查：
- Version 是否已更新到目標版本
- Status 是否 `✔ enabled`
- 是否有 `failed to load` 錯誤

### Step 2: 提醒重啟

> 更新完成。請重啟 Claude Code（退出再重新開啟）讓變更完全生效。
> 或者在下次啟動新對話時，新版 plugin 就會自動載入。

---

## 批次更新

多個 plugin 需要更新時：

```bash
# 1. 同步 marketplace（只需一次）
claude plugin marketplace update {marketplace_name}

# 2. 逐一更新（需加 @marketplace 後綴）
claude plugin update plugin-a@{marketplace_name}
claude plugin update plugin-b@{marketplace_name}
```

---

## 常見問題

### Plugin 更新後 skill 沒變？
Claude Code 有快取機制。需要重啟才能載入新版 skill 內容。

### `failed to load` 錯誤？
通常是 hooks.json 格式問題：
```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
claude plugin validate "$PLUGIN_DIR"
```

### `marketplace update` 沒看到新版本？
1. 確認 `marketplace.json` 的版本號已更新
2. 確認已 push 到 remote：
```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 兩個常值由 agent 代入：PLUGIN_NAME = 本次引數，MP_NAME = Step 0.1 印出的 marketplace 名。
# **代入前先肉眼核對兩者都只含 [A-Za-z0-9._-]**；不符就停下來回報，不執行任何指令
# （單引號裡一個 ' 或 " 就能逃出字串——代入是文字操作，shell 層的檢查在它之後）。
PLUGIN_NAME='<plugin-name>'
MP_NAME='<marketplace-name-from-step-0.1>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME$MP_NAME" in *[![:alnum:]._-]*|'') echo "✗ 名稱含非法字元或為空" >&2; exit 1 ;; esac
MP_ROOT=$(resolve_marketplace_root "$MP_NAME") && PLUGIN_DIR=$(resolve_plugin_dir "$MP_ROOT" "$PLUGIN_NAME") \
  || { echo "✗ '$PLUGIN_NAME' 在 marketplace '$MP_NAME' 解析失敗（rc $?）— Step 0.1 必須先通過" >&2; exit 1; }
cd "$MP_ROOT"
git log origin/main..HEAD --oneline
```

### `plugin update` 找不到 plugin？
需要加 `@marketplace_name` 後綴：
```bash
# 錯誤
claude plugin update my-plugin
# 正確
claude plugin update my-plugin@psychquant-claude-plugins
```
