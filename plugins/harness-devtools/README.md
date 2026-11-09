# harness-devtools

Claude Code 開發工具鏈 — plugin / MCP server / CLI 的完整發布管道。

## What is this?

一個問題的三種形狀：**「我寫了一個工具，怎麼把它發布出去？」**

- 寫的是 **Claude Code plugin** → `plugin-*` skills
- 寫的是 **MCP server**（Swift / Python / TypeScript）→ `mcp-*` skills
- 寫的是 **Swift CLI 工具** → `cli-*` skills

三者共用同一套發布觀念（版本 bump → build → sign → GitHub Release → marketplace 同步 → 安裝驗證），差別只在產物型態。

## 為什麼是一個 plugin 而不是三個

前身是三個獨立 plugin（`plugin-tools` / `mcp-tools` / `cli-tools`）。它們形成**循環依賴**：

```
  plugin-tools ─────→ mcp-tools      (mcp-deploy 被跨 plugin 引用 19 次)
       ↑    │              │
       │    └──→ cli-tools │
       └───────────────────┘          ← mcp-tools 反向呼叫 plugin-tools
```

而 Claude Code **沒有 plugin 依賴宣告機制**（`plugin.json` 沒有 `dependencies` 欄位）。只裝 `plugin-tools` 而不裝 `mcp-tools` 時，`plugin-update` 的 dependency-aware orchestration 會在呼叫 `/mcp-tools:mcp-deploy` 時找不到 skill，**而且沒有任何機制事先警告**。（此處刻意保留舊前綴——這句描述的正是合併前的失效情境。）

所以「分成三個讓使用者只裝需要的」是假選項——能選，但選了會靜默壞掉。合併成單一不可分割單元。

## 先看這個：哪個 skill、什麼順序

下面的表把 24 個 skill 逐條列出，但**逐條列表答不出「現在該跑哪一個」**——
而選錯的代價不對稱：`plugin-update` 對一個還沒上架的 plugin 會走進錯誤的 repo
（#16）。

判準是**這個 plugin 現在在哪裡**，不是「我想做什麼」：

| plugin 現在的狀態 | 跑什麼 |
|---|---|
| 還不存在 | `plugin-create` |
| 檔案在某個原始碼 repo 裡，**沒進過任何 marketplace** | `plugin-deploy`（首次上架）|
| 已在 marketplace，這次改了 skill / rule / hook | `plugin-update` |
| 已在 marketplace，這次改的是它依賴的 binary | 先在 binary 的 repo 跑 `mcp-deploy`（CLI 專案用 `cli-deploy`），再 `plugin-update` |

**binary-backed 的 plugin 首次上架是三步，不是一步**，而順序是依賴不是偏好：

```
① mcp-deploy    在 binary 的原始碼 repo 跑：編譯 → GitHub Release 上傳 asset
       ↓         （沒有這步，plugin-deploy 的 Step 2.5 會 BLOCK：release 沒 binary
                   ＝ 新使用者裝了 plugin 就壞）
② plugin-deploy 把 plugin 放進 marketplace repo、加 marketplace.json entry、push
       ↓
③ plugin-update 之後每次改 plugin shell 都跑這個
```

怎麼判斷是不是 binary-backed（`scripts/plugin-binary-meta.sh` 的 `plugin_is_binary_backed`，#22）：
`.mcp.json` 宣告了 plugin 內的 server（`command` 指向 `${CLAUDE_PLUGIN_ROOT}/…` 等；`{}`、遠端 `url`、`npx` 不算）、或 `bin/` 底下**任何檔案**含 release URL（`gh release download` /
`gh api …/releases` / `api.github.com/…/releases` / `github.com/…/releases/(download|tags|latest)`
——與 issue-driven-dev `idd-close` 的 `has_binary_wrapper` 逐字同一條；看 URL 形狀，不看檔名後綴或
變數名：`bin/che-keychain` 配 `REPO=` 也算；只算非註解行）、或 `hooks/` 底下**任何檔案**含同一 pattern、或 `plugin.json` 有
`binary_version` / `binaryVersion`——四者任一即是（`.mcp.json` 要宣告了 server 才算：`mcpServers` 非空，或 plugin 慣用的扁平格式 `{"<server>": {"command": …}}`）。一個 plugin 可以有多個
binary（che-telegram-mcp 兩支 wrapper），Phase 1.5 與 Phase 5 逐 wrapper / 逐 sidecar 驗。**binary 的 pin 是 wrapper 自己
決定的**：wrapper 內字面 `DESIRED_VERSION="x.y.z"`、或 wrapper 用 grep 讀的那個 plugin.json key、或都沒有（no-pin）——
不從 manifest 猜。「會下載的 wrapper」有 bin/ 時是 bin/（hooks/ 是 check script），沒有 bin/ 時是 hooks/（macdoc：hook 讀
`binary_version` 再自己下載）；兩支 wrapper 共用同一 pin 時 Case E 兩支都改。asset 名只認 wrapper 宣告的（`RELEASE_ASSET=` /
`ASSET_NAME=` / `BINARY_NAME=`），release 以 `v<pin>` tag 查。

## Skills

### Plugin 生命週期

| Skill | 用途 |
|---|---|
| `/harness-devtools:plugin-create` | 建立新 plugin，含目錄結構、marketplace.json 同步、CLAUDE.md 產生 |
| `/harness-devtools:plugin-upgrade` | 分析現有 plugin 缺什麼組件、過時格式，自動補上 |
| `/harness-devtools:plugin-deploy` | 發布到 marketplace（pre-flight + version bump + commit + push + sync）|
| `/harness-devtools:plugin-update` | 更新到最新版（marketplace.json 同步 + update + 安裝檢查），dependency-aware |
| `/harness-devtools:plugin-health` | 掃所有已安裝 plugin 的健康狀態（載入錯誤、版本不同步、hook 格式、binary 缺失）|
| `/harness-devtools:plugin-debug` | 深度除錯單一 plugin（hook 副作用、權限衝突、cache 版本不一致）|

### MCP Server

| Skill | 用途 |
|---|---|
| `/harness-devtools:mcp-new-app` | 互動式建立新 MCP Server 專案（Swift / Python / TypeScript）|
| `/harness-devtools:mcp-clone` | Clone 參考 MCP Server 到 `references/` 並分析可升級功能 |
| `/harness-devtools:mcp-clone-references` | Clone 競品原始碼進行分析 |
| `/harness-devtools:mcp-sign-pipeline` | 套用 Developer ID signing + notarization pipeline（macOS 26 TCC 必需）|
| `/harness-devtools:mcp-deploy` | 編譯、打包 mcpb、建立 GitHub Release |
| `/harness-devtools:mcp-publish` | 發布到官方 MCP Registry 及第三方平台（Glama、awesome-mcp-servers）|
| `/harness-devtools:mcp-install` | 從 GitHub Release 安裝到 `~/bin` |
| `/harness-devtools:mcp-upgrade` | 分析並提議專案升級（依賴、結構、新功能）|
| `/harness-devtools:mcp-sync` | 同步 binary（`.build` → `mcpb/server` → `~/bin` 一致性）|
| `/harness-devtools:mcp-test` | 完整功能測試（驗證所有 tools）|
| `/harness-devtools:mcp-diagnose` | 連線診斷（連線、binary、基本呼叫）|
| `/harness-devtools:mcp-debug` | 功能除錯（框架分析、權限問題、錯誤診斷）|
| `/harness-devtools:mcp-issue` | 快速對 MCP repo 開 issue |
| `/harness-devtools:mcp-to-plugin` | 把現有 MCP Server 包裝成完整 plugin（含 Keychain 密鑰管理）|

### Swift CLI

| Skill | 用途 |
|---|---|
| `/harness-devtools:cli-new-app` | 建立 Swift CLI 骨架（Package.swift + ArgumentParser + Version.swift）|
| `/harness-devtools:cli-deploy` | 編譯 universal binary、建立 GitHub Release、安裝到 `~/bin` |
| `/harness-devtools:cli-install` | 從 GitHub Release 安裝到 `~/bin` |
| `/harness-devtools:cli-upgrade` | 檢查並升級已安裝的 CLI 工具 |

## Rules

| Rule | 內容 |
|---|---|
| `mcp-binary-distribution.md` | binary-backed plugin 的 author-side 發布紀律（三 repo 依賴鏈）|
| `skill-description-budget.md` | skill description 的長度與觸發詞預算 |
| `tool-readme-sync-{plugin,mcp,cli}.md` | README 與工具實際能力的同步規則，三份分別對應三種產物型態 |

> 三份 `tool-readme-sync-*.md` 內容不同（141 / 156 / 177 行，md5 各異），是同一條規則在三個 plugin 中各自演化的 drift 分支。合併需逐條判斷哪些差異是刻意的，列為後續 issue。

## Scripts

`scripts/resolve-marketplace.sh` — marketplace 路徑解析的 single source of truth。

```bash
source scripts/resolve-marketplace.sh

resolve_marketplace_root che-plugin-devtools
# → ~/Developer/che-plugin-devtools

find_plugin_marketplace harness-devtools
# → che-plugin-devtools|~/Developer/che-plugin-devtools|~/Developer/che-plugin-devtools/plugins/harness-devtools
#   三欄（#18）：第三欄是 manifest plugins[].source 解析出的 plugin 目錄

resolve_plugin_dir ~/Developer/che-keychain che-keychain
# → ~/Developer/che-keychain/plugin
#   rc 0 目錄 / 1 未列且沒 plugins/<name> / 2 source 不可用 / 3 無可用 python3 / 4 manifest 讀不動
#   / 5 非本地 source（git-subdir 物件、URL）/ 6 名稱不合法；1–5 都先探 plugins/<name>，物化即命中
plugin_source_of <root> <plugin>           # source 值（去控制字元、截斷；rc 1 = manifest 未列，不做 legacy 探測、無 rc 6；印它用 printf 不用 echo）
marketplace_plugin_names <root>            # manifest 宣告 ∪ plugins/ 子目錄
git diff --name-only HEAD~3 | plugin_names_for_paths <root>   # 路徑 → plugin 名（不猜 plugins/<x>/ 佈局）
marketplace_index                          # name<TAB>root，一次走完
plugin_ctx_path <plugin>                   # 私有 state 目錄下的 context 檔路徑
write_plugin_ctx <file> <mp> <root> <dir> <plugin>   # Step 0.1 → 後續 fence 的 hand-off（驗證後 mktemp+mv 寫純資料檔）
load_plugin_ctx <file> <plugin>            # 逐行 parse（不 source）、拒絕 symlink / 非本人檔案、重驗（root 仍是該 marketplace 候選、resolve 結果一致）
remove_plugin_ctx <file>                   # Phase 5 結束清掉

marketplace_candidates che-local-plugins   # 一行一個 root，precedence 序
list_marketplaces                          # 所有已發現的名稱
```

取代先前散落 5 處的硬編碼 `psychquant-claude-plugins` 路徑。harness-devtools 搬到獨立 marketplace 後仍需管理其他 marketplace 的 plugin——工具住哪裡與工具管哪裡是兩回事。

**解析方式是掃描而非列舉**（#20）：掃搜尋根底下的 `*/.claude-plugin/marketplace.json`，讀各檔自報的 `name`。新增 marketplace 不必改程式碼。同名多候選時，擁有 `plugins/` 目錄的優先——那只是 **tie-break**，不是准入條件（單一 plugin 的 marketplace 沒有 `plugins/`，它的 repo 本身就是那個 plugin）。

**plugin 目錄從 manifest 讀，不猜佈局**（#18）：`find_plugin_marketplace` 與 `resolve_plugin_dir` 解析 `plugins[].source`；`./plugin`（單一 plugin）、`./plugins/<name>`（aggregator）、`.`（repo 即 plugin）都能命中——前提是 manifest 有這個 entry；entry 還沒寫的「新 plugin」狀態只對 `plugins/<name>` 佈局成立（Phase 2 Step 3 的範本也是 aggregator 形式）。plugin 的 manifest 可在 `.claude-plugin/plugin.json` 或根目錄 `plugin.json`，**讀它的每一處都經 `plugin_manifest_path`（`load_plugin_ctx` 給的 `$PLUGIN_MANIFEST`）**，不自己組路徑；沒有 manifest 的目錄（materialized subtree）能被解析但沒有 version 可同步，`plugin-update` Step 0.1 直接 abort 說明。manifest 給不出本地路徑時（沒 entry、git-subdir 物件、URL、JSON 壞掉、python3 跑不起來）才退回探 `plugins/<name>`——「不知道」不能變成「沒有」。兩者都失敗時 rc 分六類（1 未列 / 2 不可用 / 3 無 python3 / 4 讀不動 / 5 非本地 / 6 名稱不合法），`plugin-update` Step 0.1 據此指名真正的原因，不會一律講成「沒上架」。source 裡的引號 / `..` / `|` / 控制字元一律拒絕、目錄（含 legacy `plugins/<name>`）以實體路徑檢查仍在 root 內、持有判準只有一套：目錄若帶 plugin 的 manifest（`.claude-plugin/plugin.json` 或根目錄 `plugin.json`）就必須解析得動且 name 等於請求名；沒有 manifest 時目錄名要等於請求名且有 plugin 形狀（空目錄不算）。legacy `plugins/<name>` 只救「未列 / 無 python3 / 讀不動 / 非本地」，有 entry 但 source 寫錯是確定的錯誤不會被救回：路徑會進 git pathspec 與 python argv，不能讓第三方檔案內容變成程式碼或宣稱別人的 plugin。skill 的每個 bash block 是獨立的 Bash 呼叫，Step 0.1 以 `plugin_holders` 列舉持有該 plugin 的 checkout（解析到同一實體目錄的巢狀同名 marketplace 只算一個；真的多份時以 cwd 消歧、否則 abort 列出）、以 `write_plugin_ctx` 寫下驗證過的三元組（私有 state 目錄、純資料）、後續 block 以 `load_plugin_ctx` 逐行 parse 並重驗（失敗不設任何變數）——agent 只代入自己的引數；唯一會被貼回的第三方值是 marketplace 名，它在索引層就只保留 `[A-Za-z0-9._-]`。

### 發版 tag：`scripts/release-tag.sh`（#42）

四個發版 skill（`plugin-update` Phase 2.7、`plugin-deploy` Step 7.5、`mcp-deploy` Phase 3 Step 3a、`cli-deploy` Phase 3 Step 1.5）共用的 tag 實作。推送完成後，依**套件自己的版本**打 annotated tag 並推上去：

```bash
bash scripts/release-tag.sh --dir <版本根目錄> --commit HEAD --name-style v|plugin [--plugin <name>] \
     [--remote <remote>] [--expect <x.y.z>] [--at-bump] [--dry-run]
# → RELEASE_TAG: <tagged|exists|not-bumped|mismatch|unreadable|push-failed|dry-run> name=… commit=… version=… sources=…
```

- **版本從 commit 讀，不讀工作樹**；七種來源（封閉列舉）全部一致才打：plugin.json、pyproject 靜態版本、hatch `path` 指到的檔案（照 hatchling 的 regex source 讀：路徑先正規化、嚴格 UTF-8、預設或設定的 pattern、第一個符合的值；tag 是 hatch 讀到的版本字串，預發行版建 wheel 時 packaging 會再正規化，例如 `1.0.0-beta` 建成 `1.0.0b0`；其他 hatch source → 21）、package.json、`Sources/*/Version.swift`（`static let|var version|current`，可帶 `: String`；初始值必須整個是一個字串常值）、`mcpb/manifest.json`、`Sources/*/Server.swift`（`version: "x"` 必須是整個引數；只計以「數字.數字」開頭的字串，`"v1.2.3"`、`"dev"` 不算來源。檔案裡每個這種 `version:` 都算，不是套件版本的（例如回應結構的欄位）會讓發版停下——它是檔案裡唯一的 `version:` 時回 20（不一致），與真正的版本並存時回 21（兩個不同的值）：改成具名常數，或移出 Server.swift）。JSON 來源沒有 `version` 欄位、`Version.swift` 沒有這種宣告時都不算來源；Swift 的值不是一整個字串常值 → 21。Swift 先去掉註解（區塊註解可巢狀）。
- **`--at-bump` 的限制**：走訪沿 first-parent 歷史（branch 自己的 commit），用 merge commit 合併 PR 時 tag 打在 merge commit；看的是目前的路徑（hatch 版本檔改名會跟著走）；plugin 目錄整個搬家、搬家時又沒升版號的話，第一次跑會打在搬家的 commit。
- **pyproject 需要 python3 3.11 以上**（`tomllib`）。PATH 上第一個 `python3` 比較舊時（macOS 的 `/usr/bin/python3` 是 3.9），有 `pyproject.toml` 的 repo 一律 21（#48）。
- **bash 3.2 可用**：helper 在 macOS 內建的 `/bin/bash` 下也能跑，測試會在 `/bin/bash` 下把整套重跑一次。
- **打在哪個 commit**：
  - `plugin-update`、`plugin-deploy` 帶 `--at-bump`：從 HEAD 往回找（封閉列舉的路徑全部算，已刪除的來源也算），打在版本來源最後一次一起變成目前版本的那個 commit。沒升版號的發版因此得到 `exists`，tag 不會跟著每次推送往前移。找不到確定的 commit 時 → 21，不打在推測的 commit 上：往回走了 500 個 commit 還沒找到、shallow clone 的歷史在升版號之前就斷了（先 `git fetch --unshallow`）、或某個 commit 的來源讀不出值。之後若還有改動 plugin 目錄的 commit，stderr 會印出筆數：tag 不包含那些改動（squash merge 時兩者是同一個 commit）。還沒有版號 tag 的 plugin，第一次跑時會替目前版本補打；更早的版本不補。
  - `mcp-deploy`、`cli-deploy` 打在 HEAD，並帶 `--expect <release 的版本>`：檔案裡的版本與要發的版本不同 → 20，不打也不建 release；repo 沒有任何版本來源時用 `--expect` 的值。
- **什麼時候打**：四個 skill 都要 HEAD 已推到 upstream，而且 remote 上那個 branch 實際指向 HEAD（先比本機的 `@{u}`，再以 `git ls-remote` 問 remote；remote 被改寫或有人推了新 commit 時停下：`plugin-update`、`plugin-deploy` 可以 `git pull` 後重跑，`--at-bump` 仍會打在升版號的 commit；`mcp-deploy`、`cli-deploy` 打在 HEAD，pull 之後重跑會把 tag 打在別人的 commit，要先確認要發的是哪一個 commit），而且目前 branch 追蹤的 upstream branch 是 remote 的預設 branch（看 upstream，不看本機 branch 名）；feature branch 上 `plugin-update`、`plugin-deploy` 跳過，`mcp-deploy`、`cli-deploy` 停下不建 release。`plugin-update`、`plugin-deploy` 另外要求 plugin 目錄與 marketplace 是同一個 git repo。
- **owner/repo**：`mcp-deploy`、`cli-deploy` 從 upstream remote 的網址推出，host 必須正好是 `github.com`；ssh host alias、GitHub Enterprise 會停下，且不印出網址（可能帶憑證）。建 release 前確認 GitHub 上的 tag 就是剛推的那一個 tag 物件。
- **push URL**：remote 的 push URL 指向另一個 repo 時（`pushurl` 或 `pushInsteadOf`），helper 在推任何東西之前回 30；https 抓、ssh 推的同一個 repo 不算。
- **CI**：自動推的 tag 會觸發 `on: push: tags` 的 workflow。
- **tag 名稱**：
  - `mcp-deploy`、`cli-deploy`：固定 `v<version>`（wrapper 從 `releases/download/v<version>/…` 下載）。
  - `plugin-update`、`plugin-deploy`：只看佈局。plugin 目錄就是 git repo 的根目錄（repo 本身就是 plugin）→ `v<version>`；其他一律 `<plugin>-v<version>`，例如本 repo 的 `harness-devtools-v<version>`，binary repo 裡的 `./plugin` 是 `<plugin>-v<version>`（`v<version>` 留給 binary 的 release）。不看 marketplace 列了幾個 plugin，所以多加一個 plugin 不會改變既有 plugin 的 tag 名稱。
- **結束碼**：0 已打或已存在 / 10 同名 tag 已在另一個 commit 上（這個版本以前發過，或上次發版推完 tag 就停了；不移動）/ 20 來源不一致 / 21 讀不出或判斷不了 / 30 推送失敗（印重跑指令），或 push URL 指向別的 repo（什麼都沒推，沒有重跑指令，要先改 remote 設定）/ 2 引數錯誤。
- 不移動、不刪除 tag，不用 `--force`。

`plugin-update`、`plugin-deploy` 沒打成 tag 不中止（branch 已推送）；`mcp-deploy`、`cli-deploy` 沒打成就不建 release——沒有 tag 時 GitHub 會在 main 上自動建一個，那正是 #42 要避免的情況。

## 參考資源

Skill 寫法參考 Anthropic 官方 plugin 開發工具包：

- **GitHub**: https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- **官方 skills**（教學型）：`/plugin-dev:plugin-structure`、`/plugin-dev:skill-development`
- **本 plugin**（執行型）：直接建好、同步好、開好 issue

## History

v1.0.0 之前的 commit history 見 [`PsychQuant/psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)（遷移基準 `cfb8849`）。三個前身的最終版本：`plugin-tools` 1.18.0、`mcp-tools` 1.16.0、`cli-tools` 1.1.2。
