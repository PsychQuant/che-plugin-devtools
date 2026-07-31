# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
