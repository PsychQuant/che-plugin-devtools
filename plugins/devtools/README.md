# devtools

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

而 Claude Code **沒有 plugin 依賴宣告機制**（`plugin.json` 沒有 `dependencies` 欄位）。只裝 `plugin-tools` 而不裝 `mcp-tools` 時，`plugin-update` 的 dependency-aware orchestration 會在呼叫 `/mcp-tools:mcp-deploy` 時找不到 skill，**而且沒有任何機制事先警告**。

所以「分成三個讓使用者只裝需要的」是假選項——能選，但選了會靜默壞掉。合併成單一不可分割單元。

## Skills

### Plugin 生命週期

| Skill | 用途 |
|---|---|
| `/devtools:plugin-create` | 建立新 plugin，含目錄結構、marketplace.json 同步、CLAUDE.md 產生 |
| `/devtools:plugin-upgrade` | 分析現有 plugin 缺什麼組件、過時格式，自動補上 |
| `/devtools:plugin-deploy` | 發布到 marketplace（pre-flight + version bump + commit + push + sync）|
| `/devtools:plugin-update` | 更新到最新版（marketplace.json 同步 + update + 安裝檢查），dependency-aware |
| `/devtools:plugin-health` | 掃所有已安裝 plugin 的健康狀態（載入錯誤、版本不同步、hook 格式、binary 缺失）|
| `/devtools:plugin-debug` | 深度除錯單一 plugin（hook 副作用、權限衝突、cache 版本不一致）|

### MCP Server

| Skill | 用途 |
|---|---|
| `/devtools:mcp-new-app` | 互動式建立新 MCP Server 專案（Swift / Python / TypeScript）|
| `/devtools:mcp-clone` | Clone 參考 MCP Server 到 `references/` 並分析可升級功能 |
| `/devtools:mcp-clone-references` | Clone 競品原始碼進行分析 |
| `/devtools:mcp-sign-pipeline` | 套用 Developer ID signing + notarization pipeline（macOS 26 TCC 必需）|
| `/devtools:mcp-deploy` | 編譯、打包 mcpb、建立 GitHub Release |
| `/devtools:mcp-publish` | 發布到官方 MCP Registry 及第三方平台（Glama、awesome-mcp-servers）|
| `/devtools:mcp-install` | 從 GitHub Release 安裝到 `~/bin` |
| `/devtools:mcp-upgrade` | 分析並提議專案升級（依賴、結構、新功能）|
| `/devtools:mcp-sync` | 同步 binary（`.build` → `mcpb/server` → `~/bin` 一致性）|
| `/devtools:mcp-test` | 完整功能測試（驗證所有 tools）|
| `/devtools:mcp-diagnose` | 連線診斷（連線、binary、基本呼叫）|
| `/devtools:mcp-debug` | 功能除錯（框架分析、權限問題、錯誤診斷）|
| `/devtools:mcp-issue` | 快速對 MCP repo 開 issue |
| `/devtools:mcp-to-plugin` | 把現有 MCP Server 包裝成完整 plugin（含 Keychain 密鑰管理）|

### Swift CLI

| Skill | 用途 |
|---|---|
| `/devtools:cli-new-app` | 建立 Swift CLI 骨架（Package.swift + ArgumentParser + Version.swift）|
| `/devtools:cli-deploy` | 編譯 universal binary、建立 GitHub Release、安裝到 `~/bin` |
| `/devtools:cli-install` | 從 GitHub Release 安裝到 `~/bin` |
| `/devtools:cli-upgrade` | 檢查並升級已安裝的 CLI 工具 |

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
# → /Users/che/Developer/che-plugin-devtools

find_plugin_marketplace akashic-mcp
# → psychquant-claude-plugins|/Users/che/Developer/psychquant-claude-plugins
```

取代先前散落 5 處的硬編碼 `psychquant-claude-plugins` 路徑。devtools 搬到獨立 marketplace 後仍需管理其他 marketplace 的 plugin——工具住哪裡與工具管哪裡是兩回事。

## 參考資源

Skill 寫法參考 Anthropic 官方 plugin 開發工具包：

- **GitHub**: https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- **官方 skills**（教學型）：`/plugin-dev:plugin-structure`、`/plugin-dev:skill-development`
- **本 plugin**（執行型）：直接建好、同步好、開好 issue

## History

v1.0.0 之前的 commit history 見 [`PsychQuant/psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)（遷移基準 `cfb8849`）。三個前身的最終版本：`plugin-tools` 1.18.0、`mcp-tools` 1.16.0、`cli-tools` 1.1.2。
