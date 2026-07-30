# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/PsychQuant/che-plugin-devtools/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/PsychQuant/che-plugin-devtools/releases/tag/v1.0.0
