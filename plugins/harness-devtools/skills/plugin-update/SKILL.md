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
  - Bash(gh:*)
  - Bash(curl:*)
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
TaskCreate(name="detect_marketplace", description="Phase 0: 找到 plugin 所屬的 marketplace repo（Step 0.1 寫 context 檔）。invocation 沒帶 plugin 名時，detect_changes（Phase 1 Step 1 推斷）提前到這一項之前，選定名稱後再回來")
TaskCreate(name="sync_intent_gate", description="Phase 0.3 (v1.17.0+, #19 對所有 plugin 執行, #22 binary metadata 經 plugin-binary-meta.sh): pre-flight intent check — 信號 = latest release 比 pin 新（Case E，先問 bump）∨ marketplace drift（含 entry 缺 version / 缺 entry）∨ 30 天內 shell 變更 ∨ plugin 目錄 / marketplace.json 未提交改動 ∨ 未推送 commit 動到它們 ∨ binary 信號（純 shell plugin 的 binary 信號為空）；判定順序 E → C → B → A；全部落空 → abort early (no-op short-circuit)；binary unknown / unreleased → Case B 問")
TaskCreate(name="git_state_gate", description="Phase 0.5 (v1.16.0+ #60, #19): preview git status / unpushed commits / divergence；clean start（樹乾淨、0 既有未推送）直接通過（Phase 2 的 commit 由 Phase 2 自己 push）；只有樹上既有未提交 / 未推送 / 分歧時才 AskUserQuestion（abort default）；idd-all unattended → Case B–E auto-abort、Case A 通過")
TaskCreate(name="detect_changes", description="Phase 1: 確認 plugin + 最近 commits（git status 已由 Phase 0.5 gate）")
TaskCreate(name="check_external_deps", description="Phase 1.5: 偵測 MCP/CLI 依賴，不同步時 AskUserQuestion")
TaskCreate(name="sync_marketplace_json", description="Phase 2: 比對 plugin.json 和 marketplace.json 版本，commit+push")
TaskCreate(name="check_readme_freshness", description="Phase 2.5: 檢查 README 是否跟上版本 / 新工具，過時時 AskUserQuestion")
TaskCreate(name="marketplace_update", description="Phase 3: claude plugin marketplace update")
TaskCreate(name="plugin_install_or_update", description="Phase 4: claude plugin install/update @marketplace")
TaskCreate(name="verify_and_report", description="Phase 5: claude plugin list 驗證 + Step 1.5 binary-backed 驗證（installed sidecar == pin；無 sidecar → UNVERIFIED，不當完成，#22）+ 提醒重啟 + 最終 report")
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
# 可選：使用者指定、或 Phase 1 Step 1 印出的 marketplace 名。有值 → 只在那個 marketplace 的 checkout
# 裡解析（Phase 1 看到的是哪份，Step 0.1 就用哪份，不再全域重選）；空 → 全域反查。
# 這個值是使用者自己的引數（或使用者剛在 Phase 1 選定的），同樣先肉眼核對 [A-Za-z0-9._-]。
MP_NAME='<marketplace-name-or-empty>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
clean() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]\\' | LC_ALL=C cut -c1-200; }   # 也去反斜線：zsh 的 echo 會展開 \n \t
case "$MP_NAME" in '<marketplace-name-or-empty>') MP_NAME="" ;; esac   # 未代入的佔位視同空
case "$PLUGIN_NAME" in
    ''|'<plugin-name>')
        echo "✗ Phase 0.1: 沒有 plugin 名稱。invocation 沒帶引數時，先跑 Phase 1 Step 1 推斷" >&2
        echo "  （只掃一個 marketplace），選定名稱後帶著它（與該 marketplace 名）重跑 Step 0.1。" >&2
        exit 1 ;;
    .*|-*|*[!A-Za-z0-9._-]*)
        echo "✗ Phase 0.1: plugin 名稱 '$(clean "$PLUGIN_NAME")' 不合法。" >&2
        echo "  名稱會進路徑與 argv，只接受 [A-Za-z0-9._-] 且不以 . 或 - 開頭。這不是 marketplace 的問題。" >&2
        exit 1 ;;
esac
# marketplace 名與 plugin 名同一條規則（_valid_name）：[A-Za-z0-9._-]，不以 . 或 - 開頭
case "$MP_NAME" in .*|-*|*[!A-Za-z0-9._-]*) echo "✗ Phase 0.1: marketplace 名稱不合法（只接受 [A-Za-z0-9._-]，不以 . 或 - 開頭）" >&2; exit 1 ;; esac
WANT_MP="$MP_NAME"   # 指定的範圍另存：下面的 read 會覆寫 MP_NAME，abort 訊息要知道本次有沒有指定

# 持有者列舉（#18）：plugin_holders 走索引（有 WANT_MP 就只走該名稱的列），每列 resolve_plugin_dir，
# 解析到**同一個實體目錄**的列只算一個持有者——巢狀同名 marketplace（父 manifest 的 source 指進子
# checkout、子 checkout 自己也宣告）父子兩列指向同一個目錄，那不是歧義、沒有「副本」可清。
# 真正不同的目錄才是不同持有者（同一 marketplace 的兩份 clone）：以 cwd 消歧；cwd 不在其中任何
# 一份就 abort 並列出全部，不 first-wins 靜默選一份——有指定 MP_NAME 才嚴、沒指定就放行是反的。
HOLDERS=$(plugin_holders "$PLUGIN_NAME" "$WANT_MP") || HOLDERS=""
RESOLVED=""
case "$(printf '%s\n' "$HOLDERS" | grep -c .)" in
    0) ;;
    1) RESOLVED="$HOLDERS" ;;
    *)
        HERE=$(pwd -P); BEST=""
        while IFS='|' read -r hmp hroot hdir; do
            [ -n "$hroot" ] || continue
            rp=$(cd "$hroot" 2>/dev/null && pwd -P) || continue
            # 取**最內層**（最長）的包含 root，同 Phase 1 Step 1：巢狀 checkout 時外層也包含 cwd，
            # 索引順序是 find 的目錄順序，不能靠「第一個命中」（#18 R7）
            case "$HERE" in "$rp"|"$rp"/*) [ ${#rp} -gt ${#BEST} ] && { BEST="$rp"; RESOLVED="$hmp|$hroot|$hdir"; } ;; esac
        done <<EOF
$HOLDERS
EOF
        if [ -n "$RESOLVED" ]; then
            SEL_ROOT=${RESOLVED#*|}; SEL_ROOT=${SEL_ROOT%%|*}
            echo "ℹ Phase 0.1: '$PLUGIN_NAME' 有多份實體不同的 checkout 持有；用包含目前目錄的那份（最內層）：$(clean "$SEL_ROOT")"
        else
            echo "✗ Phase 0.1: '$PLUGIN_NAME' 在多份實體不同的 checkout 裡都解析得到，而目前目錄不在其中任何一份：" >&2
            printf '%s\n' "$HOLDERS" | while IFS='|' read -r hmp hroot hdir; do echo "    $(clean "$hmp")  $(clean "$hroot")" >&2; done
            # 兩種分佈、兩種處方（本機 7 例中 6 例是跨 marketplace 各自上架，不是副本，#18 R7）：
            if [ "$(printf '%s\n' "$HOLDERS" | cut -d'|' -f1 | sort -u | grep -c .)" -gt 1 ]; then
                echo "  這些是**不同 marketplace** 各自上架的同名 plugin（都是現役，不是副本，別刪）。" >&2
                echo "  把要更新的那個 marketplace 名代入本 fence 的 MP_NAME 重跑（只在該 marketplace 裡解析）；" >&2
                echo "  或 cd 進要更新的那份 checkout 再跑 Step 0.1（本 fence 以 cwd 消歧）。" >&2
            else
                echo "  這是**同一個 marketplace 的多份 clone**。cd 進要更新的那份 checkout 再跑 Step 0.1（本 fence 以 cwd 消歧）；" >&2
                echo "  確定是過時副本的才清掉。" >&2
            fi
            exit 1
        fi ;;
esac
IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$RESOLVED"

if [ -z "$MP_ROOT" ] || [ ! -d "$MP_ROOT" ]; then
    if [ -n "$WANT_MP" ]; then
        echo "✗ Phase 0.1: plugin '$PLUGIN_NAME' 不在 marketplace '$WANT_MP' 的任何 checkout 裡（本次限定在該 marketplace 解析）。" >&2
    else
        echo "✗ Phase 0.1: plugin '$PLUGIN_NAME' 不在任何已註冊的 marketplace 裡。" >&2
    fi
    echo "  已搜尋：$(list_marketplaces | while IFS= read -r m; do printf '%s ' "$(clean "$m")"; done)" >&2
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
    while IFS="$(printf '\t')" read -r mp root; do
        [ -n "$root" ] || continue
        resolve_plugin_dir "$root" "$PLUGIN_NAME" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 1 ] && continue
        src=$(plugin_source_of "$root" "$PLUGIN_NAME" 2>/dev/null)
        mp=$(clean "$mp"); root=$(clean "$root")
        case "$rc" in
            0) if [ -n "$WANT_MP" ] && [ "$mp" != "$WANT_MP" ]; then
                   echo "  ℹ '$mp' ($root) 解析得到——它屬於 marketplace '$mp'，不是你指定的 '$WANT_MP'。指定錯了就改 MP_NAME；要用這份就代入 '$mp'。" >&2
               else
                   echo "  ℹ '$mp' ($root) 其實解析得到，但持有者列舉沒回它——root 路徑含 | 分隔符（被跳過），或索引在兩次走訪之間變了；直接檢查該 root。" >&2
               fi ;;
            2) printf '  ⚠ %s (%s) 的 manifest 列了 %s，但 source（untrusted，已截斷；printf 不展開反斜線）= [%s]\n' "'$mp'" "$root" "'$PLUGIN_NAME'" "$src" >&2
               echo "    不可用：source 本身有問題（空、非字串、絕對、..、引號、|、控制字元、目錄不存在、symlink 逃出 root）→ 修該 manifest；" >&2
               echo "    或目標目錄不是這個 plugin（沒有 plugin manifest（.claude-plugin/plugin.json 或 plugin.json）、JSON 壞掉、或其 name 不等於 '$PLUGIN_NAME'）→ 修那個目錄的 plugin.json。" >&2
               echo "    這是確定的錯誤，不會退回探 plugins/${PLUGIN_NAME}。" >&2 ;;
            3) echo "  ⚠ '$mp' ($root)：此機器沒有可用的 python3，讀不了 manifest；只有 plugins/$PLUGIN_NAME 這種佈局偵測得到，而它不存在。" >&2 ;;
            4) echo "  ⚠ '$mp' ($root) 的 marketplace.json 讀不動（權限 / JSON 解析失敗 / 形狀不對），且 plugins/$PLUGIN_NAME 未物化。" >&2
               echo "    這不是「沒上架」——先修 JSON（常見：多餘逗號）。" >&2 ;;
            5) printf '  ℹ %s (%s) 列了 %s，source（untrusted，已截斷；printf 不展開反斜線）= [%s]\n' "'$mp'" "$root" "'$PLUGIN_NAME'" "$src" >&2
               echo "    是合法但非本地的寫法（git-subdir 物件 / URL），且 plugins/$PLUGIN_NAME 未物化。" >&2
               echo "    manifest 沒壞；plugin-update 只處理本地佈局。要更新它，先把 subtree 物化到 plugins/${PLUGIN_NAME}。" >&2 ;;
            *) echo "  ⚠ '$mp' ($root)：resolve_plugin_dir 回了未預期的 rc ${rc}。" >&2 ;;
        esac
    done <<EOF
$(marketplace_index)
EOF
    exit 1
fi

if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
    # plugin_holders 命中就一定帶第三欄；走到這裡代表 resolver 契約被改了
    # （例如有人把它退回兩欄），不是 marketplace 的問題。一樣 abort——見下段。
    echo "✗ Phase 0.1: plugin_holders 回了 '$(printf '%s' "$RESOLVED" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200)'，第三欄不是目錄。" >&2
    echo "  resolve-marketplace.sh 的契約是 name|root|plugin_dir（#18）；請對它跑" >&2
    echo "  scripts/test-resolve-marketplace.sh。" >&2
    exit 1
fi

# plugin-update 同步的就是 plugin.json 的 version：目錄沒有 manifest（materialized git-subdir
# subtree，如 akashic-mcp——靠目錄名 + plugin 形狀被承認）就沒有版本可讀、可比、可 bump。
# 在這裡擋，不要等 Phase 2 讀到空字串（讀不到 ≠ 已同步，#18）。manifest 位置由 resolver 的
# 同一套查法給（.claude-plugin/plugin.json 或 plugin.json），後面每個 fence 用 ${PLUGIN_MANIFEST}。
PLUGIN_MANIFEST=$(plugin_manifest_path "$PLUGIN_DIR") || {
    echo "✗ Phase 0.1: $(clean "$PLUGIN_DIR") 沒有 plugin manifest（.claude-plugin/plugin.json 或 plugin.json）。" >&2
    echo "  它靠目錄名與 plugin 形狀被承認（materialized subtree），沒有 version 可同步——plugin-update 對它無事可做；" >&2
    echo "  要讓它可更新，先在該目錄補 .claude-plugin/plugin.json（name + version）。" >&2
    exit 1
}
# 把驗證過的三元組寫進 context 檔（私有 state 目錄、mktemp+mv、純資料）：之後每個 block 只載回
# 並重驗，agent 不代入任何第三方值。marketplace 名稱含非法字元（來自第三方 manifest）在這裡就擋掉。
CTX=$(plugin_ctx_path "$PLUGIN_NAME")
write_plugin_ctx "$CTX" "$MP_NAME" "$MP_ROOT" "$PLUGIN_DIR" "$PLUGIN_NAME" || {
    rc=$?
    echo "✗ Phase 0.1: 無法寫 context（rc ${rc}）：marketplace 名稱 '$(clean "$MP_NAME")' 不在 [A-Za-z0-9._-]（untrusted manifest，不採用）、root / plugin 目錄含引號、控制字元、|，或 state 目錄不可寫。" >&2
    exit 1
}
echo "→ Step 0.1 OK: marketplace=$(clean "$MP_NAME") root=$(clean "$MP_ROOT") plugin_dir=$(clean "$PLUGIN_DIR") manifest=$(clean "$PLUGIN_MANIFEST") context=$CTX"
```

**`PLUGIN_DIR` 也 gate，理由和 `MP_ROOT` 一樣（#18）**：在 #18 之前這個 skill 有 17 處自己
把路徑組成 `$MP_ROOT/plugins/$PLUGIN_NAME`。對 `source: "./plugin"` 的單一 plugin
marketplace（che-keychain、che-apple-mail-mcp、che-ical-mcp）那個目錄不存在，而後面每一個
「檔案在不在」的偵測都把不存在讀成「沒有」——`IS_BINARY_BACKED=false`、`binary_version`
空、README 六信號全跳過——和 `MP_ROOT` 為空時一模一樣，只是這次 `MP_ROOT` 是對的。
路徑現在只有一個來源：manifest 的 `plugins[].source`，由 `resolve_plugin_dir` 解析。

**這是 abort，不是 warn。** 繼續下去的每一條路徑都是對錯的目標動手，而其中一條會
主動邀請使用者 push 一個不相干的 repo。

**同名 plugin 被多份實體不同的 checkout 持有時**（本機目前有 7 個：bestocr、parallel-ai-agents、
che-creative-suite、che-dropbox-ignore、che-pixel-mcp、che-svg-mcp 各在兩個 marketplace 上架；
che-apple-mail-mcp 有兩份 clone），`/plugin-update <name>` 不再靜默取索引第一份：站在要更新的
checkout 裡跑、或帶 marketplace 名（Step 0.1 的 `MP_NAME`），否則 Step 0.1 會列出全部持有者並 abort。

**每個 bash block 自己載回 context（#18）**：agent 是分次呼叫 Bash 工具執行這份 SKILL.md
的，shell 變數不跨呼叫存活。Step 0.1 設好的 `MP_ROOT` / `PLUGIN_DIR` 到 Phase 0.3 那個
shell 已經不存在——空的 `$PLUGIN_DIR/.mcp.json` 測的是 `/.mcp.json`，答案是「沒有」，而
「沒有」正是本 issue 要消滅的那種靜默失敗。所以 Step 0.1 把驗證過的三元組寫進 context 檔
（`write_plugin_ctx`），之後**每一個**用到 `$MP_ROOT` / `$PLUGIN_DIR` 的 block 都以同一段
前導開頭：`load_plugin_ctx` 載回並**重驗**（名稱合法、`MP_ROOT` 仍是該 marketplace 的
候選、`resolve_plugin_dir` 仍給同一個目錄），然後 `cd "$MP_ROOT"`。這樣 (a) 同名多
checkout 時 Step 0.1 gate 過的那份 root 才是後面 `git push` 的那份——靠名稱重選會走另一套
tie-break；(b) root / plugin 目錄不經 agent 代入；唯一會被 agent 貼回的第三方值是 marketplace
名——它在 resolver 的**索引層**就過了 `[A-Za-z0-9._-]`（不合法的 marketplace 整個不列入，
`list_marketplaces` / `marketplace_index` / `plugin_holders` 印不出它），Phase 1 印出、代入
Step 0.1 時再以 shell `case` 二次守門；(c) 每個含 git 的 fence 都在 marketplace repo 內跑——Phase 0.5 Step 3 的 commit / push
也有專用 fence，agent 不在對話裡現組 git 指令。這不是「重組路徑」：路徑
仍然只從 manifest 來，只是每個 shell 各驗一次。**表格儲存格與散文裡的 `<PLUGIN_DIR>` 是
敘述，不是可執行的指令；可執行的形式只在帶前導的 fence 裡。**

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
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
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1

# 四個結構信號收斂在 scripts/plugin-binary-meta.sh（#22），這裡只消費：
#   .mcp.json ∨ bin/ 下**任何一般檔案**含 release URL ∨ hooks/*.sh 含同一 URL pattern ∨ manifest 有 binary pin
# 判準是 URL 形狀（`gh release download` / `api.github.com/repos/…/releases` / `github.com/…/releases/(download|tags|latest)`，
# 與 idd-close 的 has_binary_wrapper 同一條），不是檔名後綴（che-keychain 的 wrapper 叫 bin/che-keychain）、也不是變數名
# （REPO= 與 GITHUB_REPO= 都不是判準）。不掃 skills/ 散文——harness-devtools 自己的 SKILL.md 就會命中（#18 R4）。
# helper 不用 glob（find 列檔），zsh nomatch 不會中止 fence（#18 R7）；不用 `ls | xargs grep | head` 那種退出碼恆 0 的 pipeline（#18 R5）。
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
BINARY_HITS=$(plugin_is_binary_backed "$PLUGIN_DIR" "$PLUGIN_MANIFEST") && IS_BINARY_BACKED=true || IS_BINARY_BACKED=false
echo "→ Phase 0.3 Step 1: IS_BINARY_BACKED=${IS_BINARY_BACKED}${BINARY_HITS:+ ($BINARY_HITS)}"
[ "$IS_BINARY_BACKED" = true ] || echo "  （四個信號皆未命中：.mcp.json / bin/* 含 release URL / hooks/*.sh 含 release URL / manifest 有 binary_version 或 binaryVersion。不等於一定沒有 binary——但已沒有其他結構信號可查；wrapper 不放在 bin/ 或 hooks/ 的佈局本 skill 不認）"
```

**非 binary-backed plugin（純 skill / rule / agent）也照跑 Step 2**（#19）：它們的 binary 信號為空（`BINARY_UNRELEASED` 空 → 不進 Case B），但 `MP_DRIFT`、`SHELL_RECENT_TOUCHES`、`SHELL_DIRTY` 這三個信號跟 binary 無關、只算在 Step 2 裡——跳過 Step 2 等於純 shell plugin 在 Phase 2 之前沒有任何地方判定「marketplace.json 落後了沒」，也沒有 no-op 早退。#19 之前這裡寫「跳過 Phase 0.3，直接走 Phase 0.5」，理由是「沒改 → Phase 0.5 自然 abort」；但 0.5 看的是**此刻**有沒有待推送，跟「30 天內改過、已 push、marketplace 還沒鏡像」是正交的（那正是 Case C 該接住的情境），而 2026-08-31 che-apple-mail-mcp 3.0.0 的誤攔就是兩道 gate 判準正交的結果。

### Step 2: 收集 sync 候選變更（所有 plugin；binary 部分只對 binary-backed 有值）

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1

# 路徑一律走 sys.argv，不內嵌進 python 原始碼：$PLUGIN_DIR 來自 manifest（第三方檔案），
# 內嵌成 open('$PLUGIN_DIR/...') 時路徑裡一個 ' 就是任意程式碼執行（#18 R1 security）。
# (a) 從 plugin.json 取 binary_version + shell version
# manifest 路徑來自 load_plugin_ctx 的 ${PLUGIN_MANIFEST}（.claude-plugin/plugin.json 或根目錄 plugin.json，
# 與 resolver 承認目錄時用的同一套查法）——不要自己組 .claude-plugin/plugin.json（#18 R6：safari-browser
# 等根目錄佈局 resolver 認、消費端讀不到）。
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ Phase 0.3: $PLUGIN_DIR 沒有 plugin manifest — 沒有 version 可同步（Step 0.1 應已擋下）" >&2; exit 1; }
SHELL_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_MANIFEST" 2>/dev/null)
# 讀不到 ≠ 已同步：空版本號不能拿去比對
[ -n "$SHELL_VERSION" ] || { echo "✗ Phase 0.3: 讀不到 $PLUGIN_MANIFEST 的 version — 無法判定 sync intent" >&2; exit 1; }
# binary pin 與結構信號一律經 scripts/plugin-binary-meta.sh（#22）：欄位讀 binary_version（#77 schema）與
# binaryVersion（che-keychain / che-transport-mcp 的 wrapper 自己讀的）兩種拼法、**不**回退 version（那是 shell 版本）；
# 寫回時保留檔案原本的 key（Case E 的 bump fence）。值過 [A-Za-z0-9.+-] 才會被印出來。
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
# 有效 pin = wrapper 實際會下載的那個版本：binary_version → binaryVersion → version（#77 之前的 wrapper 與 che-keychain 的
# fallback 分支都讀 version；本機 marketplace 13 個 binary-backed plugin 只有 version）。**key 一律印出來**：來自 version 的值
# 對 che-apple-notes-mcp 是真的比對，對 shell / binary 各自版號的 plugin 是「該補 pin」的提醒——只有讀的人分得出（#22 verify R1）。
PBV=$(plugin_binary_version_effective "$PLUGIN_MANIFEST"); PBV_RC=$?
BINARY_VERSION=${PBV%%|*}; BINARY_PIN_KEY=${PBV#*|}; [ "$BINARY_PIN_KEY" = "$PBV" ] && BINARY_PIN_KEY=""
[ "$PBV_RC" = 3 ] && echo "⚠ $PLUGIN_MANIFEST 的 binary pin 含非法字元（只接受 [A-Za-z0-9.+-]）— 視為沒有 pin"
# Step 1 的判定不跨 fence：同一個 helper 重算（值不靠上一個 shell）
BINARY_HITS=$(plugin_is_binary_backed "$PLUGIN_DIR" "$PLUGIN_MANIFEST") && IS_BINARY_BACKED=true || IS_BINARY_BACKED=false
# 純 shell plugin 也有 version，但那不是任何 binary 的 pin：不是 binary-backed 就沒有有效 pin（否則每個純 shell plugin 都會落進 Case B no-clone）
[ "$IS_BINARY_BACKED" = true ] || { BINARY_VERSION=""; BINARY_PIN_KEY=""; }

# (b) 比對 marketplace.json — 落後嗎？「entry 不存在」（rc 1，Phase 2 Step 3 要新增整個 entry）與「entry 缺 version」
# （rc 0 印空，Phase 2 Step 2 補一個欄位）是兩件事，各印各的理由；兩者都算落後（MP_DRIFT=yes），不是「'' != x 剛好」
# 那種巧合（#22 第 4 點）。manifest 讀不動就 abort——它是 Step 0.1 剛讀過的檔，讀不動是真的壞了。
MP_VERSION=$(marketplace_entry_version "$MP_ROOT" "$PLUGIN_NAME"); MEV_RC=$?
case "$MEV_RC" in
  0) [ -n "$MP_VERSION" ] || echo "ℹ marketplace.json 的 '$PLUGIN_NAME' entry has no version — 視為落後，Phase 2 Step 2 會補上" ;;
  1) echo "ℹ marketplace.json 沒有 '$PLUGIN_NAME' 的 entry — 視為落後，Phase 2 Step 3 會新增" ;;
  3) echo "⚠ marketplace.json 的 '$PLUGIN_NAME' entry 的 version 含非法字元 — 視為落後"; MP_VERSION="" ;;
  *) echo "✗ Phase 0.3: 讀不動 $MP_ROOT/.claude-plugin/marketplace.json（rc ${MEV_RC}）— 無法判定 sync intent" >&2; exit 1 ;;
esac
MP_DRIFT=$([ "$MP_VERSION" != "$SHELL_VERSION" ] && echo yes || echo no)

# (c) Shell 檔案最近 N 個 commits 是否觸到此 plugin？
# pathspec 用絕對 ${PLUGIN_DIR}（git 接受 worktree 內的絕對路徑；同檔 Phase 2.5 亦然），並帶
# --literal-pathspecs（目錄名含 * ? [ 時不得當 glob）。不要相對化：${PLUGIN_DIR#$MP_ROOT/} 把
# MP_ROOT 當 glob、對 repo 即 plugin 的佈局會變空字串。root-sourced plugin（source "."）的
# pathspec 是整個 repo：對它這個信號等於「repo 30 天內有沒有 commit」，是佈局語意，不是誤報。
# git 答不出來（不是 work tree、HEAD 未生、git 缺席）不能變成「30 天內沒改」再變成 Case A 的「事實」：
# 先探一次，探不到就 abort（Phase 0.3 在 0.5 之前，這裡是第一個碰 git 的地方）
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git rev-parse -q --verify HEAD >/dev/null 2>&1 \
  || { echo "✗ Phase 0.3: $MP_ROOT 不是可用的 git work tree（或沒有任何 commit）— 無法判定 sync intent。plugin-update 的 Phase 0.5 / 2 / 5 都要 push，純本地目錄型 marketplace 不在它的服務範圍" >&2; exit 1; }
SHELL_RECENT_TOUCHES=$(git --literal-pathspecs log --since="30 days ago" --name-only --pretty=format: \
    -- "$PLUGIN_DIR/" 2>/dev/null \
    | grep -v '^$' | sort -u | head -10)
# (c') 工作目錄裡**未提交**的改動：git log 看不到它們，而「改完就跑 /plugin-update」正是本 skill 的主要情境——
# 沉睡 30 天的 plugin 改完未 commit，沒有這個信號會被 Case A 用一句假的「30 天內沒改」擋掉（#19 R1）
SHELL_DIRTY=$(git --literal-pathspecs status --porcelain -- "$PLUGIN_DIR" .claude-plugin/marketplace.json 2>/dev/null)   # 含 marketplace.json 自己的未提交鏡像（#19 R2）
DIRTY_N=$(printf '%s' "$SHELL_DIRTY" | grep -c .)
# (c'') 已 commit、尚未推送、且動到本 plugin 或 marketplace.json 的 commit：30 天窗口看不到超過 30 天的，
# 而 #19 之前純 shell plugin 靠 Phase 0.5 Case B 接住這個狀態——0.3 對所有 plugin 執行後不能先一步 exit 0（#19 R2）。
# @{u} 答不出來（沒有 upstream / detached HEAD）跟上面的 work-tree 探測同一條規則：abort，不得靜默當 0（#19 R3）
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
  || { echo "✗ Phase 0.3: 目前 branch 沒有 upstream tracking（或 detached HEAD）— 未推送的變更無法判定。先 git branch --set-upstream-to=<remote>/<branch>（或 push -u）再重跑" >&2; exit 1; }
SHELL_UNPUSHED=$(git --literal-pathspecs log --oneline "$UPSTREAM..HEAD" -- "$PLUGIN_DIR" .claude-plugin/marketplace.json 2>/dev/null) \
  || { echo "✗ Phase 0.3: 算不出 $UPSTREAM..HEAD" >&2; exit 1; }
UNPUSHED_N=$(printf '%s' "$SHELL_UNPUSHED" | grep -c .)
REPO_UNPUSHED=$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null) || { echo "✗ Phase 0.3: 算不出 $UPSTREAM..HEAD" >&2; exit 1; }

# (d) BINARY repo: main 是否有 unreleased commits（信號移植自 #66 Phase 1.5 強化）
# owner/repo 由 plugin_binary_repo 從 bin/* 與 hooks/*.sh 抽（URL 字面或 <任何>_REPO= / REPO= 賦值，兩段都過 allowlist；
# #22：不靠 *-wrapper.sh 檔名、不靠固定變數名）。多個不同 repo → 取第一個並印出來，不靜默選。
# detect_binary_repo 定義在本 fence 內（函式也不跨 Bash 呼叫存活）：在三個常見路徑找 local clone；找不到 → 空（best-effort）。
BINARY_REPO=$(plugin_binary_repo "$PLUGIN_DIR"); PBR_RC=$?
# rc 2 只在同一層級（*_REPO= 賦值 vs 賦值）多值時出現——文件連結不是候選；真實案例是 wrapper 指 PsychQuant/x、hook 指舊 fork
[ "$PBR_RC" = 2 ] && echo "⚠ $PLUGIN_DIR 的 *_REPO= 賦值不一致（$(plugin_binary_wrappers "$PLUGIN_DIR" | cut -d'|' -f1,4 | tr '\n' ' ')）— 取第一個（${BINARY_REPO}），其餘不核對；請統一"
detect_binary_repo() {
    local repo="$1" base c
    [ -n "$repo" ] || return 1
    base=${repo##*/}
    case "$base" in .|..|.*|-*) return 1 ;; esac            # 檔案內容組出的路徑段，不接受 . / .. / 隱藏 / 選項形
    for c in "$HOME/Developer/$base" "$HOME/Developer/che-mcps/$base" "$HOME/code/$base"; do
        [ -d "$c/.git" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
# 四態：數字 = 比對過；unknown = 沒 clone / 沒 tag / 沒 main、**或 binary-backed 但 plugin.json 沒宣告版本**
# （查不到不是 0，#18 R4/R5）；空 = 非 binary-backed
# unknown 分兩個子態，Step 4 Case B 的問句與建議不同：no-pin（plugin.json 沒宣告版本，該做的是補 pin，
# 不是 release）/ no-clone（有 pin 但本機沒有 clone / tag / main 可核對）。
BINARY_UNRELEASED=""; BINARY_UNKNOWN_WHY=""; BINARY_REPO_PATH=""
if [ "$IS_BINARY_BACKED" = true ] && [ -z "$BINARY_VERSION" ]; then
    BINARY_UNRELEASED=unknown; BINARY_UNKNOWN_WHY=no-pin
    echo "⚠ plugin 是 binary-backed（${BINARY_HITS}）但 $PLUGIN_MANIFEST 沒有 binary_version / binaryVersion — binary 的 release 狀態與 release-ahead 都無法核對；補 pin 是手動步驟（Case B no-pin 會問）"
fi
if [ -n "$BINARY_VERSION" ]; then
    BINARY_UNRELEASED=unknown; BINARY_UNKNOWN_WHY=no-clone
    BINARY_REPO_PATH=$(detect_binary_repo "$BINARY_REPO") || BINARY_REPO_PATH=""
    if [ -d "$BINARY_REPO_PATH" ] && git -C "$BINARY_REPO_PATH" rev-parse -q --verify "refs/tags/v$BINARY_VERSION" >/dev/null 2>&1 \
       && git -C "$BINARY_REPO_PATH" rev-parse -q --verify main >/dev/null 2>&1; then
        BINARY_UNRELEASED=$(git -C "$BINARY_REPO_PATH" log "v$BINARY_VERSION..main" --oneline 2>/dev/null | wc -l | tr -d ' ')
        BINARY_UNKNOWN_WHY=""
    fi
fi

# (e) Release ahead of pin（#22 第 3 點）：latest release tag 比 pin 新 → **正向** sync 信號（Case E：先問要不要 bump pin）。
# 這是 common-release-flow「release 完自動跑 plugin-update」鏈唯一需要的動作；此前沒有任何 phase 看這個方向
# （Phase 1.5 Signal 2 只看反方向：main 超前 release）。走 gh（帶認證、失敗回 rc）；取不到 → unknown：印一行、不阻擋、
# 不進 Case E——「查不到」不是「已是最新」。測試用 PBM_GH 注入 stub，不打網路。
RELEASE_LATEST=""; RELEASE_AHEAD=""
if [ "$IS_BINARY_BACKED" = true ] && [ -n "$BINARY_VERSION" ] && [ -n "$BINARY_REPO" ]; then
    RELEASE_LATEST=$(latest_release_version "$BINARY_REPO") || RELEASE_LATEST=""
    if [ -z "$RELEASE_LATEST" ]; then
        RELEASE_AHEAD=unknown; echo "ℹ 取不到 ${BINARY_REPO} 的 latest release（gh 未登入 / 網路 / 沒有 release）— release-ahead 信號未核對（不是「已是最新」）"
    else
        version_gt "$RELEASE_LATEST" "$BINARY_VERSION"; VG_RC=$?
        case "$VG_RC" in
          0) RELEASE_AHEAD=$RELEASE_LATEST ;;
          1) RELEASE_AHEAD=no ;;
          *) RELEASE_AHEAD=unknown; echo "ℹ latest release '${RELEASE_LATEST}' 與 pin '${BINARY_VERSION}' 不是 x.y.z 形，無法比較 — release-ahead 信號未核對" ;;
        esac
    fi
elif [ "$IS_BINARY_BACKED" = true ] && [ -n "$BINARY_VERSION" ]; then
    RELEASE_AHEAD=unknown; echo "ℹ 抽不到 $PLUGIN_DIR 的 binary repo（bin/ 與 hooks/ 沒有 *_REPO= 賦值或 release URL 字面）— release-ahead 信號未核對"
fi

# ── Step 3 + Step 4 的判定在同一個 shell 完成（值不跨 fence）；印出 Case 與數字，
#    Step 4 只依這一行派發。Case A 的 abort 也在這裡。順序 E → C → B → A：pin 落後 release 時先問 bump，
#    否則 Case C 會帶著舊 pin 把 shell 同步出去（che-keychain 0.3.0 的實況，#22）。
#    unattended（IDD_ALL_UNATTENDED=1）下 E **不 abort**：印一行 AUDIT、pin 不動、照 shell 信號分類——release 剛發完正是
#    common-release-flow 自動跑 plugin-update 的時刻，讓它因為 pin 落後而整個中止等於自動鏈永遠做不完（#22 verify R1）。──
if [ "$MP_DRIFT" = "yes" ] || [ -n "$SHELL_RECENT_TOUCHES" ] || [ -n "$SHELL_DIRTY" ] || [ -n "$SHELL_UNPUSHED" ]; then SHELL_CASE=C
elif [ "$BINARY_UNRELEASED" = unknown ]; then SHELL_CASE=B          # 查不到 → 交給使用者，不當 0
elif [ "${BINARY_UNRELEASED:-0}" -gt 0 ] 2>/dev/null; then SHELL_CASE=B
else SHELL_CASE=A; fi
SYNC_CASE=$SHELL_CASE
if [ -n "$RELEASE_AHEAD" ] && [ "$RELEASE_AHEAD" != no ] && [ "$RELEASE_AHEAD" != unknown ]; then
    if [ "${IDD_ALL_UNATTENDED:-}" = 1 ]; then
        echo "AUDIT: Phase 0.3 pin v${BINARY_VERSION} (${BINARY_PIN_KEY}) behind latest release v${RELEASE_AHEAD} of ${BINARY_REPO} — not bumped under unattended; continuing as Case ${SHELL_CASE}"
    else SYNC_CASE=E; fi
fi
echo "→ Phase 0.3 sync intent: Case $SYNC_CASE — marketplace=${MP_VERSION:-<missing>} plugin.json=$SHELL_VERSION drift=$MP_DRIFT recent_touches=$(printf '%s' "$SHELL_RECENT_TOUCHES" | grep -c .) dirty=$DIRTY_N unpushed_here=$UNPUSHED_N repo_unpushed=$REPO_UNPUSHED upstream=$UPSTREAM binary=${BINARY_VERSION:-none}${BINARY_PIN_KEY:+ key=$BINARY_PIN_KEY} unreleased=${BINARY_UNRELEASED:-n/a}${BINARY_UNKNOWN_WHY:+ why=$BINARY_UNKNOWN_WHY} binary_repo=${BINARY_REPO_PATH:-none} repo=${BINARY_REPO:-none} latest=${RELEASE_LATEST:-n/a} release_ahead=${RELEASE_AHEAD:-n/a}"
case "$SYNC_CASE" in
  E)
    echo "→ Phase 0.3: latest release v${RELEASE_AHEAD} of ${BINARY_REPO} is newer than the pinned binary v${BINARY_VERSION} in $PLUGIN_MANIFEST (key: ${BINARY_PIN_KEY}; plugin version: ${SHELL_VERSION}) — Step 4 Case E asks whether to bump the pin"
    exit 0 ;;
  A)
    echo "✗ Phase 0.3: Nothing to sync."
    echo "  - marketplace.json @ ${MP_VERSION:-<missing>} matches plugin.json @ $SHELL_VERSION"
    echo "  - no plugin file changes in last 30 days; no uncommitted changes under the plugin dir / marketplace.json; no unpushed commit touching them"
    if [ -n "$BINARY_VERSION" ]; then echo "  - binary v$BINARY_VERSION: 0 unreleased commits on main（本機 clone 與 tag 皆核對過）"
    else echo "  - not binary-backed（無 .mcp.json / bin 或 hooks 的 release URL / binary pin；無 binary 可核對）"; fi
    [ "$RELEASE_AHEAD" = no ] && echo "  - latest release v${RELEASE_LATEST} of ${BINARY_REPO} is not newer than the pin (${BINARY_PIN_KEY})"
    [ "$RELEASE_AHEAD" = unknown ] && echo "  - release-ahead check could not run（見上方 ℹ）— pin 是否落後 latest release 未核對"
    echo ""
    # MP_DRIFT 比的是本機的兩個 JSON，跟 remote 無關：repo 還有未推送 commit 時，刷 cache 抓到的仍是舊版（#19 R2）
    if [ "$REPO_UNPUSHED" = 0 ]; then
        echo "  If you intended to force a marketplace cache refresh anyway (repo has 0 unpushed commits vs $UPSTREAM),"
        echo "  bypass plugin-update and run: claude plugin marketplace update $MP_NAME"
    else
        echo "  Note: this repo has $REPO_UNPUSHED unpushed commit(s) vs $UPSTREAM that do not touch this plugin or marketplace.json —"
        echo "  this run stops here, so Phase 0.5 Step 5's cross-plugin warning will NOT run for them; push them first if a cache refresh is what you want."
    fi
    remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"   # 本次 invocation 到此結束
    exit 0 ;;
  C)
    echo "→ Phase 0.3: sync intent confirmed"
    [ "$MP_DRIFT" = "yes" ] && echo "  - marketplace.json drift: ${MP_VERSION:-<missing>} → $SHELL_VERSION"
    [ -n "$SHELL_RECENT_TOUCHES" ] && echo "  - recent shell changes: $(printf '%s\n' "$SHELL_RECENT_TOUCHES" | grep -c .) files"
    [ -n "$SHELL_DIRTY" ] && echo "  - uncommitted changes under the plugin dir / marketplace.json: $DIRTY_N status entries（attended 時 Phase 0.5 會問要不要 commit，unattended 則 auto-abort）"
    [ -n "$SHELL_UNPUSHED" ] && echo "  - unpushed commits touching this plugin / marketplace.json: ${UNPUSHED_N}（Phase 0.5 會依優先序表分類——B / D / E——後問要不要 push；unattended 則 auto-abort）"
    if [ "$BINARY_UNKNOWN_WHY" = no-pin ]; then echo "  - binary-backed but no binary_version / binaryVersion pinned in $PLUGIN_MANIFEST — release status not checked（補 pin 後重跑才會有 Case E 的 release-ahead 檢查）"
    elif [ "$BINARY_UNRELEASED" = unknown ]; then echo "  - binary v$BINARY_VERSION: unreleased-commit check could not run（no local clone / tag / main）— see Phase 1.5"; fi
    [ "$RELEASE_AHEAD" = unknown ] && echo "  - release-ahead check could not run（見上方 ℹ）— pin 是否落後 latest release 未核對"
    [ "${BINARY_UNRELEASED:-0}" -gt 0 ] 2>/dev/null && echo "  - binary main has $BINARY_UNRELEASED unreleased commits (see Phase 1.5 for warn detail)"
    exit 0 ;;
  B)
    if [ "$BINARY_UNKNOWN_WHY" = no-pin ]; then
      echo "→ Phase 0.3: binary-backed but $PLUGIN_MANIFEST pins no binary_version / binaryVersion — release status cannot be checked; shell unchanged, marketplace in sync — Step 4 Case B (unknown / no-pin) asks"
    elif [ "$BINARY_UNRELEASED" = unknown ]; then
      echo "→ Phase 0.3: binary v$BINARY_VERSION could not be checked (no local clone / tag / main${BINARY_REPO_PATH:+; clone found at $BINARY_REPO_PATH}); shell unchanged, marketplace in sync — Step 4 Case B (unknown / no-clone) asks"
    else
      echo "→ Phase 0.3: binary main has $BINARY_UNRELEASED unreleased commits since v$BINARY_VERSION; shell unchanged, marketplace in sync — Step 4 Case B asks"
    fi
    exit 0 ;;
esac
```

> **`detect_binary_repo` heuristic**：從 wrapper script 抓 `GITHUB_REPO`（e.g. `PsychQuant/che-apple-mail-mcp`），然後在常見路徑下找 local clone：`$HOME/Developer/<repo>` / `$HOME/Developer/che-mcps/<repo>` / `$HOME/code/<repo>`。找不到就跳過 binary-repo-drift 信號（不 fail-stop — 信號是 best-effort）。

### Step 3: Sync intent 判斷

把 Step 2 收集到的信號濃縮成「真的有東西要 sync 嗎？」的 boolean：

| 信號命中 | sync intent | 解讀 |
|---------|------------|------|
| marketplace.json 版本落後 plugin.json (`MP_DRIFT=yes`) | YES | shell 已 bump 但 marketplace 沒同步 — 經典 plugin-update use case |
| 30 天內有 plugin 檔案 commits（`SHELL_RECENT_TOUCHES` 非空）| YES | shell 真的有改動 |
| plugin 目錄或 marketplace.json 有未提交改動（`SHELL_DIRTY` 非空）| YES | 改完還沒 commit——本 skill 的主要情境；attended 時 Phase 0.5 Case C/D 會問怎麼 commit |
| 有未推送 commit 動到 plugin 目錄或 marketplace.json（`SHELL_UNPUSHED` 非空）| YES | 上次 push 失敗 / 手動 commit 未推；Phase 0.5 依優先序表分類（clean → B、dirty → D、分歧 → E）後問要不要 push |
| Binary repo `main` 超前 last release ≥ 1 commits | MAYBE | 提示「binary 有 unreleased commits — 是不是該先 mcp-deploy / release？」|
| latest release tag 比 manifest 的 binary pin 新（`RELEASE_AHEAD=<x.y.z>`，#22）| **YES（Case E，先問）** | release 剛發、pin 還是舊的——common-release-flow 的自動鏈就是為這一步存在；先問 bump，bump 後回 Step 2 重跑（落到 Case C）|
| 全部都沒命中 | **NO** | nothing to sync — short-circuit abort |

### Step 4: AskUserQuestion 5-case dispatch（順序 E → C → B → A；D 是 unattended 的覆蓋規則）

#### Case A: Nothing to sync → abort

當 (a) `MP_DRIFT=no` AND (b) `SHELL_RECENT_TOUCHES` 為空 AND (b') `SHELL_DIRTY` 為空（plugin 目錄與 marketplace.json 無未提交改動）AND (b'') `SHELL_UNPUSHED` 為空（無未推送 commit 動到它們）AND (c) `BINARY_UNRELEASED` 是**核對過的** 0 或空（純 shell plugin；查不到算 unknown，走 Case B）AND (d) `RELEASE_AHEAD` 不是版本號（`no` / `unknown` / 空；是版本號就是 Case E）：

訊息與 `exit 0` 由 Step 2 的 fence 在同一個 shell 印出（值不跨 fence）；agent 看到
`Case A` 那行就停止。

#### Case B: Binary 狀態是唯一信號 → AskUserQuestion

當 (a) `MP_DRIFT=no` AND (b) `SHELL_RECENT_TOUCHES` 為空 AND (b') `SHELL_DIRTY` 為空 AND (b'') `SHELL_UNPUSHED` 為空 AND (c) `BINARY_UNRELEASED` 是 `>= 1` **或 `unknown`**（查不到不是 0，#18）。四個 shell 信號任一命中都是 Case C，不是 Case B。
Step 2 那行 `unreleased=… why=…` 決定用哪個問句模板——三個子態的正確處置不同，套錯模板就是給錯處方：

**B-count**（`unreleased=<N>`，N ≥ 1）：

```
question: "Binary repo `main` 累積 <Step 2 印出的 unreleased> 個未 release 的 commits (last release: v<Step 2 印出的 binary>)。Shell 沒改、marketplace.json 已同步。怎麼處理？"
options:
  - "abort, release binary first (default, recommended)"
    description: "exit; cd <Step 2 印出的 binary_repo>; ./scripts/release.sh v<next>; 完成後 bump plugin.json binary_version + 重跑 plugin-update"
  - "proceed anyway (force shell sync only)"
    description: "略過 binary release 提醒，繼續走 Phase 0.5+ 同步 shell（binary 仍是舊版）— 只適合純 documentation / shell-side bug fix 的情境"
  - "abort"
    description: "exit; 不動 anything"
```

**B-unknown / no-pin**（`unreleased=unknown why=no-pin`：plugin 是 binary-backed，但 plugin.json 沒宣告 `binary_version` / `binaryVersion`。沒有東西可 release、release-ahead 也無從比較，該做的是補 pin——補 pin 是手動步驟：Case E 的 bump fence 只改既有的 key）：

```
question: "<plugin> 是 binary-backed，但 plugin.json 沒有 binary_version / binaryVersion，無法核對 binary 是否已 release。Shell 沒改、marketplace.json 已同步。怎麼處理？"
options:
  - "proceed anyway (shell sync only)"
    description: "繼續 Phase 0.5+ 同步 shell；binary 狀態未核對（不是「已核對沒問題」）"
  - "abort, pin binary_version first (recommended)"
    description: "exit; 在 plugin.json 補 binary_version（wrapper 實際下載的那個 release tag；wrapper 若讀 binaryVersion 就用那個 key），再重跑 plugin-update——之後 Phase 0.3 (e) 會拿它跟 latest release 比"
  - "abort"
    description: "exit; 不動 anything"
```

**B-unknown / no-clone**（`unreleased=unknown why=no-clone`：有 pin，但本機沒有 clone / tag / `main` 可比對）：

```
question: "plugin.json pin 了 binary v<Step 2 印出的 binary>，但本機找不到可核對的 clone / tag / main（binary_repo=<Step 2 印出的 binary_repo>），無法確認 main 是否有未 release 的 commits。Shell 沒改、marketplace.json 已同步。怎麼處理？"
options:
  - "proceed anyway (shell sync only)"
    description: "繼續 Phase 0.5+ 同步 shell；binary 狀態未核對"
  - "abort, fetch tags / clone first (recommended)"
    description: "exit; 在 binary repo 跑 git fetch --tags（或先 clone 到 ~/Developer/<repo>），再重跑 plugin-update"
  - "abort"
    description: "exit; 不動 anything"
```

三個模板的任何 abort 選項 → exit 0，並先 `remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"`（帶前導的一行 fence，同 Phase 0.5 Step 3）——留著的 context 會讓下一次執行從中途接上。只有 `proceed` 保留 context（Phase 0.5 之後每個 fence 都要載它）。
選 `proceed anyway` → 繼續 Phase 0.5。

#### Case E: Latest release 比 pin 新 → AskUserQuestion bump（#22）

當 Step 2 那行印 `release_ahead=<x.y.z>`（不是 `no` / `unknown` / `n/a`）。**E 先於 C**：release 剛 push、manifest 的 pin 還是舊版時，四個 shell 信號多半也命中（release 前通常改過 shell），落到 Case C 會把舊 pin 連同 shell 一起同步出去——che-keychain 0.3.0 就是這樣：`binaryVersion` 停在 0.2.0、latest tag 已是 v0.3.0、沒有任何 phase 說「pin 落後」（#22 第 3 點）。

```
question: "<Step 2 印出的 repo> 的 latest release 是 v<release_ahead>，但 <PLUGIN_MANIFEST> 的 binary pin（<key>）還是 v<binary>；plugin version 目前是 <plugin version>。要 bump pin 嗎？"
options:
  - "bump pin 到 v<release_ahead>（只改 <key>，plugin version 不動）(default)"
    description: "適合 binary 與 plugin shell 各自版號的 plugin（#77 schema：binary_version 獨立於 version）。key 是 version 時這一項就是改 version"
  - "bump pin 與 plugin version 一起到 <release_ahead>"
    description: "兩個欄位同版；適合 che-keychain 這類 version == binaryVersion 慣例的 plugin。fence 會拒絕把 version 改低（release 0.3.0 對上 version 2.0.0 不是 bump 是降版）"
  - "proceed without bumping（pin 維持 v<binary>，本次只同步 shell）"
    description: "刻意 pin 舊版（新版有 regression）或 binary 節奏快於 plugin 時用；release-ahead 會記進 Phase 5 report，不會靜默"
  - "abort"
    description: "exit; 不動 anything（先 remove_plugin_ctx）"
```

選 bump（前兩項）→ 跑下面的 fence（代入兩個值），然後**回 Step 2 重跑**：此時 `SHELL_DIRTY` 非空 → Case C → Phase 0.5 Case C/D 會問怎麼 commit。不在這裡 commit——commit 是 Phase 0.5 的事。
選 `proceed without bumping` → 同 Case B 的 proceed：context 保留，依 Step 2 印出的 shell 信號走（有信號 → Phase 0.5；全空 → 等同 Case A，印一句後 abort），Phase 5 report 的 Phase 0.3 列寫 `E → not bumped`。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
# 兩個代入值：NEW_PIN 是 Step 2 印出的 release_ahead（來自 gh，仍過 allowlist）；ALSO_VERSION 是使用者選了第二個選項才 yes
NEW_PIN='<release_ahead-from-step-2>'
ALSO_VERSION='no'
case "$NEW_PIN" in ''|'<release_ahead-from-step-2>'|.*|-*|*[!0-9A-Za-z.+-]*) echo "✗ NEW_PIN 未代入或不合法（只接受 [0-9A-Za-z.+-]）" >&2; exit 1 ;; esac
case "$ALSO_VERSION" in yes|no) ;; *) echo "✗ ALSO_VERSION 只能是 yes 或 no" >&2; exit 1 ;; esac
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ Case E: $PLUGIN_DIR 沒有 plugin manifest" >&2; exit 1; }
# 寫回保留檔案原本的 key（binary_version / binaryVersion / version——Step 2 印出的 key）：che-keychain / che-transport-mcp 的
# wrapper 讀的是 binaryVersion，改名會弄壞它們；兩個 pin key 都有時以 binary_version 為準（印出來）
PBV=$(plugin_binary_version_effective "$PLUGIN_MANIFEST"); PBV_RC=$?
case "$PBV_RC" in 0) ;; 3) echo "✗ Case E: $PLUGIN_MANIFEST 的 pin 值含非法字元 — 先手動修好再重跑 Step 2" >&2; exit 1 ;; *) echo "✗ Case E: 讀不到 $PLUGIN_MANIFEST 的 pin（rc ${PBV_RC}）— Case E 只在有 pin 時出現；回 Step 2 重跑" >&2; exit 1 ;; esac
OLD_PIN=${PBV%%|*}; KEY=${PBV#*|}
[ "$(plugin_binary_version_key "$PLUGIN_MANIFEST"; echo "rc=$?")" != "binary_version
rc=2" ] || echo "⚠ $PLUGIN_MANIFEST 同時有 binary_version 與 binaryVersion — 只改 binary_version，另一個留著（請手動清掉一個）"
CUR_VERSION=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("version"); print(v if isinstance(v,str) else "")' "$PLUGIN_MANIFEST" 2>/dev/null)
if [ "$KEY" = version ] && [ "$ALSO_VERSION" = yes ]; then echo "ℹ pin 就是 version 欄位本身；「一起 bump」與「只 bump pin」在這個 plugin 上是同一件事"; ALSO_VERSION=no; fi
# 「一起 bump」只證明 release > pin，沒證明 release > plugin version：version 2.0.0 對上 release 0.3.0 是降版，不是 bump（#22 verify R1）
if [ "$ALSO_VERSION" = yes ] && [ -n "$CUR_VERSION" ]; then
    version_gt "$CUR_VERSION" "$NEW_PIN"; VG_RC=$?
    [ "$VG_RC" = 0 ] && { echo "✗ Case E: plugin version ${CUR_VERSION} 比目標 ${NEW_PIN} 新 — 「一起 bump」會把 version 降版；改選「只 bump pin」或 abort" >&2; exit 1; }
    [ "$VG_RC" = 2 ] && { echo "✗ Case E: plugin version '${CUR_VERSION}' 與 '${NEW_PIN}' 不是 x.y.z 形，無法確認不是降版 — 改選「只 bump pin」或手動改" >&2; exit 1; }
fi
python3 - "$PLUGIN_MANIFEST" "$KEY" "$NEW_PIN" "$ALSO_VERSION" <<'PY'
import json, sys
path, key, new, also = sys.argv[1:5]
d = json.load(open(path))          # dict 保序；indent=2 是本 repo 所有 plugin.json 的縮排
d[key] = new
if also == "yes":
    d["version"] = new
with open(path, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
echo "→ Phase 0.3 Case E: $PLUGIN_MANIFEST ${KEY}: ${OLD_PIN} → $(plugin_binary_version_effective "$PLUGIN_MANIFEST" | cut -d'|' -f1); version: $([ "$ALSO_VERSION" = yes ] && printf '%s' "$NEW_PIN" || printf '%s (unchanged)' "${CUR_VERSION:-?}")"
git --literal-pathspecs diff --stat -- "$PLUGIN_MANIFEST"
echo "→ 回 Phase 0.3 Step 2 重跑（會落到 Case C；Phase 0.5 會問怎麼 commit 這個改動）"
```

選 `abort` → 同 Case B 的 abort：先 `remove_plugin_ctx`，exit 0。

**unattended（`IDD_ALL_UNATTENDED=1`）**：Step 2 的 fence 自己處理——不進 Case E、不改 manifest、印一行 `AUDIT: Phase 0.3 pin vY (<key>) behind latest release vX of <repo> — not bumped under unattended; continuing as Case <C|B|A>`，然後照 shell 信號的 case 走（Phase 5 Step 3 的 report 原樣收錄這一行）。要不要 bump 是人的裁決，但「不裁決」不等於「不能同步 shell」：release 剛發完正是 common-release-flow 自動跑 plugin-update 的時刻，在這裡 abort 會讓自動鏈永遠做不完。

#### Case C: Sync intent confirmed → 通過 0.3，直接進 0.5

當 `MP_DRIFT=yes` OR `SHELL_RECENT_TOUCHES` 非空 OR `SHELL_DIRTY` 非空 OR `SHELL_UNPUSHED` 非空（與 Step 2 fence 的 `SYNC_CASE=C` 判定同一條）：正常 sync use case，print 簡短摘要後進入 Phase 0.5。

摘要由 Step 2 的 fence 印出（`→ Phase 0.3: sync intent confirmed` 與逐項數字）；agent 看到
`Case C` 那行就進 Phase 0.5。

#### Case D: idd-all unattended → auto-decide

當 plugin-update 在 `idd-all` orchestrator 下 invoke：
- Nothing to sync (Case A) → 同樣 abort（idd-all 在最終 report 標 "plugin-update skipped: no sync intent"）
- Binary 狀態是唯一信號 (Case B，含 unknown 兩個子態) → auto-abort（unattended 不該 force shell sync，也不該把「未核對」當「沒問題」）+ structured error，並 `remove_plugin_ctx`
- Latest release 比 pin 新 (Case E) → **不 abort**：pin 不動、印 `AUDIT: Phase 0.3 pin … behind latest release … — not bumped under unattended`，照 shell 信號的 case（C / B / A）繼續——要不要 bump 是人的裁決，但 abort 會讓 release 後的自動鏈永遠做不完（#22）
- Sync intent confirmed (Case C) → 繼續 Phase 0.5（0.5 自己有 unattended handler）

設計同 Phase 0.5 Step 4：**需要人裁決的 case** 在 unattended mode 統一走 abort + audit trail；沒有裁決點的 case 通過（Phase 0.5 的 Case A clean start；E' pure behind 是 ff-only 後重測，重測落到哪個 case 就照那個 case）。

---

## Phase 0.5: Git State Preview & Confirmation Gate（v1.16.0+ #60）

> **為什麼這 phase 在 Phase 1 之前**:Phase 1+ 會 `git add` / `git commit` / `git push` / `claude plugin marketplace update`,在那之前,user 必須對樹上**既有**的變更（未提交 / 未推送 / 分歧，Case B–E）明確表態要不要一起推。clean start（Case A）沒有裁決點，直接通過（#19）——這代表在 clean start 下（含 unattended）**以下動作不經人工確認就會發生（封閉列舉，不得類推）**：(1) Phase 2 對 `.claude-plugin/marketplace.json` 的鏡像 commit + push——只在該檔的 entry 版本已等於 plugin.json 且相對 HEAD 有變更時，push 前列出視窗內混進的 commit 與其 plugin 歸屬；(2) Phase 3 `claude plugin marketplace update`（重拉 plugin index）；(3) Phase 4 `claude plugin update` / `install`（把 plugin 程式碼裝進本機；binary-backed plugin 的 wrapper 下次啟動會自動下載 release binary）。#19 之前 unattended 在 Phase 0.5 一律 abort，這三項從未在無人看管下執行過；現在它們是 common-release-flow 自動鏈刻意要的行為。其餘兩道互動閘在 unattended 下：**仍會 abort** 的只有 Phase 1.5 Step 4（binary 不同步）；Phase 2.5 Step 2（README stale）**不 abort**，自動「先略過」繼續 Phase 3，並印一行 `AUDIT:` 供 Phase 5 的最終 report 收錄。
>
> 既有 (pre-v1.16.0) 行為:Phase 1 Step 2 印出 `git status` 後接 narrative reminder text 「請先 commit + push」,但**沒實際 gate**,AI executor 可以印 reminder 後繼續。新 phase 把這個決定升格成 **AskUserQuestion** explicit dispatch,跟 skill 內既有 [Phase 1.5: External Binary Dependency Check](#phase-15-external-binary-dependency-check若有) + [Phase 2.5: README Freshness Check](#phase-25-readme-freshness-check) 同 pattern(用 section refs 而非 line numbers,避免後續 insert 後 stale)。
>
> **Relationship to IDD `pr_policy`**:`pr_policy` 控制 development-time PR-vs-direct-commit 決定(during `idd-implement`)。Phase 0.5 控制 release-time push-or-abort 決定(during `plugin-update`)。**Different lifecycle moments;Phase 0.5 不 consult / 不 override `pr_policy`**。

> **這道 gate 問的是什麼（#19）**：不是「有沒有東西要推」，而是「樹上**既有**、不屬於本次 sync 的東西要不要一起推」。Phase 2 若 marketplace.json 落後 plugin.json，會自己產生並 push 鏡像 commit（Phase 2 不 bump plugin.json——那是使用者或 release 流程做的），那個變更在 0.5 這個時間點**還不存在**——所以「樹乾淨、0 既有未推送」是最乾淨的起始狀態，不是「沒事可做」。#19 之前 Case A 對這個狀態 abort 並建議「bypass plugin-update 直接跑 marketplace update」，在 marketplace.json 還沒 bump 時那是錯的指引（2026-08-31 che-apple-mail-mcp 3.0.0：30 天內改過 ∧ 樹乾淨，0.3 Case C「繼續」與 0.5 Case A「exit 0」同時成立）。0.3 看歷史（該不該 sync）、0.5 看當下（既有的髒東西怎麼辦），兩者判準正交，各自只回答自己的問題。

### Step 1: Read-only Preview Block

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1

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
| 6 (lowest) | **Clean start** (Case A) — 通過，不 dispatch | divergence `0 0` AND `git status --short` empty：沒有既有變更需要裁決；Phase 2 若 marketplace.json 有落差會自行 commit + push |

> **Why divergence wins** (priority 1-2 first):dirty + diverged 同時成立時,先處理 divergence(無法 push 在落後的 branch);user 可以 fetch + rebase 後再決定 dirty 怎麼處理。原 draft 把 dirty 跟 diverged 並列導致雙重匹配,新版用 priority order 消除歧義。
>
> **Pure-behind (Case E') 是新增 case** — origin 比 local 多 commits 但 local 無 unpushed,這是 `git pull --ff-only` 的乾淨情境;原 draft 漏列。

**Edge cases all → abort with structured error**(由 Step 1 preview block 的開頭 guard 處理):
- Detached HEAD → already aborted in Step 1
- No upstream tracking → already aborted in Step 1
- Incomplete rebase / merge / cherry-pick → already aborted in Step 1

### Step 3: AskUserQuestion Dispatch（Case B–E；Case A 通過、E\' ff-only 後重測）

任何一個選項導致 abort（exit 而不進 Phase 1）時，先 `remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"`（帶前導的一行 fence）——留著的 context 會讓下一次執行從中途接上而跳過 Step 0.1 的 gate。**這條規則的範圍是 Phase 0.3 與 Phase 0.5 的 abort 選項、Phase 1.5 Step 4 的「中止」，以及 Phase 5 的正常收尾**（封閉列舉）；Phase 2 / 2.5 / 3 中途停住（例如 `claude plugin marketplace update` 失敗）不清，由載入端的 6 小時 TTL 兜底——那些點 agent 每次都會從 Step 0.1 重跑、Step 0.1 會覆寫。

依 detected state 跑對應的 AskUserQuestion（Case A 不問、Case E' 先 `git pull --ff-only` 再重測 Step 2）。**Default option = `abort` for any state with multiple sensible actions**;`push as-is` 只在 unambiguous clean+unpushed case 是 default。

**任何 push 選項在執行 push fence 之前，先跑 Step 5 的 cross-plugin 檢查**（push 之後 `$UPSTREAM..HEAD` 就是空集合，Step 5 會誤報「沒碰任何 plugin」，#18 R9）。Case A 路徑上唯一的 push 是 Phase 2 Step 4 自己的：它的 fence 在有混進來的 commit 時做同一段 `plugin_names_for_paths` 歸屬分析後才 push（#19 R2）。

**選項裡的 commit / push 動作一律用下面兩個 fence 執行，不在對話裡現組 `git push`**：Step 1 的
`cd "$MP_ROOT"` 到這個 Bash 呼叫已經失效，現組的 git 會跑在 session 的 cwd——那正是 Step 0.1
存在理由裡的那個災害（推了不相干的 repo）。兩個 fence 都帶前導，git 因此在 marketplace repo 內跑；
push 用 `git push`（Step 1 已確認 upstream 存在），不代入 branch 名。

```bash
# Case C「stage all + commit + push」/ Case D「amend」「commit dirty as new commit」的 commit 半段。
# COMMIT_MSG 是使用者在 AskUserQuestion 後給的訊息（自己的引數）；AMEND=yes 走 --amend --no-edit。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# commit message 走 quoted heredoc → 檔案 → `git commit -F`：訊息裡的單引號是常態（don't、plugin's），
# 不能放進單引號常值；quoted delimiter 不展開任何東西，唯一的逃逸是一整行恰等於 MSGEOF（#18 R9）
AMEND='<yes-or-empty>'
case "$AMEND" in yes) : ;; *) AMEND="" ;; esac
MSGF=$(mktemp) || exit 1
cat > "$MSGF" <<'MSGEOF'
<commit-message-or-empty>
MSGEOF
git add -A -- "$MP_ROOT"   # pathspec 收斂到 marketplace root：巢狀在外層 repo 的 marketplace 不得把外層一起 stage
if [ -n "$AMEND" ]; then git commit --amend --no-edit
elif grep -qv '^<commit-message-or-empty>$' "$MSGF" && grep -q . "$MSGF"; then git commit -F "$MSGF"
else echo "✗ 需要 commit message" >&2; rm -f "$MSGF"; exit 1; fi
rm -f "$MSGF"
```

```bash
# 任一「push」選項的 push 半段（Case B「push N as-is」、Case C/D 的 push、Case E rebase/merge 之後）。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
git push && echo "→ Phase 0.5: pushed $(git rev-parse --abbrev-ref HEAD) in $MP_ROOT"
```

#### Case A: Clean start — 通過

不需要 dispatch，也**不是 abort**（#19）：樹上沒有任何既有的、需要裁決的變更；本次要推的 sync commit 由 Phase 2 自己產生並 push。印一行就進 Phase 1（context 保留，後面每個 fence 都要載它）：

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# 這行不是宣告，是量測：Case A 誤判的代價從「exit 0 不做事」變成「放行 → Phase 2 push」（#19 R2），
# 所以 fence 自己重驗，不符就退回 Step 2 重新分類（fail-safe）
# Case A 的定義是三條件：divergence `0 0`（behind 與 ahead 皆 0）∧ 樹乾淨——三條都驗，純 behind（E'）也要拒絕
DIV=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) || { echo "✗ Phase 0.5 Case A: 沒有 upstream — Step 1 應已 abort" >&2; exit 75; }
BEHIND=${DIV%%[[:space:]]*}; AHEAD=${DIV##*[[:space:]]}
if [ -n "$(git status --porcelain)" ] || [ "$AHEAD" != 0 ] || [ "$BEHIND" != 0 ]; then
    echo "✗ Phase 0.5: 這不是 Case A — status entries: $(git status --porcelain | grep -c .), behind: ${BEHIND}, ahead: ${AHEAD}。回 Step 1 重跑 preview、依 Step 2 優先序表重新分類（behind>0 → E'；其餘 B–E 要問，unattended 則照 B–E abort）。" >&2
    exit 75
fi
echo "→ Phase 0.5: clean tree, divergence 0 0 (verified) — nothing to gate; Phase 2 will mirror marketplace.json (commit + push only if it changes)"
```

> #19 之前這裡 `exit 0` 並建議「bypass plugin-update 直接跑 `claude plugin marketplace update`」——marketplace.json 還沒 bump 時，那條指令抓到的仍是舊版本。

#### Case B: Clean + N unpushed → AskUserQuestion

```
question: "$N unpushed commits on $BRANCH. Push them to origin and proceed with marketplace sync?"
options:
  - label: "push N as-is (default)"
    description: "push（用下方 push fence）→ continue to Phase 1+"
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
    description: "push（用下方 push fence）→ continue (dirty stays uncommitted)"
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
    description: "sync fence（MODE=rebase：git fetch + git rebase @{u}，linear history）→ push fence → continue (may have conflicts)"
  - label: "fetch + merge + push"
    description: "sync fence（MODE=merge：git fetch + git merge @{u}）→ push fence → continue (may have conflicts)"
```

#### Case E': Pure behind → ff-only 後重測

沒有裁決點：`git pull --ff-only` 不會改寫任何本地 commit——但它會把 upstream 上任何人推的內容拉進本機工作樹，而重測落到 Case A 時同一次 unattended run 會接著跑 Phase 3 / 4 把它裝進本機；這是 E' 在 unattended 下的實際範圍。成功後 fence 自己印出新的 divergence / status 當作新 preview，**回 Step 1 重跑 preview block、再依 Step 2 優先序表重新分類**——結果可能是 Case A（繼續）也可能是 C / D（髒樹，要問；unattended 則 abort）。**每次 invocation E' 最多走一次**：重測仍是 E'（代表 pull 與重測之間 upstream 又前進了）即 abort。ff-only 失敗（髒樹擋住、或其實有分歧）就 abort，**不重試**（attended / unattended 相同；unattended 沒有人喊停）：

```bash
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
if git pull --ff-only; then
    echo "→ Phase 0.5 Case E': fast-forwarded to upstream. New preview — divergence (behind ahead): $(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null | tr '\t' ' '); status entries: $(git status --porcelain | grep -c .)"
    echo "   回 Step 1 重跑 preview、依 Step 2 重新分類；重測仍是 E' 就 abort（每次 invocation 最多一次）"
else remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"; echo "✗ Phase 0.5 Case E': ff-only 失敗（髒樹擋住或已分歧）— 手動處理後重跑 plugin-update" >&2; exit 75; fi
```

預設 `abort` — conflict resolution 是 user 的工作,不是 skill 的。fetch / rebase / merge 同樣不在對話裡現組
（在錯的 repo 上 rebase 比 push 更糟：改寫本地歷史、可能留下 conflict 中斷態）：

```bash
# Case E 的 sync 半段；MODE 是使用者在 AskUserQuestion 選的（rebase / merge），@{u} 是 Step 1 驗證過的 upstream
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
MODE='<rebase-or-merge>'
case "$MODE" in rebase|merge) : ;; *) echo "✗ MODE 須為 rebase 或 merge" >&2; exit 1 ;; esac
git fetch && git "$MODE" '@{u}' && echo "→ Phase 0.5: $MODE onto upstream done in $MP_ROOT — 接著跑 push fence"
```

### Step 4: idd-all Unattended Mode Handler

當 plugin-update 在 `idd-all` orchestrator 下被 invoke(env var or args detect,e.g. `IDD_ALL_UNATTENDED=1`):

1. 仍跑 Step 1 preview block(printed for audit)
2. **封閉列舉，不得類推**：**Case A（clean start）通過**（#19：沒有需要人裁決的東西；common-release-flow 的自動鏈正是在乾淨樹上跑的）；**Case E'（pure behind）** 與 attended 相同：`git pull --ff-only` 後重測 Step 2（ff-only 不會改寫任何本地 commit）；**Case B / C / D / E → Auto-abort**（先 `remove_plugin_ctx`）with structured error:
   ```
   ✗ plugin-update Phase 0.5 cannot prompt under unattended mode.
     Detected state: $STATE.
     User must run /plugin-update <name> manually after IDD chain completes.
   ```
3. Case B–E 的 abort 回非零退出碼(e.g. 75 = "abort by gate")so `idd-all` 在 final report 標 "plugin-update skipped under unattended mode"；Case A 的 fence 自驗通過 → **不**回這個狀態、context 保留、繼續 Phase 1；**Case A 的 fence 自驗失敗**（exit 75，context 保留）→ 回 Step 1 重跑 preview、重新分類，落到 B–E 就照 B–E abort（此時才 `remove_plugin_ctx`）；Case E' 的 ff-only 成功後**回 Step 1 重跑 preview、重測落到哪個 case 就照那個 case 的規則**（A → 繼續；B–E → abort；仍是 E' → abort，每次 invocation 最多一次），ff-only 失敗 → abort（exit 75，不重試）

設計同 `idd-diagnose` Step 3.4 F unattended-mode pattern:auto-default to safe path + audit trail entry。**Plan tier 的 EnterPlanMode + plugin-update 的 Phase 0.5 Case B–E 都是 user-attendance-required gates**,unattended mode 統一走 abort + audit；Case A 通過之後，後面兩道互動閘各自有 unattended 分支——Phase 1.5 Step 4（binary 不同步 → auto-abort）與 Phase 2.5 Step 2（README stale → 自動「先略過」並在 report 標註）。

### Step 5: Cross-plugin Commits Warning（v1.16.0 Tier A:warn-only)

當 Step 3 選擇 `push N as-is` / `push N+1`,**在執行 push fence 之前**檢查 unpushed commits 有沒有 touch 預期外的 plugin / 完全沒 touch target plugin（push 之後 `$UPSTREAM..HEAD` 為空，本 step 只能在 push 前跑）。target 就是本次引數 `PLUGIN_NAME`（前導代入）；沒帶名稱的 invocation 先走 Phase 1 Step 1 的推斷、拿到名稱後再回來跑本 step。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
TARGET_PLUGIN="$PLUGIN_NAME"
# UPSTREAM 是 Step 1 那個 shell 的變數，這裡重算；空的 "$UPSTREAM"..HEAD 是 git 合法的空集合
# （rc 0、零輸出），會讓這道 gate 安靜地死掉（#18 R2）。
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
  || { echo "✗ no upstream tracking branch — Step 1 should have aborted" >&2; exit 1; }

# 收集 unpushed commits touch 到的 plugin 名(去重)——經 manifest 對映，不猜 plugins/<x>/ 佈局
# （單一 plugin marketplace 的檔案在 plugin/ 底下；repo 即 plugin 的佈局擁有全部路徑，
# 所以 root-sourced plugin 對任何 commit 都算被 touch——那是佈局語意，case (a) 對它不成立。#18）
# plugin_names_for_paths 對解析不到的名稱只在 stderr 警告、不計入：那些是「未知」，不是「沒動到」——
# 收下 stderr 算出數量，有就升成本 gate 自己的警告並走 case (c)（#18 R9）
PNP_ERR=$(mktemp) || exit 1
TOUCHED=$(git -c core.quotePath=false -c diff.relative=false log --name-only --pretty=format: "$UPSTREAM"..HEAD \
  | plugin_names_for_paths "$MP_ROOT" 2>"$PNP_ERR")
TOUCHED_COUNT=$(echo -n "$TOUCHED" | grep -c . || true)
UNRESOLVED=$(grep -c 'did not resolve' "$PNP_ERR" || true); UNRESOLVED_NAMES=$(grep -o "'[^']*' did not resolve" "$PNP_ERR" | cut -d"'" -f2 | tr '\n' ' ')
rm -f "$PNP_ERR"

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
elif [ "$TOUCHED_COUNT" = "1" ] && [ "$TOUCHED" = "$TARGET_PLUGIN" ] && [ "${UNRESOLVED:-0}" = "0" ]; then
    : # Happy path — single-plugin commit matching target. No warning.
else
    # Cross-plugin or wrong target
    echo "⚠ Heads-up: unpushed commits touch plugin(s) other than (or in addition to) target '$TARGET_PLUGIN':"
    echo "$TOUCHED" | sed 's/^/   - /'
    echo "   Pushing will publish all of them via marketplace update."
    echo "   (warn-only; active scope guard 留給 follow-up issue #65 處理)"
fi
[ "${UNRESOLVED:-0}" = "0" ] || echo "⚠ Heads-up: $UNRESOLVED plugin name(s) touched by these commits could NOT be resolved（${UNRESOLVED_NAMES}）— 它們是「未知」，不是「沒動到」；push 會一併發佈它們的變更。修那些 entry 的 source 或 manifest 再判斷。"
echo "→ Phase 0.5 Step 5: $TOUCHED_COUNT plugin(s) touched by $(git rev-list --count "$UPSTREAM"..HEAD) unpushed commit(s)${TOUCHED:+: $(printf '%s' "$TOUCHED" | tr '\n' ' ')}; unresolved=${UNRESOLVED:-0}"
```

**Tier A scope = warn-only(3 cases:empty / happy / cross-plugin)**;**Tier C scope guard(active 拒絕 push,refuse + suggest interactive rebase)留給 follow-up issue #65 處理**。

### Step 6: Pass to Phase 1

通過 Phase 0.5 gate（clean start 直接通過，或 user 對既有變更做了裁決；需要裁決而 unattended 的已 abort）後,進 Phase 1 with 已驗證的 git state。

---

## Phase 1: 偵測變更

### Step 1: 確定 Plugin

如果用戶指定了 plugin 名稱，直接使用。否則從 git 推斷：

```bash
# 這一步還沒有 plugin 名（要推斷的就是它），所以不用前導。只掃**一個** marketplace：cwd 在某個
# marketplace checkout 裡就用它；否則列出 list_marketplaces 請使用者先選，不掃全機（35 個 root
# 各跑 git + 逐名解析要十幾秒，且輸出混雜，#18 R4）。marketplace 名是第三方值，印之前去控制字元。
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
clean() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]\\' | LC_ALL=C cut -c1-200; }   # 也去反斜線：zsh 的 echo 會展開 \n \t
# 可選：使用者選定的 marketplace 名（空 → 由 cwd 推斷）。代入前核對 [A-Za-z0-9._-]。
MP_NAME='<marketplace-name-or-empty>'
case "$MP_NAME" in '<marketplace-name-or-empty>') MP_NAME="" ;; esac
# 同一條規則（_valid_name / Step 0.1）：[A-Za-z0-9._-]，不以 . 或 - 開頭
case "$MP_NAME" in .*|-*|*[!A-Za-z0-9._-]*) echo "✗ marketplace 名稱不合法（只接受 [A-Za-z0-9._-]，不以 . 或 - 開頭）" >&2; exit 1 ;; esac
HERE=$(pwd -P)
ROOT=""; MPN=""; BEST=""
if [ -n "$MP_NAME" ]; then
    # 指定名稱：走 marketplace_candidates（巢狀同名的子層是 subtree、外層勝——與 Step 0.1 同一規則，不靠索引順序）
    ROOT=$(marketplace_candidates "$MP_NAME" 2>/dev/null | head -1); MPN="$MP_NAME"
    [ "$(marketplace_candidates "$MP_NAME" 2>/dev/null | grep -c .)" -le 1 ] || echo "ℹ marketplace '$MP_NAME' 有多份實體不同的 checkout；這一步只推斷名稱，Step 0.1 會以 cwd 消歧、不在任何一份裡時要求你 cd。"
fi
while IFS="$(printf '\t')" read -r mp root; do
    [ -n "$root" ] && [ -z "$MP_NAME" ] || continue
    rp=$(cd "$root" 2>/dev/null && pwd -P) || continue
    # cwd 在哪份 checkout 裡：取**最內層**（最長）的包含 root——巢狀 marketplace 時外層也包含 cwd，
    # 取第一個命中會把站在內層的使用者判到外層（#18 R6）
    case "$HERE" in "$rp"|"$rp"/*) [ ${#rp} -gt ${#BEST} ] && { BEST="$rp"; ROOT="$root"; MPN="$mp"; } ;; esac
done <<EOF
$(marketplace_index)
EOF
if [ -z "$ROOT" ]; then
    echo "ℹ 當前目錄不在任何 marketplace checkout 裡（或指定的名稱不存在）。用 AskUserQuestion 讓使用者從下面選一個，"
    echo "  再把選到的名稱代入本 block 的 MP_NAME 重跑："
    list_marketplaces | while IFS= read -r m; do echo "  - $(clean "$m")"; done
    exit 0
fi
echo "→ marketplace: $(clean "$MPN") ($ROOT)"
# git 答不出來（HEAD 未生、少於 4 個 commit、shallow clone）不能變成「最近沒有 plugin 變更」：先探，
# 不足 3 個 commit 就從 root commit 起算，並把結果數印出來（#18 R8）
git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1 || { echo "ℹ $ROOT 沒有任何 commit — 無法推斷最近變更的 plugin；請直接給 plugin 名"; exit 0; }
BASE=HEAD~3
git -C "$ROOT" rev-parse -q --verify "$BASE" >/dev/null 2>&1 || BASE=$(git -C "$ROOT" rev-list --max-parents=0 HEAD | tail -1)
RECENT=$(git -c core.quotePath=false -c diff.relative=false -C "$ROOT" diff --name-only "$BASE" 2>/dev/null | plugin_names_for_paths "$ROOT")   # plugin_names_for_paths 以 toplevel 相對路徑對齊，diff.relative 不得改變輸出形狀
if [ -n "$RECENT" ]; then printf '%s\n' "$RECENT"; echo "→ 最近 $(git -C "$ROOT" rev-list --count "$BASE"..HEAD) 個 commit 觸到 $(printf '%s\n' "$RECENT" | grep -c .) 個 plugin（上列）"
else echo "ℹ 最近 $(git -C "$ROOT" rev-list --count "$BASE"..HEAD) 個 commit 沒有觸到任何 manifest 對映得到的 plugin（不是「沒有變更」：見 plugin_names_for_paths 的 stderr 警告）"; fi
```

列出這個 marketplace 最近變更的 plugin（經 manifest 對映，`./plugin`、entry-less `plugins/<name>` 與 repo-即-plugin 佈局都算得到；巢狀 marketplace 的路徑以 `git rev-parse --show-prefix` 對齊；`core.quotePath=false` 讓非 ASCII 檔名不被引號化），請用戶確認要更新哪一個；確認後以該 plugin 名**與上面印出的 marketplace 名**（代入 Step 0.1 的 `MP_NAME`；這個名稱在 resolver 索引層已過 `[A-Za-z0-9._-]`，代入時再核對一次）跑 Step 0.1——Step 0.1 只在那個 marketplace 的 checkout 裡解析、同名多份 checkout 以 cwd 消歧、並以 context 檔綁定，不會全域重選到另一份。

### Step 2: 檢查 Git 狀態

> **Skipped(v1.16.0+ #60)**:Git state preview + commit/push decision 已在 [**Phase 0.5: Git State Preview & Confirmation Gate**](#phase-05-git-state-preview--confirmation-gate-v1160-60) 處理。
>
> 走到 Phase 1 等於 Phase 0.5 已 gate 過：clean start 直接通過（#19），或 user 對既有的未提交 / 未推送 / 分歧做了裁決（abort 的話根本不會走到這裡）。
>
> Pre-v1.16.0 此 step 印 `git status` 後接 narrative reminder 「請先 commit + push」,**沒實際 gate**;新版升格成 Phase 0.5 的 explicit dispatch（#60 時是 5-case AskUserQuestion；#19 起 Case A 通過、E' ff-only 後重測、B–E 才問）。歷史脈絡見 #60。

---

## Phase 1.5: External Binary Dependency Check（若有）

Plugin 如果依賴外部 binary（MCP server、CLI 工具），plugin-update 只會同步 shell
（wrapper / skill / command），**不會** 自動更新 binary。這個 phase 偵測並提示。

### Step 1: 偵測依賴類型

| 訊號 | 類型 | 判斷方式 |
|------|------|---------|
| `.mcp.json` 存在 | **MCP binary** | `<PLUGIN_DIR>/.mcp.json` 存在 |
| `bin/` 下任何一般檔案含 release URL | **MCP binary**（wrapper）| `gh release download` / `api.github.com/repos/…/releases` / `github.com/…/releases/(download\|tags\|latest)`——URL 形狀，不是檔名後綴（`bin/che-keychain` 也算）、不是變數名（`REPO=` / `GITHUB_REPO=` 都不是判準）|
| `hooks/*.sh` 含同一 URL pattern | **CLI tool** | 同上；hook 只委派給 wrapper、不自己 curl 的佈局由上一列接住 |
| manifest 有 `binary_version` / `binaryVersion` | 由宣告 | 兩種拼法都讀；不回退 `version` |
| Skill / hook 引用 `~/bin/$BINARY` | — | 文件描述用；**不是**可執行判準——對 skills/ 散文 grep 會把 harness-devtools 自己判成 binary-backed（#18 R4）|

（`<PLUGIN_DIR>` 是敘述；四列判準與 owner/repo、binary 名的抽取都在 `scripts/plugin-binary-meta.sh`（#22），可執行的判斷在 Phase 0.3 Step 1 帶前導的 fence。）

### Step 2: MCP 情境 — 兩個信號（asset present + repo drift）

兩個獨立信號：

1. **Latest release 有沒有對應 asset** — 救「release 漏上傳 binary」這類 #13-style 失誤
2. **Binary repo main 是否超前 last release**（v1.17.0+ 新增信號）— 救「main 累積大量 [Unreleased] 改動但沒 cut release」這類盲點

兩個信號獨立、各自 warn。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ Phase 1.5: $PLUGIN_DIR 沒有 plugin manifest（Step 0.1 應已擋下）" >&2; exit 1; }
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
# 不用 `for wrapper in "$PLUGIN_DIR"/bin/*-wrapper.sh`：zsh nomatch 會讓對不到的 glob 中止整個 fence（#18 R7）。
# **逐 wrapper**：plugin_binary_wrappers 對 bin/ 下每個真的會下載 release 的檔案各給一列 `file|asset|install|repo`
# （不限 *-wrapper.sh；che-telegram-mcp 有兩支 wrapper / 兩個 binary，只驗第一個卻印「checked: N」是 R1 的 HIGH）。
# 抽不到就每列各印一行（#17：沉默與「檢查過沒問題」不可區分）；名稱與 repo 都已過 allowlist。
# 本 step 是 MCP 情境：沒有 bin/ 的 hook-only 佈局（gifthub）由 Step 3 處理——這裡明說並停住，不用 hooks 抽到的名字去查 MCP asset。
WRAPPERS=$(plugin_binary_wrappers "$PLUGIN_DIR") || WRAPPERS=""
BIN_FILES=$(find "$PLUGIN_DIR/bin" -maxdepth 1 -type f 2>/dev/null | grep -c .)
if [ -z "$WRAPPERS" ] || [ "$BIN_FILES" = 0 ]; then
    echo "→ Phase 1.5 Step 2: wrappers checked: 0 of ${BIN_FILES} bin/ file(s) — 沒有會下載 release 的 wrapper（hook-only 佈局走 Step 3；不是「檢查過沒問題」）"
    exit 0
fi
# 有效 pin（binary_version → binaryVersion → version，key 印出）與 unreleased 比對每個 repo 只做一次
PBV=$(plugin_binary_version_effective "$PLUGIN_MANIFEST"); BINARY_VERSION=${PBV%%|*}; BINARY_PIN_KEY=${PBV#*|}; [ "$BINARY_PIN_KEY" = "$PBV" ] && BINARY_PIN_KEY=""
[ -n "$BINARY_VERSION" ] || echo "ℹ $PLUGIN_MANIFEST 沒有 binary_version / binaryVersion / version — Signal 2 沒有 pin 可比（不是「沒有 unreleased」）"
CHECKED=0; TOTAL=0; UNRES=""; REPOS_SEEN="|"
while IFS='|' read -r wfile asset inst repo; do
    [ -n "$wfile" ] || continue
    TOTAL=$((TOTAL + 1))
    if [ -z "$asset" ] || [ -z "$repo" ]; then
        MISS=""; [ -z "$asset" ] && MISS="BINARY_NAME"; [ -z "$repo" ] && MISS="${MISS:+$MISS 與 }repo"
        echo "❓ ${wfile}: 判定不出 ${MISS}（只認 BINARY_NAME= / INSTALL_NAME= / \$HOME/bin/<name>；*_REPO=\"owner/repo\" 或 release URL 字面）— Signal 1 對它沒驗證任何東西"
        UNRES="${UNRES:+$UNRES }${wfile}"; continue
    fi
    CHECKED=$((CHECKED + 1))
    # === Signal 1: asset present in latest release? ===（走 gh，與 Phase 0.3 (e) 同一個 stub 座標；查不到說 UNKNOWN，不說「缺」）
    if ASSETS=$(release_assets "$repo"); then
        if printf '%s\n' "$ASSETS" | grep -qxF -- "$asset"; then echo "✅ ${wfile}: ${asset} present in ${repo} latest release"
        else
            echo "⚠️  ${wfile}: ${asset} not in ${repo} latest release"
            echo "   Plugin will install but wrapper auto-download will fail."
            echo "   → cd <MCP-source-repo> && /harness-devtools:mcp-deploy"
        fi
    else
        echo "❓ ${wfile}: 取不到 ${repo} 的 latest release assets（gh 未登入 / 網路 / 沒有 release）— Signal 1 未核對（不是「asset 在」）"
    fi

    # === Signal 2: binary repo main has unreleased commits? (v1.17.0+) === 每個 repo 一次
    case "$REPOS_SEEN" in *"|$repo|"*) continue ;; esac; REPOS_SEEN="${REPOS_SEEN}${repo}|"
    REPO_BASENAME=$(basename "$repo")
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
                echo "⚠️  $REPO_BASENAME main has $UNRELEASED unreleased commits since v$BINARY_VERSION (pin key: ${BINARY_PIN_KEY})"
                echo "   $PLUGIN_MANIFEST pins ${BINARY_PIN_KEY}=$BINARY_VERSION; wrapper auto-download will fetch that."
                echo "   Recent unreleased commits:"
                git -C "$BINARY_REPO_PATH" log "v$BINARY_VERSION..main" --oneline 2>/dev/null | head -5 | sed 's/^/      /'
                echo "   → cd $BINARY_REPO_PATH && ./scripts/release.sh v<next>"
                echo "     then bump $PLUGIN_MANIFEST ${BINARY_PIN_KEY} + re-run plugin-update"
            fi
        else
            # Local tag missing — could mean: never fetched, or release made on remote-only.
            # Best-effort: skip rather than misreport.
            echo "ℹ️  $REPO_BASENAME local repo found but tag v$BINARY_VERSION missing — run 'git fetch --tags' to enable Signal 2"
        fi
    fi
done <<EOF
$WRAPPERS
EOF
echo "→ Phase 1.5 Step 2: wrappers checked: ${CHECKED} of ${TOTAL} (bin/ files: ${BIN_FILES})${UNRES:+; unresolved: $UNRES} pin=${BINARY_VERSION:-none}${BINARY_PIN_KEY:+ key=$BINARY_PIN_KEY}"
```

**何時 Signal 2 沉默**：
- Plugin.json 無 `binary_version` / `binaryVersion` / `version` 欄位（印一行 ℹ；有效 pin 的 key 會印出來——來自 `version` 時提醒該補 pin）
- 本機沒有 binary repo 的 clone（試過 `~/Developer/` / `~/Developer/che-mcps/` / `~/code/` 三個 fallback）
- Local clone 沒有對應的 `v$BINARY_VERSION` tag（建議使用者跑 `git fetch --tags`）

設計理由：Signal 2 是 best-effort warn — 對能取得的資訊提示，缺資料時 silent skip。**不 abort plugin-update**（這是 Phase 0.3 的工作）；Phase 1.5 維持「prompt then sync」的協助型行為。

### Step 3: CLI 情境 — 比對本機 binary 和 latest release 版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# 與 Step 2 同一套紀律（#18 R8）：抽不到就報出來、抽到的值過 allowlist 才進 exec / URL、結尾印結論——
# 沉默與「本機 binary 已是最新」在 stdout 上不可區分。
HOOK="$PLUGIN_DIR/hooks/session-start.sh"
[ -f "$HOOK" ] || { echo "ℹ Phase 1.5 Step 3: $PLUGIN_DIR 沒有 hooks/session-start.sh — CLI 版本比對沒有可驗證的對象（不是「已同步」）"; exit 0; }
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
# repo 與 binary 名由 helper 抽（#22；與 Step 2 同一份 allowlist）：認 `<任何>_REPO="owner/repo"` / `REPO="owner/repo"` 賦值
# （gifthub 是 GFH_REPO=）、字面 api.github.com/repos/owner/repo、github.com/owner/repo（不抓檔案裡第一個 a/b 形字串：#!/bin/sh 就會命中）；
# 名稱認 BINARY_NAME= / INSTALL_NAME= / $HOME/bin/<name>。抽的範圍是 bin/* 與 hooks/*.sh，不只 session-start.sh。
GFH_REPO=$(plugin_binary_repo "$PLUGIN_DIR"); PBR_RC=$?
[ "$PBR_RC" = 2 ] && echo "⚠ $PLUGIN_DIR 引用了多個 repo — 取第一個（${GFH_REPO}）"
BINARY_NAME=$(plugin_binary_name "$PLUGIN_DIR") || BINARY_NAME=""
[ -n "$GFH_REPO" ] || { echo "❓ $PLUGIN_DIR 的 bin/ 與 hooks/ 判定不出 repo（只認 *_REPO=\"owner/repo\" 賦值、gh api …/repos/owner/repo/releases、api.github.com/repos/owner/repo/releases、github.com/owner/repo/releases 字面）— CLI 版本比對沒驗證任何東西"; exit 0; }
[ -n "$BINARY_NAME" ] || { echo "❓ $PLUGIN_DIR 的 bin/ 與 hooks/ 判定不出 \$HOME/bin/<name>（也沒有 BINARY_NAME= / INSTALL_NAME=）— CLI 版本比對沒驗證任何東西"; exit 0; }
[ -x "$HOME/bin/$BINARY_NAME" ] || echo "ℹ $HOME/bin/$BINARY_NAME 未安裝（或不可執行）— 本機版本無法取得"
# 這是 plugin 檔案內容點名的 binary（它自己的 CLI）：從中性目錄執行，不讓它以 marketplace repo 為 cwd
LOCAL_VERSION=$(cd / && "$HOME/bin/$BINARY_NAME" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
# latest 走 gh（帶認證；與 Phase 0.3 (e) 同一函式，測試共用 PBM_GH stub）；兩邊都正規化成 x.y.z 再比（tag v1.2.3-rc1 / 前綴 tag 不得製造假的「落後」）
LATEST_VERSION=$(latest_release_version "$GFH_REPO" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$LATEST_VERSION" ]; then echo "❓ 取不到 $GFH_REPO 的 latest release（網路 / 沒有 release / rate limit）— 無法比對"
elif [ -z "$LOCAL_VERSION" ]; then echo "❓ 取不到本機 $BINARY_NAME 的版本（latest v${LATEST_VERSION}）— 無法比對"
elif [ "$LOCAL_VERSION" != "$LATEST_VERSION" ]; then
    echo "⚠️  $BINARY_NAME local v$LOCAL_VERSION, latest v$LATEST_VERSION"
    echo "   → /harness-devtools:cli-upgrade $BINARY_NAME"
else echo "✅ Phase 1.5 Step 3: $BINARY_NAME local v$LOCAL_VERSION == latest（${GFH_REPO}）"; fi
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
  - "中止" — 停止 plugin-update，讓我手動處理（先 `remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"`，同 Phase 0.5 Step 3）
```

**unattended（`IDD_ALL_UNATTENDED=1`）**：要不要順便更新 binary 是需要人裁決的（「順便更新」會觸發 mcp-deploy / cli-upgrade 這類有副作用的動作）→ 先 `remove_plugin_ctx`，auto-abort + structured error（同 Phase 0.5 Step 4 的格式，`Detected state: binary out of sync`，退出碼 75），印一行 `AUDIT: Phase 1.5 binary out of sync — aborted under unattended`，`idd-all` 在 final report 標 "plugin-update skipped under unattended mode: binary out of sync"。這條路徑在 #19 之前不可達（unattended 走不過 Phase 0.5），是 Case A 放行後才需要的分支。

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
| 有依賴但不同步（attended） | **AskUserQuestion**：要順便更新 binary 嗎？ |
| 有依賴但不同步（unattended，`IDD_ALL_UNATTENDED=1`） | `remove_plugin_ctx` + auto-abort（exit 75、structured error）；不自行選項 |

**為什麼 plugin-update 是 prompt-then-sync 而 plugin-deploy 是 block**：

| Skill | 觸發頻率 | 行為 | 理由 |
|-------|---------|------|------|
| `plugin-deploy` Step 2.5 | 偶爾（發版時）| **BLOCK** | Release 沒 binary = 新使用者裝 plugin 就壞，不能放過 |
| `plugin-update` Phase 1.5 | 頻繁（日常同步）| **ASK + AUTO-SYNC** | 開發者通常想要一次更新完，但要尊重「只改 shell 不動 binary」的情境 |

### Step 5: 執行 auto-sync（若使用者選擇）

**MCP 情境**：

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# BINARY_NAME 是 Step 2 那個 fence 印出的值（wrapper 的 BINARY_NAME=），由 agent 代入；代入前核對
# [A-Za-z0-9._-]。空值會讓下面的 grep -l "" 命中每一個 Package.swift、cd 進隨機 repo（#18 R5）。
BINARY_NAME='<binary-name-from-step-2>'
case "$BINARY_NAME" in ''|'<binary-name-from-step-2>'|.*|-*|*[!A-Za-z0-9._-]*) echo "✗ BINARY_NAME 未代入或不合法 — 先看 Step 2 的輸出" >&2; exit 1 ;; esac
# 找到 MCP source repo（通常在 ~/Developer/ 下）
MCP_SOURCE=$(find ~/Developer -maxdepth 3 -name "Package.swift" -exec grep -lF -- "$BINARY_NAME" {} \; | head -1 | xargs dirname 2>/dev/null)   # -F：不把 . 當萬用字元

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
# cli-upgrade 已知如何找 repo（從 ~/bin/<binary> 偵測）。BINARY_NAME 同上：由 Step 3 的輸出代入、核對後才用。
BINARY_NAME='<binary-name-from-step-3>'
case "$BINARY_NAME" in ''|'<binary-name-from-step-3>'|.*|-*|*[!A-Za-z0-9._-]*) echo "✗ BINARY_NAME 未代入或不合法" >&2; exit 1 ;; esac
# Skill invocation: Skill(skill="cli-tools:cli-upgrade", args="$BINARY_NAME")
```

完成後回到 Phase 2 繼續 marketplace.json sync。

---

## Phase 2: 更新 marketplace.json（關鍵！）

`marketplace.json` 位於 `$MP_ROOT/.claude-plugin/marketplace.json`，是 marketplace 的 plugin index。
**如果這個檔案沒更新，`claude plugin marketplace update` 不會看到新版本。**

> **本 phase 的鏡像 commit 由本 phase 自己 commit + push**（Step 4 的 fence，只在 marketplace.json 真的有變更時；已同步就印一行跳過）；Phase 0.5 只 gate 樹上**既有**的變更，不預期這裡的 commit（#19）。

### Step 1: 列出 marketplace 中所有 plugin 版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# entry 缺 version 不是 KeyError（#22 第 4 點：che-keychain 的 entry 原本就沒有 version）——印 (missing — will be set from plugin.json)，Step 2 補上
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("plugins") or []:
    if isinstance(p, dict):
        v = p.get("version")
        print("  %s: %s" % (p.get("name", "?"), v if isinstance(v, str) and v else "(missing — will be set from plugin.json)"))
' .claude-plugin/marketplace.json
```

### Step 2: 對比 plugin.json 的實際版本

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ $PLUGIN_DIR 沒有 plugin manifest — 沒有 version 可同步" >&2; exit 1; }
V=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_MANIFEST" 2>/dev/null)
[ -n "$V" ] || { echo "✗ 讀不到 $PLUGIN_MANIFEST 的 version" >&2; exit 1; }
echo "plugin.json ($PLUGIN_MANIFEST): $V"
```

如果 marketplace.json 的版本落後 plugin.json，用 Edit 工具更新 marketplace.json。**entry 沒有 `version` 欄位時**（Phase 0.3 印過 `entry has no version`、Step 1 印 `(missing — will be set from plugin.json)`）：在該 entry 加一行 `"version": "<plugin.json 的 version>"`（放在 `"name"` 之後），不是改既有值——che-keychain 的 entry 原本就沒有這個欄位（#22 第 4 點）。Step 4 的 fence 會驗版本相等才 commit。

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
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ $PLUGIN_DIR 沒有 plugin manifest — 沒有 version 可同步" >&2; exit 1; }
NEW_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_MANIFEST" 2>/dev/null)
[ -n "$NEW_VERSION" ] || { echo "✗ 讀不到 $PLUGIN_MANIFEST 的 version" >&2; exit 1; }
case "$NEW_VERSION" in *[!0-9A-Za-z.+-]*) echo "✗ plugin.json 的 version 含非法字元（只接受 [0-9A-Za-z.+-]）" >&2; exit 1 ;; esac
clean() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]\\' | LC_ALL=C cut -c1-80; }
# 「已同步」要驗**版本**，不是驗「檔案沒被改過」：Step 2 / 3 的 Edit 是 agent 的手動步驟，漏做時檔案
# 也是乾淨的——印一句肯定的「已同步」就是 #19 要治的那類假訊息（#19 R2）。用 Phase 0.3 (b) 同一個 helper，
# 「entry 不存在」與「entry 缺 version」各給各的處方（#22）。
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
MP_NOW=$(marketplace_entry_version "$MP_ROOT" "$PLUGIN_NAME"); MEV_RC=$?
if [ "$MEV_RC" = 1 ]; then
    echo "✗ Phase 2: marketplace.json 沒有 '$PLUGIN_NAME' 的 entry — 回 Step 3 依範本新增整個 entry（name / version / description / author / source / category；source 是後續所有 phase 解析路徑的依據）後重跑本 fence。" >&2
    exit 1
elif [ "$MEV_RC" = 3 ]; then
    echo "✗ Phase 2: marketplace.json 的 '$PLUGIN_NAME' entry 的 version 含非法字元 — 改成 ${NEW_VERSION} 後重跑本 fence。" >&2
    exit 1
elif [ "$MEV_RC" != 0 ]; then
    echo "✗ Phase 2: 讀不動 .claude-plugin/marketplace.json（rc ${MEV_RC}）— 先修好檔案再重跑本 fence。" >&2
    exit 1
elif [ -z "$MP_NOW" ]; then
    echo "✗ Phase 2: marketplace.json 的 '$PLUGIN_NAME' entry 沒有 version — Step 2 的 Edit 沒落地。在 entry 加 \"version\": \"${NEW_VERSION}\" 後重跑本 fence。" >&2
    exit 1
elif [ "$MP_NOW" != "$NEW_VERSION" ]; then
    echo "✗ Phase 2: marketplace.json 的 '$PLUGIN_NAME' entry 是 v$(clean "$MP_NOW")，plugin.json 是 v${NEW_VERSION} — Step 2 的 Edit 沒落地。先把 entry 的 version 改成 ${NEW_VERSION} 再重跑本 fence。" >&2
    exit 1
fi
# 參考點是 upstream，不是 index：本 fence 自己 push 失敗後重跑、或 Phase 1.5 的 mcp-deploy 順手 commit 了鏡像，
# 都會留下「已在 HEAD、upstream 還沒有」的狀態——只比 index↔HEAD 會把它印成成功（#19 R3）
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || { echo "✗ Phase 2: 沒有 upstream — Phase 0.5 Step 1 應已 abort" >&2; exit 1; }
git --literal-pathspecs add -- .claude-plugin/marketplace.json
if ! git --literal-pathspecs diff --cached --quiet -- .claude-plugin/marketplace.json; then
    git --literal-pathspecs commit -m "chore: update marketplace.json for $PLUGIN_NAME v$NEW_VERSION" -- .claude-plugin/marketplace.json \
      || { echo "✗ Phase 2: commit 失敗" >&2; exit 1; }
    echo "→ Phase 2: committed marketplace.json mirror (v${NEW_VERSION})"
fi
AHEAD=$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null) || { echo "✗ Phase 2: 算不出 $UPSTREAM..HEAD" >&2; exit 1; }
if [ "$AHEAD" = 0 ]; then
    echo "→ Phase 2: marketplace.json v${NEW_VERSION} 已在 HEAD 且 $UPSTREAM 已包含 HEAD — 無需 push；繼續 Phase 3"
else
    # push 推的是整個 branch：Phase 0.5 量到 0 既有未推送是「當時」的事實，中間隔著 Phase 1 / 1.5
    # （mcp-deploy 可能 opt-in commit）。全部列出並做 Step 5 同款的 plugin 歸屬分析（解析不到的名稱算未知）。
    echo "→ Phase 2: $AHEAD commit(s) to push to ${UPSTREAM}："; git log --oneline "$UPSTREAM..HEAD" | sed 's/^/     /'
    PNP_ERR=$(mktemp) || exit 1
    TOUCHED=$(git -c core.quotePath=false -c diff.relative=false log --name-only --pretty=format: "$UPSTREAM..HEAD" | plugin_names_for_paths "$MP_ROOT" 2>"$PNP_ERR")
    UNRES=$(grep -c 'did not resolve' "$PNP_ERR" || true); rm -f "$PNP_ERR"
    echo "  plugins touched (manifest 對映): ${TOUCHED:-(none)}; unresolved names: ${UNRES:-0}$( [ "${UNRES:-0}" = 0 ] || printf ' — 未知，不是沒動到')" | tr '\n' ' '; echo
    # push 明寫 remote 與 refspec（從 @{u} 拆出），不靠 push.default / pushRemote：裸 `git push` 在 push.default=current
    # 或 matching 下會在本地 branch 名 ≠ upstream 名時開新分支或什麼都不推卻 rc 0；`origin HEAD` 同樣開新分支（#19 R2/R3）。
    # push 之後再驗 @{u} == HEAD 才印成功——成功訊息必須是量出來的，不是宣告的。
    REMOTE=${UPSTREAM%%/*}; RBRANCH=${UPSTREAM#*/}
    git push "$REMOTE" "HEAD:refs/heads/$RBRANCH" || { echo "✗ Phase 2: push to $UPSTREAM failed（鏡像 commit 仍在本地 HEAD，重跑本 fence 會再推）" >&2; exit 1; }
    if [ "$(git rev-parse '@{u}' 2>/dev/null)" = "$(git rev-parse HEAD)" ]; then
        echo "→ Phase 2: marketplace.json mirrored to v${NEW_VERSION}, pushed — $UPSTREAM == HEAD (verified)"
    else
        echo "✗ Phase 2: push 回 0 但 $UPSTREAM 仍 != HEAD（remote-tracking ref 未更新）— 檢查 remote 設定後重跑" >&2; exit 1
    fi
fi
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
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
README="$PLUGIN_DIR/README.md"
# README 不存在是一個獨立的狀態（狀況表：跳過，plugin-deploy 才強制補），要明說；不能讓六個信號各自
# 對不存在的檔案給出「沒提到」或「沒問題」（#18 R7）
[ -f "$README" ] || { echo "ℹ Phase 2.5: $PLUGIN_DIR 沒有 README.md — 六信號跳過（這是「沒有 README」，不是「README 沒問題」）"; exit 0; }
STALE_README=false
# 信號 2 與 6 靠 git：git 答不出來（非 work tree / 沒 commit）時這兩個信號是「無法判定」，不是「通過」，
# 結論行要把它們算成 unknown 而不是併進「全過」（#18 R8）
GIT_OK=true
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git rev-parse -q --verify HEAD >/dev/null 2>&1 || GIT_OK=false
[ "$GIT_OK" = true ] || echo "ℹ Phase 2.5: $MP_ROOT 不是可用的 git work tree — 信號 2 / 6 無法判定"
# 每個信號在「沒有輸入可評估」時記一筆，結論行只宣稱真的跑過的那幾個（#18 R9）
SKIPPED=""
# 讀不到 version 就 abort：空的 NEW_VERSION 會讓下面信號 1 的 pattern 變成 `v\|`（空 alternation
# 匹配每一行）→ README 永遠「沒有 stale」——這正是 #18 要消滅的「偵測落空被讀成沒有」。
[ -n "$PLUGIN_MANIFEST" ] || { echo "✗ Phase 2.5: $PLUGIN_DIR 沒有 plugin manifest — README 六信號無法判定" >&2; exit 1; }
NEW_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_MANIFEST" 2>/dev/null)
[ -n "$NEW_VERSION" ] || { echo "✗ Phase 2.5: 讀不到 $PLUGIN_MANIFEST 的 version — README 六信號無法判定" >&2; exit 1; }

# README 是否有任何版本追蹤標記（給 Suppression A 用）
HAS_VERSION_SECTION=false
if grep -qE '## (Version|Changelog)|# Changelog|v[0-9]+\.[0-9]+' "$README" 2>/dev/null; then
    HAS_VERSION_SECTION=true
fi

# 信號 1: README 沒出現新版本字串
[ "$HAS_VERSION_SECTION" = "true" ] || SKIPPED="$SKIPPED 1(README 無版本標記)"
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
CODE_MTIME=$(git --literal-pathspecs log -1 --format=%ct -- "$PLUGIN_MANIFEST" "$PLUGIN_DIR/skills" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/rules" "$PLUGIN_DIR/commands" 2>/dev/null)
{ [ "$GIT_OK" = true ] && [ -n "$README_MTIME" ] && [ -n "$CODE_MTIME" ] && [ "$HAS_VERSION_SECTION" = "true" ]; } || SKIPPED="$SKIPPED 2(無 git mtime 或無版本標記)"
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
[ -f "$CHANGELOG" ] || SKIPPED="$SKIPPED 3(無 CHANGELOG.md)"
if [ -f "$CHANGELOG" ]; then
    LATEST_CL_VERSION=$(grep -oE '^## \[?[0-9]+\.[0-9]+\.[0-9]+\]?' "$CHANGELOG" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$LATEST_CL_VERSION" ] && ! grep -q "$LATEST_CL_VERSION" "$README" 2>/dev/null; then
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
# 迴圈一律 `while read` 吃 heredoc，不寫 `for x in $VAR`：Bash 工具是 zsh，未加引號的展開**不分詞**，
# 整串換行相連的名單會當成一個項目、grep 收到含換行的 pattern → 信號 4 / 6 永遠不觸發（#18 R8）
# 名稱來自檔案系統：不經 xargs（空白 / 引號會被重切）、只接受 [A-Za-z0-9._-]（其餘記為未評估）、
# 拼進 ERE 前把 . 跳脫（`a.b` 不得匹配 `axb`）（#18 R9）
ACTUAL_SKILLS=$(find "$PLUGIN_DIR/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null | sed 's#/SKILL\.md$##; s#.*/##' | sort)
ACTUAL_AGENTS=$(find "$PLUGIN_DIR/agents" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | sed 's#.*/##; s#\.md$##' | sort)
ACTUAL_COMMANDS=$(find "$PLUGIN_DIR/commands" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | sed 's#.*/##; s#\.md$##' | sort)
name_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
re_esc() { printf '%s' "$1" | sed 's/[.]/\\./g'; }
MISSING_COMPONENTS=()
# 認可的引用格式（任一命中即視為「README 提到這個 component」）：
#   `name`              — backtick-quoted reference
#   /name               — bare slash command form
#   /plugin-name:name   — plugin-namespace form (typical in installed clients)
#   @name               — agent reference
#   - **name**          — markdown bold list entry
while IFS= read -r s; do [ -n "$s" ] || continue
    name_ok "$s" || { SKIPPED="$SKIPPED 4(skill 名含非法字元:$s)"; continue; }; s=$(re_esc "$s")
    grep -qE "\`$s\`|/${s}\b|/[a-z0-9_-]+:${s}\b|^- \*\*$s\*\*" "$README" 2>/dev/null || MISSING_COMPONENTS+=("skill:$s")
done <<EOF
$ACTUAL_SKILLS
EOF
while IFS= read -r a; do [ -n "$a" ] || continue
    name_ok "$a" || { SKIPPED="$SKIPPED 4(agent 名含非法字元:$a)"; continue; }; a=$(re_esc "$a")
    grep -qE "\`$a\`|@$a\b|/[a-z0-9_-]+:${a}\b|^- \*\*$a\*\*" "$README" 2>/dev/null || MISSING_COMPONENTS+=("agent:$a")
done <<EOF
$ACTUAL_AGENTS
EOF
while IFS= read -r c; do [ -n "$c" ] || continue
    name_ok "$c" || { SKIPPED="$SKIPPED 4(command 名含非法字元:$c)"; continue; }; c=$(re_esc "$c")
    grep -qE "/${c}\b|\`/${c}\`|/[a-z0-9_-]+:${c}\b" "$README" 2>/dev/null || MISSING_COMPONENTS+=("command:$c")
done <<EOF
$ACTUAL_COMMANDS
EOF
if [ ${#MISSING_COMPONENTS[@]} -gt 0 ]; then
    echo "⚠️  signal-4: README missing ${#MISSING_COMPONENTS[@]} components: ${MISSING_COMPONENTS[*]}"
    STALE_README=true
fi

# 信號 5: Tool count drift（v1.15.0 新增）
# README 多半會在標題寫「(N tools)」「N MCP Tools」「Tool 數量: N」。
# 把這個 N 抓出來跟 plugin.json description 中宣稱的 tool 數比對。
# README 落後最容易在這露餡（che-ical-mcp v0.8.2 → v1.7.2 README 寫 20 tools 實際 28）。
DESC=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("description", ""))' "$PLUGIN_MANIFEST" 2>/dev/null)
DESC_TOOLS=$(echo "$DESC" | grep -oE '[0-9]+ ?(?:個 )?(?:MCP )?(?:tools|工具)' | head -1 | grep -oE '^[0-9]+')
README_TOOLS=$(grep -oE 'Available Tools \([0-9]+\)|\([0-9]+ (?:MCP )?tools\)|\*\*[0-9]+ MCP Tools\*\*|[0-9]+ 個工具' "$README" 2>/dev/null | grep -oE '[0-9]+' | head -1)
{ [ -n "$DESC_TOOLS" ] && [ -n "$README_TOOLS" ]; } || SKIPPED="$SKIPPED 5(無 tool count 可比)"
if [ -n "$DESC_TOOLS" ] && [ -n "$README_TOOLS" ] && [ "$DESC_TOOLS" != "$README_TOOLS" ]; then
    echo "⚠️  signal-5: README tool count ($README_TOOLS) != plugin.json description ($DESC_TOOLS)"
    STALE_README=true
fi

# 信號 6: Version history multi-version gap（v1.15.0 新增）
# 如果 README 有 Version History 表格，掃「最近 90 天」的 git log 找出 bump commits，
# 確保表格涵蓋這段時間出貨的版本 — 不只是「latest 有沒有」（信號 1）而是「中間是否漏版本」。
# 範圍只看 90 天避免 major rewrite（plugin v1.x → v2.x README 改寫）誤觸發。
{ [ "$GIT_OK" = true ] && grep -q '## Version History\|### Changelog' "$README" 2>/dev/null; } || SKIPPED="$SKIPPED 6(無 Version History 或無 git)"
if grep -q '## Version History\|### Changelog' "$README" 2>/dev/null; then
    SHIPPED_VERSIONS=$(git --literal-pathspecs log --since="90 days ago" --format='%s' -- "$PLUGIN_DIR/" 2>/dev/null | \
        grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -8)
    MISSING_VERSIONS=()
    while IFS= read -r v; do [ -n "$v" ] || continue
        v_clean=${v#v}
        grep -q "$v_clean\|v$v_clean" "$README" 2>/dev/null || MISSING_VERSIONS+=("$v_clean")
    done <<EOF
$SHIPPED_VERSIONS
EOF
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
# 結論要印出來：沒有任何 ⚠️ 與「fence 中途死掉」在 stdout 上一模一樣（#18 R7）；
# 「全過」只能說已評估的信號——靠 git 的兩個在非 git 目錄是 unknown（#18 R8）
if [ "$STALE_README" = true ]; then echo "→ Phase 2.5: README stale（見上方 signal-N）— Step 2 詢問是否更新"
elif [ -z "$SKIPPED" ]; then echo "✅ Phase 2.5: README fresh（六信號全過）— 繼續 Phase 3"
else echo "✅ Phase 2.5: README fresh（已評估的信號通過；未評估：${SKIPPED}）— 繼續 Phase 3"; fi   # ${…}：bash 會把緊接的全形括號吃進變數名
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
| 更新 README | Read CHANGELOG.md + 在帶前導的 fence 內 `git --literal-pathspecs -C "$MP_ROOT" log --oneline -n 10 -- "$PLUGIN_DIR/"` → 提出 README diff → 使用者確認後 Edit，再用**下方的 fence** commit + push（不在對話裡現組 git） |
| 已經沒問題 | 繼續 Phase 3，不記 warning |
| 先略過 | 繼續 Phase 3，**Phase 5 最終 report 要顯眼標註** README 待補 |

**unattended（`IDD_ALL_UNATTENDED=1`）**：自動採「先略過」——不改任何檔案、不問，印一行 `AUDIT: Phase 2.5 README stale（signal-N）— skipped under unattended, 待手動處理`，Phase 5 Step 3 的最終 report 原樣收錄。這是唯一不需要人裁決也不會動到東西的選項；#19 之前 unattended 走不到這裡。

```bash
# 「更新 README」的 commit + push（帶前導，git 在 marketplace repo 內跑；COMMIT_MSG 是使用者確認過的訊息）
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
MSGF=$(mktemp) || exit 1
cat > "$MSGF" <<'MSGEOF'
<commit-message>
MSGEOF
grep -qv '^<commit-message>$' "$MSGF" && grep -q . "$MSGF" || { echo "✗ 需要 commit message" >&2; rm -f "$MSGF"; exit 1; }
git --literal-pathspecs add -- "$PLUGIN_DIR/README.md" && git commit -F "$MSGF" && git push \
  && echo "→ Phase 2.5: README committed and pushed in $MP_ROOT"
rm -f "$MSGF"
```

### 狀況表

| 狀況 | 動作 |
|------|------|
| README 不存在 | 跳過（plugin-deploy 才會強制補） |
| README 存在且 fresh（六個信號都通過）| 顯示 ✅，繼續 Phase 3 |
| README 存在但 stale（attended） | **AskUserQuestion**（三選項） |
| README 存在但 stale（unattended） | 自動「先略過」：不改檔、不問，final report 標註 README stale 待手動處理 |
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
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
claude plugin marketplace update "$MP_NAME"
```

這會從 source（git remote 或本地目錄）重新拉取 plugin index。

### Step 2: 驗證

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
claude plugin list 2>&1 | grep -A3 -- "$PLUGIN_NAME"
```

---

## Phase 4: 更新已安裝的 Plugin

### 注意：必須加 `@marketplace_name` 後綴

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
# 已安裝 → 更新
claude plugin update "$PLUGIN_NAME@$MP_NAME"

# 未安裝 → 安裝
claude plugin install "$PLUGIN_NAME@$MP_NAME"
```

先檢查是否已安裝：
```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
claude plugin list 2>&1 | grep -- "$PLUGIN_NAME"
```

---

## Phase 5: 驗證與提醒

### Step 1: 確認最終狀態

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
# 唯一由 agent 代入的值是本次引數 PLUGIN_NAME：代入前先肉眼核對只含 [A-Za-z0-9._-]，
# 不符就停下來回報、不執行任何指令（單引號裡一個 ' 就能逃出字串；shell 層的檢查在代入之後）。
# 其餘（marketplace 名、root、plugin 目錄）一律從 Step 0.1 寫下的 context 檔載回並重驗
# ——那是純資料檔（逐行 parse，不 source），放在私有 state 目錄，第三方 manifest 的值
# 不經過 agent 的手，也不靠名稱重選 checkout。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
claude plugin list 2>&1 | grep -A5 -- "$PLUGIN_NAME"
```

檢查：
- Version 是否已更新到目標版本
- Status 是否 `✔ enabled`
- 是否有 `failed to load` 錯誤

### Step 1.5: binary-backed 驗證 + 收尾（**每個 plugin 都跑**，#22 第 5 點）

`claude plugin list` 顯示新版只證明 **shell** 裝好了。binary-backed plugin 的 binary 由 wrapper 在下次啟動時依 manifest 的 pin 下載，這一步對照 wrapper 寫的 sidecar（`~/bin/.<install name>.version`，**每個 binary 一個**：che-telegram-mcp 有兩個）與有效 pin——che-keychain 0.3.0 是手動跑 wrapper `--version` 才確認的。不主動執行 wrapper（那會在 marketplace repo 的 cwd 下載 binary）；沒有 sidecar 就說 UNVERIFIED，不說 ✅。純 shell plugin 印 `n/a`。**本次 invocation 在這個 fence 結束**（`remove_plugin_ctx`）——所以不是「非 binary-backed 就跳過」的 step，跳過它 context 檔會留下來、下一次執行從中途接上。

```bash
# ── 前導（每個 bash block 都以此開頭；Bash 工具的 shell 狀態不跨呼叫存活）──
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
load_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")" "$PLUGIN_NAME" || exit 1
cd "$MP_ROOT" || exit 1
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/plugin-binary-meta.sh"
# 給使用者貼的驗證指令只用過 allowlist 的檔名（bin/ 裡的檔名是第三方內容；`kc; rm -rf ~` 這種名字印 <wrapper>）
BIN_FILE=$(plugin_binary_wrappers "$PLUGIN_DIR" | head -1 | cut -d'|' -f1); case "$BIN_FILE" in ''|'?') BIN_FILE='<wrapper>' ;; *) BIN_FILE="$PLUGIN_DIR/bin/$BIN_FILE" ;; esac
if BINARY_HITS=$(plugin_is_binary_backed "$PLUGIN_DIR" "$PLUGIN_MANIFEST"); then
    PBV=$(plugin_binary_version_effective "$PLUGIN_MANIFEST"); PBV_RC=$?
    PIN=${PBV%%|*}; PIN_KEY=${PBV#*|}; [ "$PIN_KEY" = "$PBV" ] && PIN_KEY=""
    if [ "$PBV_RC" = 3 ]; then echo "❓ Phase 5 Step 1.5: UNKNOWN — $PLUGIN_MANIFEST 的 pin 值含非法字元，無法比對"
    elif [ "$PBV_RC" != 0 ] || [ -z "$PIN" ]; then echo "❓ Phase 5 Step 1.5: UNKNOWN — binary-backed (${BINARY_HITS}) but $PLUGIN_MANIFEST has no binary_version / binaryVersion / version（rc ${PBV_RC}）; nothing to compare the installed binary against"
    else
        NAMES=$(plugin_install_names "$PLUGIN_DIR") || NAMES=""
        if [ -z "$NAMES" ]; then
            echo "❓ Phase 5 Step 1.5: UNKNOWN — 抽不到 binary 名（bin/ 的 wrapper 沒有 BINARY_NAME= / INSTALL_NAME= / \$HOME/bin/<name>），找不到 sidecar"
        else
            OK_N=0; BAD=""; MISSING=""; ODD=""
            while IFS= read -r nm; do
                [ -n "$nm" ] || continue
                INSTALLED=$(plugin_installed_binary_version "$PLUGIN_DIR" "$nm"); PIB_RC=$?
                case "$PIB_RC" in
                  0) if [ "$INSTALLED" = "$PIN" ]; then OK_N=$((OK_N + 1)); echo "  ✅ ${nm}: installed v${INSTALLED} == pin v${PIN} (${PIN_KEY})"
                     else BAD="${BAD:+$BAD }${nm}=v${INSTALLED}"; echo "  ⚠️  ${nm}: installed v${INSTALLED} != pin v${PIN} (${PIN_KEY})"; fi ;;
                  1) MISSING="${MISSING:+$MISSING }${nm}"; echo "  ❓ ${nm}: no sidecar ${PLUGIN_BIN_DIR:-$HOME/bin}/.${nm}.version — wrapper 從未在本機觸發過" ;;
                  *) ODD="${ODD:+$ODD }${nm}"; echo "  ❓ ${nm}: sidecar 內容不是版本號（rc ${PIB_RC}）" ;;
                esac
            done <<EOF
$NAMES
EOF
            N_ALL=$(printf '%s\n' "$NAMES" | grep -c .)
            if [ -n "$BAD" ]; then echo "⚠️  Phase 5 Step 1.5: MISMATCH ${BAD} pin v${PIN} (${PIN_KEY}) — wrapper 下次啟動會抓 pin 的版本；要立刻驗證：(cd / && ${BIN_FILE} --version)"
            elif [ -n "$MISSING" ] || [ -n "$ODD" ]; then echo "❓ Phase 5 Step 1.5: UNVERIFIED (no sidecar for: ${MISSING}${ODD:+; unreadable: $ODD}) — ${OK_N}/${N_ALL} verified; binary 是否到位**未驗證**；要驗證：(cd / && ${BIN_FILE} --version)"
            else echo "✅ Phase 5 Step 1.5: installed == pin v${PIN} (${PIN_KEY}) for all ${OK_N} binar$([ "$OK_N" = 1 ] && printf 'y' || printf 'ies')"; fi
        fi
    fi
else
    echo "→ Phase 5 Step 1.5: n/a（not binary-backed）"
fi
# 本次 invocation 結束：清掉 context 檔，下一次執行必須重新走 Step 0.1 的 gate
remove_plugin_ctx "$(plugin_ctx_path "$PLUGIN_NAME")"
```

MISMATCH / UNVERIFIED / UNKNOWN 都**不是完成**：報出來、寫進 Step 3 的 report，讓使用者決定要不要立刻觸發 wrapper。

### Step 2: 提醒重啟

> 更新完成。請重啟 Claude Code（退出再重新開啟）讓變更完全生效。
> 或者在下次啟動新對話時，新版 plugin 就會自動載入。

### Step 3: 最終 report（attended / unattended 皆印；unattended 時這是唯一的痕跡，#19）

把本次各 phase 印過的決定行彙整成固定格式，貼在回覆（unattended 下由 `idd-all` 收進 final report）：

```
plugin-update report — <PLUGIN_NAME> @ <marketplace> (<mode: attended|unattended>)
- Phase 0.3: Case <A|B|C|E→bump→C|E→not bumped→C> — drift=<yes|no> recent_touches=<n> dirty=<n> unpushed_here=<n> binary=<…> key=<…> release_ahead=<…>; <AUDIT: Phase 0.3 pin … behind latest release … — not bumped under unattended（原樣）| —>
- Phase 0.5: Case <A verified|B|C|D|E|E'→重測> — <push N as-is | commit+push | abort | clean start>
- Phase 1.5: <no wrapper | binary in sync | binary out of sync → mcp-deploy / cli-upgrade | AUDIT: skipped under unattended (binary out of sync)>
- Phase 2: <mirrored vX and pushed to <upstream> (verified) | already at HEAD and upstream | abort: Edit 沒落地>
- Phase 2.5: <README fresh | README updated | AUDIT: README stale（signal-N）待手動處理 | 使用者選「已經沒問題」>
- Phase 3/4: marketplace update <ok|failed>; plugin update <ok|failed>; installed version <…>
- Phase 5: binary <n/a | installed == pin vX for all N | MISMATCH <name>=vX … pin vY | UNVERIFIED (no sidecar for: …) k/N verified | UNKNOWN>
```

Phase 0.3 Step 2（pin 落後 release、unattended 不 bump）、Phase 1.5 Step 4 與 Phase 2.5 Step 2 在 unattended 下各印一行以 `AUDIT:` 開頭的固定文字，這一步把它們原樣收進來——不改寫、不省略。

---

## 批次更新

多個 plugin 需要更新時：

```bash
# 批次更新沒有單一 PLUGIN_NAME，所以不用前導；marketplace 名由使用者指定（自己的引數，同樣核對
# [A-Za-z0-9._-]），不是從 manifest 讀出來代入。
MP_NAME='<marketplace-name>'
case "$MP_NAME" in ''|'<marketplace-name>'|.*|-*|*[!A-Za-z0-9._-]*) echo "✗ marketplace 名稱未代入或不合法" >&2; exit 1 ;; esac
# 1. 同步 marketplace（只需一次）
claude plugin marketplace update "$MP_NAME"

# 2. 逐一更新（需加 @marketplace 後綴）
claude plugin update "plugin-a@$MP_NAME"
claude plugin update "plugin-b@$MP_NAME"
```

---

## 常見問題

### Plugin 更新後 skill 沒變？
Claude Code 有快取機制。需要重啟才能載入新版 skill 內容。

### `failed to load` 錯誤？
通常是 hooks.json 格式問題：
```bash
# 自足的診斷 block（流程結束後或全新 session 也能跑）：不依賴 context 檔，直接反查。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME" in ''|.*|-*|*[!A-Za-z0-9._-]*) echo "✗ 名稱不合法" >&2; exit 1 ;; esac
IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$(find_plugin_marketplace "$PLUGIN_NAME")"
[ -d "${PLUGIN_DIR:-}" ] || { echo "✗ '$PLUGIN_NAME' 不在任何本機 marketplace（find_plugin_marketplace 無命中）" >&2; exit 1; }
echo "→ 檢查 ${MP_ROOT}（索引首命中；同名多份 checkout 時可能不是 Step 0.1 以 cwd 選到的那份——不確定就 cd 進目標 checkout 再跑）"
cd "$MP_ROOT" || exit 1
claude plugin validate "$PLUGIN_DIR"
```

### `marketplace update` 沒看到新版本？
1. 確認 `marketplace.json` 的版本號已更新
2. 確認已 push 到 remote：
```bash
# 自足的診斷 block（流程結束後或全新 session 也能跑）：不依賴 context 檔，直接反查。
PLUGIN_NAME='<plugin-name>'
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
case "$PLUGIN_NAME" in ''|.*|-*|*[!A-Za-z0-9._-]*) echo "✗ 名稱不合法" >&2; exit 1 ;; esac
IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$(find_plugin_marketplace "$PLUGIN_NAME")"
[ -d "${PLUGIN_DIR:-}" ] || { echo "✗ '$PLUGIN_NAME' 不在任何本機 marketplace（find_plugin_marketplace 無命中）" >&2; exit 1; }
echo "→ 檢查 ${MP_ROOT}（索引首命中；同名多份 checkout 時可能不是 Step 0.1 以 cwd 選到的那份——不確定就 cd 進目標 checkout 再跑）"
cd "$MP_ROOT" || exit 1
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
