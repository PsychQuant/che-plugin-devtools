# harness-devtools — CLAUDE.md

## Purpose

Claude Code 開發工具鏈：plugin / MCP server / Swift CLI 的完整發布管道。三個領域共用同一套發布觀念，差別只在產物型態。

## 這個 plugin 的邊界

**是**：把「我寫好的工具」變成「別人裝得到的東西」——建立骨架、版本管理、build、sign、Release、marketplace 同步、安裝驗證、診斷。

**不是**：寫工具本身的內容。Swift 語言問題找 `apple-xcode-skills`，文件紀律找 `doc-guardian`。

## Marketplace 路徑解析（重要）

**永遠不要在 skill 裡硬編碼 marketplace 路徑。** 用 `scripts/resolve-marketplace.sh`：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-marketplace.sh"

MARKETPLACE_ROOT=$(resolve_marketplace_root che-plugin-devtools)

# 或反查：給 plugin 名，找它在哪個 marketplace
IFS='|' read -r MP_NAME MP_ROOT <<< "$(find_plugin_marketplace akashic-mcp)"

# 同名多候選時看得到 shadowing（一行一個 root，precedence 序）
marketplace_candidates che-local-plugins
```

**為什麼**：harness-devtools 住在 `che-plugin-devtools`，但它管理的 plugin 分布在 `psychquant-claude-plugins`(28)、`sinica-claude-plugins`(2)、`che-local-plugins`(8) 等多個 marketplace。工具住哪裡與工具管哪裡是兩回事。v1.0.0 之前有 5 處把 `psychquant-claude-plugins` 寫死，是單一 marketplace 假設的殘留。

**新增 marketplace 不必改任何程式碼**（#20）。resolver 掃搜尋根底下的
`*/.claude-plugin/marketplace.json`，讀各檔**自報的 `name`**——不是目錄名，兩者
13/33 不同（`bestasr` 住在 `bestASR-project/bestASR`）。在此之前是兩份必須手動
同步的硬編清單，各只有 4 筆，漏掉本機 33 個裡的 29 個。

## MCP 專案路徑解析（同理）

**永遠不要在 skill 裡硬編碼 MCP 專案路徑。** 用 `scripts/resolve-mcp-project.sh`：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-mcp-project.sh"

cd "$(require_mcp_project "$1")" || exit 1   # 找不到會列出可用專案並回非零
PROJ=$(resolve_mcp_project che-ical-mcp)      # 純查詢，找不到回非零、無輸出
list_mcp_projects                             # 所有已知專案
```

專案分佈在三個 umbrella，`MCP_ROOTS_SPEC` 定義搜尋順序與收錄規則：

| Root | Mode | 意義 |
|---|---|---|
| `~/Developer/che-mcps` | `any` | 主 umbrella，任何帶 package metadata 的子目錄都算（含共用 library）|
| `~/Developer/che-msg` | `any` | telegram 家族自己的 umbrella |
| `~/Developer` | `mcp-suffix` | 一般目錄，**只收 `*-mcp`** —— 否則 `macdoc` / `rush` 等 22 個無關 Swift package 會被誤收 |

**為什麼**：v2.0.1 之前有 11 處硬編碼 `~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/`，那個路徑**已經不存在**。裸 `cd <deadpath>/$1`（不帶 `2>/dev/null &&`）失敗後 shell 繼續往下跑，skill 就對呼叫者當時的 cwd 做檢查並回報 —— 錯的專案，沒有任何錯誤訊息。

收錄判準是「有任一語言的 package metadata」而非只認 `Package.swift`：`iss-compute-mcp` 是 Python（只有 `requirements.txt`），Swift-only 的判準會靜默漏掉它。

新增 umbrella 時只改 `MCP_ROOTS_SPEC` 一處。

## 三個領域的 skill 命名

| 前綴 | 產物 | 典型鏈路 |
|---|---|---|
| `plugin-*` | Claude Code plugin | create → upgrade → deploy → update → health/debug |
| `mcp-*` | MCP server | new-app → sign-pipeline → deploy → publish → test/diagnose |
| `cli-*` | Swift CLI | new-app → deploy → install → upgrade |

前綴天然不衝突（已驗證 24 個 skill 零重名），合併後可直接並置。

## 跨 skill 呼叫

`plugin-update` 是 dependency-aware orchestrator：偵測到 binary-backed plugin 時會呼叫 `mcp-deploy` 或 `cli-upgrade`。合併成單一 plugin 後這些呼叫**保證解析得到**——這正是合併的主要理由（見 README「為什麼是一個 plugin 而不是三個」）。

skill 之間互相引用時用 `/harness-devtools:<skill-name>`，不要用舊的 `/plugin-tools:` / `/mcp-tools:` / `/cli-tools:` 前綴。

## Plugin 標準結構（快速參考）

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json          ← 唯一必要檔案
├── skills/                  ← SKILL.md files
├── agents/                  ← agent definitions
├── hooks/                   ← hooks.json
├── rules/                   ← 領域規則
├── .mcp.json                ← MCP servers
└── README.md                ← 分享前建議加
```

> `skills/`、`hooks/`、`agents/` 在 plugin root，**不在** `.claude-plugin/` 裡面。

## 版本同步紀律

改任何 plugin 都必須同步兩處，否則 `claude plugin update` 會說 already at latest 而跳過：

1. `plugins/<name>/.claude-plugin/plugin.json` 的 `version`
2. `.claude-plugin/marketplace.json` 對應 entry 的 `version`

CHANGELOG.md 遵循 Keep a Changelog 1.1.0，由 `/doc-guardian:changelog-validate` 驗證三方同步（CHANGELOG ↔ plugin.json ↔ marketplace.json）。

## 參考資源

- Anthropic 官方 plugin-dev：https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- 官方 skills（教學型）：`/plugin-dev:plugin-structure`、`/plugin-dev:skill-development`
- 本 plugin（執行型）：直接建好、同步好、開好 issue
