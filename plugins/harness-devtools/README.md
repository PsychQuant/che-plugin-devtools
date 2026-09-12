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

怎麼判斷是不是 binary-backed：`plugin.json` 有 `mcpServers`、或 `bin/` 底下有
wrapper script、或 hook 會去 curl GitHub Release——三者任一即是。

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
plugin_source_of <root> <plugin>           # source 值（去控制字元、截斷；同 rc 表）
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

**plugin 目錄從 manifest 讀，不猜佈局**（#18）：`find_plugin_marketplace` 與 `resolve_plugin_dir` 解析 `plugins[].source`；`./plugin`（單一 plugin）、`./plugins/<name>`（aggregator）、`.`（repo 即 plugin）都能命中——前提是 manifest 有這個 entry；entry 還沒寫的「新 plugin」狀態只對 `plugins/<name>` 佈局成立（Phase 2 Step 3 的範本也是 aggregator 形式）。plugin 的 manifest 可在 `.claude-plugin/plugin.json` 或根目錄 `plugin.json`。manifest 給不出本地路徑時（沒 entry、git-subdir 物件、URL、JSON 壞掉、python3 跑不起來）才退回探 `plugins/<name>`——「不知道」不能變成「沒有」。兩者都失敗時 rc 分六類（1 未列 / 2 不可用 / 3 無 python3 / 4 讀不動 / 5 非本地 / 6 名稱不合法），`plugin-update` Step 0.1 據此指名真正的原因，不會一律講成「沒上架」。source 裡的引號 / `..` / `|` / 控制字元一律拒絕、目錄（含 legacy `plugins/<name>`）以實體路徑檢查仍在 root 內、持有判準只有一套：目錄若帶 plugin 的 manifest（`.claude-plugin/plugin.json` 或根目錄 `plugin.json`）就必須解析得動且 name 等於請求名；沒有 manifest 時目錄名要等於請求名且有 plugin 形狀（空目錄不算）。legacy `plugins/<name>` 只救「未列 / 無 python3 / 讀不動 / 非本地」，有 entry 但 source 寫錯是確定的錯誤不會被救回：路徑會進 git pathspec 與 python argv，不能讓第三方檔案內容變成程式碼或宣稱別人的 plugin。skill 的每個 bash block 是獨立的 Bash 呼叫，Step 0.1 以 `write_plugin_ctx` 寫下驗證過的三元組（私有 state 目錄、純資料）、後續 block 以 `load_plugin_ctx` 逐行 parse 並重驗——agent 只代入自己的引數。

## 參考資源

Skill 寫法參考 Anthropic 官方 plugin 開發工具包：

- **GitHub**: https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- **官方 skills**（教學型）：`/plugin-dev:plugin-structure`、`/plugin-dev:skill-development`
- **本 plugin**（執行型）：直接建好、同步好、開好 issue

## History

v1.0.0 之前的 commit history 見 [`PsychQuant/psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)（遷移基準 `cfb8849`）。三個前身的最終版本：`plugin-tools` 1.18.0、`mcp-tools` 1.16.0、`cli-tools` 1.1.2。
