# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
