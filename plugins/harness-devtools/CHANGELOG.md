# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.3.0] - 2026-08-26

### Fixed

- **`plugin-deploy` Step 2.5 的 BLOCK 對 75% 的 wrapper 從沒執行過**（#17）。
  它靠 `grep '^BINARY_NAME='` 與 `grep '^GITHUB_REPO='` 認出要查什麼，**抽不到就
  `continue`**——不 echo、不計入 `MCP_STALE`、不影響結束碼。使用者看到一片安靜，
  而 deploy 照常往下走。

  實測 `psychquant-claude-plugins` 的 12 個真實 wrapper：**只有 3 個**兩行都抽得到。
  野生有三種方言——`GITHUB_REPO=`+`BINARY_NAME=`、**`REPO=`**+`BINARY_NAME=`（8 個）、
  以及 binary 名當函式參數（agent-cacher、claude-ltm）。

  修法**不是**再多列舉一種寫法（雖然順手多認了 `REPO=`，那只減少誤報、不是保證）
  ——下一個方言還會出現。判準改成：**抽不出來就代表沒驗過，那必須說出來。**
  抽不到的 wrapper 逐一具名報出，並用 AskUserQuestion 三選一（已手動確認 /
  去補 wrapper / 中止），**預設中止**。

  修正後涵蓋率 25% → 92%，剩下的一個不再靜默。

- **`plugin-update` Phase 1.5 Signal 1 同一段**，同樣改成具名報出（該處是 warn 不是
  BLOCK，符合 plugin-update 的協助型定位，但沉默與「檢查過沒問題」不可區分）。

### 這是同一個失敗類別的第三次

`#16` 修的兩個（`resolve-marketplace.sh` 的 zsh word-split、`plugin-update` 不檢查
回傳碼）與本次是同一形狀：**失敗變成空字串，然後被當成沒事**。三次都不是「寫錯
邏輯」，是**沒有問「這個 API 失敗時我怎麼知道」**。

## [2.2.0] - 2026-08-26

### Fixed

- **`resolve-marketplace.sh` 在 zsh 下對每一個 plugin 都解析失敗**（#16）。
  `for mp in $MARKETPLACE_NAMES` 依賴 unquoted 變數的 word-split，而 zsh 預設不做
  那件事。這個檔案是被 `source` 的，所以跑它的是呼叫端的 shell——`#!/bin/bash`
  那行不生效，而 **Claude Code 的 Bash 工具跑在 zsh**。實測 `find_plugin_marketplace
  harness-devtools` 在 bash 回 0 並印出正確結果、在 zsh 回 1 且無輸出。改成換行
  分隔 + `while read`（here-doc，不是 pipe——pipe 的 subshell 會讓 `return 0` 只
  結束子 shell）。五個 skill 都 source 它。
- **`plugin-update` Phase 0 不檢查 marketplace 解析失敗**（#16）。`MP_NAME` /
  `MP_ROOT` 靜默變空字串後，Phase 0.3 的 `PLUGIN_DIR` 變成 `/plugins/<name>`
  （binary gate 整個失效），Phase 0.5 的 `cd "$MP_ROOT"` 成為 no-op ——**git state
  gate 因此跑在使用者當下所在的 repo 上，並邀請他 push 一個不相干的 repo**。
  新增 Step 0.1 marketplace resolution gate，abort 並指出正確的下一步
  （`plugin-deploy` 首次上架 / `plugin-create` / binary-backed 要先 `mcp-deploy`）。

### Added

- 測試套件新增 zsh 分支。先前整份測試只跑 bash（檔頭逐字寫著
  "Deliberately runs under /bin/bash"），**那正是上面第一個 bug 活下來的原因**。
  變異確認：改回空白分隔後 zsh 兩條紅、bash 全部照樣綠。
- README 新增「哪個 skill、什麼順序」段。先前 24 個 skill 逐條列出但沒有任何一處
  說明首次上架與後續同步的差別，而 `plugin-update` 的描述（marketplace.json 同步 +
  安裝檢查）字面上讀起來就像涵蓋首次上架。

## [2.1.0] - 2026-08-01

`mcp-upgrade` 新增 MCP protocol 版本維度，並修正它 description 與實作矛盾之處。做的是 #14。

### Added

- **`mcp-upgrade` Phase 1.5：Protocol 版本檢查（語言無關）**。

  Phase 1 查的是 **SDK 套件版本**（`swift-sdk 0.12.0`），Phase 1.5 查的是 **protocol 版本**（`YYYY-MM-DD`）—— 兩者是不同的東西，升一個不保證升另一個。此前 24 個 skill **沒有任何一個**處理後者（`grep -rl protocolVersion skills/` 零命中）。

  三段結構：

  1. **現查官方 current 版本** —— 版本號**不寫進 skill**。protocol 每隔數月換一次，寫死等於埋一個保證過期的事實（本輪 #11 剛因為同一個形狀吃虧）。
  2. **偵測專案宣告** —— 分三種情況判定，風險不同：硬編碼（最高，SDK 升級也不會帶動）／引用 SDK 常數（中）／未宣告（低）。
  3. **判定遷移工作量** —— 跨 breaking change 時列出該版 Negotiation 段實際要求的必要項，不報告成「改個字串」。

  「落後幾代」從 spec repo 的 `docs/specification/` 目錄取完整版本序列計算（`llms.txt` 只給 current 一個）。日期字串按 `YYYY-MM-DD` 字典序比較即等同時間序。取不到序列時**退回只報「落後 / 未落後」** —— 報不出代數是可接受的降級，報錯的代數不是。

  同步擴充 Phase 4 報告（新增 `🔌 Protocol 版本` 段）與 Phase 5 執行選項（落後時才出現「Protocol 版本遷移」）。

### Fixed

- **`mcp-upgrade` description 與實作矛盾**。原文寫「本 skill 只分析與提議、**不改動 code**」，但它的 `allowed-tools` 含 `Write, Edit`，且 Phase 5「等待核可並執行」會編輯 `Package.swift`、跑 `swift package update` / `npm update` / `pip install --upgrade`。

  那句話是 v2.0.0（27 個 description 重寫）時寫的 —— 當時讀了 Phase 0–3 就下結論，**沒讀到 Phase 5**。而該次自訂的流程第 2 條正是「讀該 skill 的 SKILL.md body，觸發語要從它實際會做的事提煉，不能憑名字猜」；照做了，但讀得不夠遠。新 description 明確寫出「核可的項目才動手改」及會執行的實際指令。

- **偵測腳本漏排除建置產物**（實作過程中自己踩到並修正）。`.build/checkouts/` 底下是整包 MCP SDK 原始碼，當然含 `protocolVersion` 與各版本日期；不排除的話，一個「未宣告、完全交給 SDK」的乾淨專案會被報成「硬編碼三個版本」。

  **這個坑在 Claude Code 環境裡看不到** —— 它注入的 `grep` 實為 `ugrep --ignore-files`，自動遵守 `.gitignore`（`.build/` 正在裡面）。同一個專案：原生 `grep` 掃出 184 行、Claude Code 的 `grep` 掃出 0 行。skill 交付給原生環境跑，必須自己寫 `--exclude-dir`。

## [2.0.3] - 2026-08-01

修 2.0.2 引入的 live bug：resolver 確定地指向四個月前的過時原始碼。修的是 #11。

### Fixed

- **`MCP_ROOTS_SPEC` 順序：`che-msg` 移到 `che-mcps` 之前。**

  `che-telegram-all-mcp` / `che-telegram-bot-mcp` 在兩處都有，但**不是同一個專案的兩份副本**：

  | | `che-msg/` | `che-mcps/` |
  |---|---|---|
  | 形態 | monorepo 子目錄（無自己的 `.git`）| 獨立 clone（有自己的 `.git`）|
  | remote | `PsychQuant/che-msg` | `kiki830621/che-telegram-*-mcp` |
  | 最後 commit | **2026-06-14** | 2026-02-22 |
  | 檔案結構 | 重構後（`TelegramAllLib/`、`CLIBootstrap.swift`…）| 重構前（`TDLibClient.swift`）|

  舊順序把 `che-mcps` 排前面，於是六個 `mcp-*` skill 被確定地導向**落後四個月**的原始碼。#2 的 closing summary 寫「resolver 依 precedence 取 che-mcps 那份，行為確定且有測試 pin 住，所以工具層安全」—— 前半正確、結論錯誤。**確定不等於正確**：測試 pin 住的是「第一個 root 勝出」這條規則，不是「勝出的那份是對的」。

- **同名遮蔽從靜默變可見**。`resolve_mcp_project` 現在偵測「同一名稱存在於多個 umbrella」，往 **stderr** 印出全部候選並標明取了哪個。stdout 仍只有單一路徑，呼叫端的 `cd "$(resolve_mcp_project x)"` 不受影響。

  這正是本 issue 的根因形狀：靜默地在數份同名之中挑一個，挑錯了也沒有任何訊號。無遮蔽時不印任何東西（不製造雜訊）。

### Added

- **`mcp_project_candidates <name>`** —— 依 precedence 順序列出所有候選路徑。讓「有幾份、分別在哪」成為可查詢的事實，而非只能從警告訊息推斷。

**未做的事**：本機 `~/Developer/che-mcps/che-telegram-{all,bot}-mcp` 這兩個過時 clone **未刪除** —— 那是不可逆的資料層動作，留給使用者決定。resolver 現在不會取到它們，且若取到會警告，所以留著不影響正確性。

## [2.0.2] - 2026-07-31

六個 `mcp-*` skill 有 11 處指向一個**已經不存在**的專案目錄。修的是 #2。

### Fixed

- **11 處硬編碼 `~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/<name>`** —— 該路徑在本機不存在（連 `projects/mcp` 那層都沒有）。

  **失效方式是靜默的**：`cd <deadpath>/$1` 沒帶 `2>/dev/null &&`，`cd` 失敗後 shell 照樣往下執行，於是 `mcp-debug` / `mcp-test` / `mcp-diagnose` 會對**呼叫者當時的 cwd** 做檢查、建 `logs/`、然後回報結果。看起來成功，對象卻是錯的專案。

  改用新的 `scripts/resolve-mcp-project.sh`；找不到時 `require_mcp_project` 印出搜尋過的位置與可用專案清單並回非零。

### Added

- **`scripts/resolve-mcp-project.sh`** —— MCP 專案路徑的 single source of truth，與 `resolve-marketplace.sh` 同構。25 個測試（fixture 以覆寫 `HOME` 建合成樹，因此 precedence 與收錄判準都可測，且順帶 pin 住「root 是 HOME 相對而非絕對路徑」這個契約）。

  三個 umbrella 各有收錄模式：

  | Root | Mode | 理由 |
  |---|---|---|
  | `~/Developer/che-mcps` | `any` | 主 umbrella，含共用 library |
  | `~/Developer/che-msg` | `any` | telegram 家族自己的 umbrella |
  | `~/Developer` | `mcp-suffix` | 一般目錄，只收 `*-mcp` |

  兩個判準都是實測校正出來的，不是預設對的：

  - **`~/Developer` 若當成 `any`**，`list_mcp_projects` 會從 24 個變成 **42 個** —— 多出的 22 個是 `macdoc` / `rush` / `safari-browser` 等與 MCP 無關的 Swift package，會讓錯誤訊息裡的「可用的專案」清單反而誤導人。
  - **收錄判準若只認 `Package.swift`**，會靜默漏掉 `iss-compute-mcp` —— 它是 Python，只有 `requirements.txt`。改為接受任一語言的 package metadata。

### Notes（診斷推翻了 issue 的原假設）

#2 原本寫「需先定組織原則」，理由是 `che-telegram-mcp` 內嵌在 `psychquant-claude-plugins/plugins/` 而非 `che-mcps/`。**那句話是錯的**：該目錄底下 `find -name Package.swift` 回 0 —— 它是下載 binary 的 plugin wrapper，不是原始碼專案。真正的 telegram MCP 在 `che-mcps/` 與 `che-msg/` 底下。

所以本次**不搬動任何專案**，只加一支能跨 umbrella 解析的函式。順帶查到一件確實需要決定、但不屬本 issue 的事：`che-telegram-all-mcp` 與 `che-telegram-bot-mcp` 在 `che-mcps/` 與 `che-msg/` **各有一份不同 inode 的實體目錄**（不是 symlink）。resolver 依 precedence 取 `che-mcps` 那份，但兩份副本本身該不該合併，留待另開 issue。

## [2.0.1] - 2026-07-31

修掉改名後殘留的失效引用，並補上一支讓這類殘留可機械偵測的檢查腳本。修的是 #1。

### Added

- **`scripts/check-skill-references.sh`** —— 掃全 repo 找出「指向不存在 skill 的引用」與「已退役的 plugin 前綴」。exit 0 全過 / 1 有 findings / 2 路徑錯，附 `--format tsv` 供 CI 消費。15 個測試（`test-check-skill-references.sh`）。

  **為什麼需要它**：改名的成本不在改名本身，在引用的長尾。本 repo 踩過兩代 —— `changelog-tools → doc-tools → doc-guardian`。第二次改名時掃的是「當前名字」，所以寫著更早的 `changelog-tools` 的引用**搜不到、也就沒人知道它們存在**，一路存活到兩代之後。skill 引用不像 `import`，指向不存在的目標時是完全靜默的。

  刻意的前瞻／歷史引用不需 allowlist 檔：同一行寫明 `Phase 2` / `尚未實作` / `刻意保留` 等字樣即跳過，`CHANGELOG.md` 與 `test-*` 整份跳過（前者的舊名是當時的事實，後者的舊名是 fixture 資料）。

### Fixed

- **`rules/tool-readme-sync-plugin.md` 與 `skills/plugin-deploy/SKILL.md` 指向 `mcp-tools/rules/tool-readme-sync.md`** —— 該路徑在合併後已不存在。改為同目錄的 `tool-readme-sync-mcp.md`。

- **`rules/tool-readme-sync-plugin.md` 的 marketplace 審計範例硬編碼絕對路徑**（`/Users/che/Developer/psychquant-claude-plugins/`）。改為 `resolve-marketplace.sh` —— 那支腳本正是 v1.0.0 為了消滅這類硬編碼而寫的，這處是漏網的第 6 處。同段落把「plugin 都住在 `psychquant-claude-plugins`」的單一 marketplace 假設一併泛化。

- **`hooks/post-push-deploy-reminder.sh` 印出 `/mcp-tools:mcp-deploy`** —— 那是給使用者照著打的提示，前綴已失效。

**刻意未改的兩處**：`README.md` 中解釋「合併前為何會靜默斷裂」的那句仍寫 `/mcp-tools:mcp-deploy` —— 它描述的正是合併前的情境，改成新前綴會讓句子自相矛盾。同理 `CLAUDE.md` 裡「不要用舊的 `/plugin-tools:` 前綴」的反例。兩處都已標註，檢查腳本據此跳過。

## [2.0.0] - 2026-07-31

### Changed

- **plugin 更名 `devtools` → `harness-devtools`**（breaking）。呼叫方式由 `/devtools:*` 改為 `/harness-devtools:*`；**skill 名不變**。

  舊名的問題不是已經撞名，而是**沒說出它管什麼**。環境中 `agent-sdk-dev` / `mcp-server-dev` / `plugin-dev` / `feature-dev` 都指明了對象，`devtools` 是唯一只說「開發工具」的；加上官方 `chrome-devtools-mcp` 名稱相近，容易混淆。新名指明範圍 —— 它管的是 **Claude Code harness 這一層**（plugin、MCP server、CLI、skill），而 `harness` 正是官方用語。

  改名時機選在此刻：僅本機安裝、無外部使用者、0 stars / 0 forks，成本最低。101 處 `/devtools:` 引用 + 28 個檔案以機械替換完成，`che-plugin-devtools`（repo / marketplace 名）的 31 處未受影響 —— 替換用 negative lookbehind 排除 `che-plugin-` 與已替換的 `harness-` 前綴。

  本檔 v1.0.0 entry 內的 `/devtools:*` 字樣**刻意保留**：那是當時的事實。

- **16 個 skill 的 description 重寫**，依 invocation 模式採兩種寫法：

  - **auto-invocation**（`cli-*` 4 個 + `mcp-test` / `mcp-debug` / `mcp-diagnose` / `mcp-issue`）—— 四段結構（做什麼 / Use when / 防止的失敗）。其中三個「診斷」類的第四段改寫為**與鄰近 skill 的分工**，因為它們最大的失敗模式不是沒被觸發，是觸發錯的那一個（`diagnose` 連線層 / `debug` 功能層 / `test` 全面驗證）。
  - **manual-only**（8 個 `mcp-*`，`disable-model-invocation: true`）—— **不寫觸發語**（寫了也永遠不會 fire），改為「做什麼 + 與鄰近 skill 的分工」。此組有兩對極易混淆：`clone` vs `clone-references`（已知 URL vs 要先搜尋）、`deploy` vs `publish` vs `sync` vs `install`（發到自己 Release / 上架官方 Registry / 三處 binary 一致性 / 從 Release 裝到本機）。

  desc 字元數：`cli-*` 42–85 → 245–344；`mcp-*` auto 29–60 → 242–278；`mcp-*` manual 38–67 → 168–222。全部改用 YAML block scalar。

**Migration**

```bash
claude plugin uninstall devtools@che-plugin-devtools
claude plugin install harness-devtools@che-plugin-devtools
```

其他 repo 或個人筆記中的 `/devtools:*` 引用需一併更新為 `/harness-devtools:*`。


## [1.0.0] - 2026-07-30

首個版本。由三個既有 plugin 合併而成，遷入新 marketplace `che-plugin-devtools`。

### Added

- **`scripts/resolve-marketplace.sh`** — marketplace 路徑解析的 single source of truth。提供 `resolve_marketplace_root <name>` 與 `find_plugin_marketplace <plugin>` 兩個函數，取代先前散落在 5 處 SKILL.md / rules 的硬編碼 `psychquant-claude-plugins` 路徑。
- 24 個 skills 並置於單一 plugin：`plugin-*`(6) / `mcp-*`(14) / `cli-*`(4)，前綴天然不衝突，呼叫方式由 `/plugin-tools:plugin-update` 改為 `/devtools:plugin-update`（其餘同理）。

### Changed

- **合併三個前身 plugin**：`plugin-tools` 1.18.0 + `mcp-tools` 1.16.0 + `cli-tools` 1.1.2 → `devtools` 1.0.0。

  合併理由：三者形成循環依賴（`plugin-tools` ↔ `mcp-tools` 雙向，`cli-tools` → `mcp-tools`），`mcp-deploy` 一支就被跨 plugin 引用 19 次；而 Claude Code **沒有 plugin 依賴宣告機制**（`plugin.json` 無 `dependencies` 欄位）。分開安裝時，只裝其中一個會讓 `plugin-update` 的 dependency-aware orchestration 在呼叫 `/mcp-tools:mcp-deploy` 時找不到 skill，**且無任何事前警告**。「可選擇性安裝」在此 call graph 下是假選項。

- **`rules/tool-readme-sync.md` 拆為三份並存**，內容逐位元不變：
  - `tool-readme-sync-plugin.md`（141 行，md5 `8348f73a…`）
  - `tool-readme-sync-mcp.md`（156 行，md5 `85040e3b…`）
  - `tool-readme-sync-cli.md`（177 行，md5 `b3049168…`）

  三份原本同名但 md5 各異，是已各自演化的 drift 分支而非複製品。合併需逐條判斷哪些差異是刻意的，屬內容判斷而非搬家動作，故延後為獨立 issue 處理——以保住本次遷移「行為完全一樣」這個可驗證的成功條件。

**Migration notes**

- v1.0.0 之前的 commit history 見 [`PsychQuant/psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)，遷移基準 commit `cfb8849`。三個前身各自的 CHANGELOG 保留於該 repo。
- 舊呼叫方式 `/plugin-tools:*`、`/mcp-tools:*`、`/cli-tools:*` 一律改為 `/devtools:*`，skill 名本身不變。

[Unreleased]: https://github.com/PsychQuant/che-plugin-devtools/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/PsychQuant/che-plugin-devtools/releases/tag/v2.0.0
[1.0.0]: https://github.com/PsychQuant/che-plugin-devtools/releases/tag/v1.0.0
