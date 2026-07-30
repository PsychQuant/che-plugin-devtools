# MCP Tool List ↔ README 同步紀律

當 MCP Server 的 tool 集合（`tools/list` 所回傳的項目）變動時，**必須**在同一個 commit（或同一個 release 週期內）更新 README。

## 為什麼

MCP server 的 README 是 **使用者契約**。它同時被三種讀者消費：

| 讀者 | 讀 README 的目的 |
|------|----------------|
| 人類開發者 | 決定要不要裝、裝完知道能做什麼 |
| AI agent / LLM | 計劃任務時判斷此 MCP 有沒有提供它需要的 tool |
| Plugin / marketplace index | 自動生成 tool 列表、keywords、description |

README 和實際 `tools/list` 脫鉤造成的後果：

- 使用者在 README 找得到的 tool 實際不存在 → bug report 湧入
- 實際存在的 tool 沒列在 README → LLM agent 永遠不會嘗試呼叫它（資源浪費）
- Tool 數量過時（「146 tools」寫到半年後才改成 165）→ 在比較表上給競品空間

## 觸發條件（必須同步 README）

滿足任一條件即啟動：

1. **新增 tool** — `tools/list` 多出一個 name
2. **移除 tool** — name 消失（BREAKING，CHANGELOG 也要寫）
3. **重命名 tool** — name 改變
4. **Schema 實質改變** — 必填欄位增減、behavior 反轉（如 track_changes 預設值翻轉）
5. **tool 總數改變** — README 開頭或 comparison table 的數字要跟著動

僅內部重構（private helper 改名、implementation 重寫但對外介面不變）→ 不需要 README。

## 必要的 README 改動範圍

| 改動 | README 連動 |
|------|------------|
| 加/減/改 tool | 對應的工具表格那一列 |
| tool 總數變 | Features 列表、Comparison table、Available Tools heading |
| 新增工具分類（如加了 Session State API 這一整類） | 新增一個獨立 section + 更新目錄 |
| 重大版本（v2.0.0 / v3.0.0） | Version History 表新增一列，註明 BREAKING |
| Dependencies 改了 | Technical Details → Dependencies 區塊 |

## Deploy 前的自我檢查

`mcp-deploy` skill 跑完**前**做這個檢查：

```bash
# 跑起來後用 JSON-RPC 抓實際 tool count
TOOL_COUNT=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  ./CheXxxMCP | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['tools']))")

# 抓 README 宣稱的 tool count
README_COUNT=$(grep -oE '[0-9]+ MCP Tools' README.md | head -1 | grep -oE '[0-9]+')

# 不一致就警告
[ "$TOOL_COUNT" = "$README_COUNT" ] || echo "⚠️ README 宣稱 $README_COUNT, 實際 $TOOL_COUNT"
```

## 當多個版本累積才發現 README 落後時

像 che-word-mcp v2.0.0 → v3.1.0 累積 8 個版本都沒更新 README 的情況，補救方式：

1. **批量更新 Version History 表** — 不要只補最新一版，把中間被漏掉的全部補回（讓歷史可追溯）
2. **工具表按 category 重新掃一次** — 不要只加新 tool，檢查舊 tool 的描述是否還正確（可能有 BREAKING 沒記）
3. **Comparison table / feature bullets 全面重掃** — 這些是最容易過時的位置
4. **雙語版同步** — 如果有 README_zh-TW.md 或其他語言，一次全改

## GitHub Repo About Metadata（和 README 同等級的使用者第一印象）

README 是 repo 內部文件；**GitHub repo 首頁右側的 About 面板** 是外部的「名片」。Search engine、Topics 瀏覽頁、marketplace 聚合器都讀這塊，不讀 README。

Tool 集合變動時，**這三項也要檢查**：

| 欄位 | 位置 | 應該同步的時機 |
|------|------|-------------|
| **Description**（~350 字短介紹）| `gh repo view --json description` | Tool 總數改變、加了新 category（如 session state、readback）、或 BREAKING 變更 |
| **Topics**（最多 20 個標籤）| `gh repo view --json repositoryTopics` | 加了新功能領域（例如原本純 MCP → 加了 manuscript-review 類 tool）|
| **Homepage URL** | `gh repo view --json homepageUrl` | 通常指 `releases` 頁；改過 binary 發布位置時才動 |

### Description 的三層結構模板

```
[What] {Swift-native MCP server for X with N tools} —
[Differentiator] {first direct OOXML library / native EventKit / no X process required} —
[Features] {Feature A, Feature B, Feature C, Feature D} —
[Use case] {Optimized for Y workflow}
```

範例（che-word-mcp v3.1.0）：

> Swift-native MCP server for Microsoft Word (.docx) with 165 tools — first direct OOXML library (no Microsoft Word process required). Text-anchor insert, batch replace/search, session state with SHA256 drift detection, F9-equivalent field recount, OMML math AST, Caption/Equation CRUD. Optimized for thesis and manuscript review workflows.

### 建議 Topics 數量

- **目標：15-20 個**（GitHub 上限 20）
- 少於 5 個 = search visibility 等於零
- `null` / 空陣列 = 完全沒出現在 `topic:xxx` 搜尋頁

### 必備 Topic 類別

| 類別 | Topic 範例 |
|------|----------|
| 語言 | `swift`, `rust`, `typescript`, `python` |
| 協議 | `mcp`, `mcp-server`, `model-context-protocol` |
| 客戶端 | `claude`, `claude-ai`, `claude-code`, `claude-desktop` |
| 平台 | `macos`, `linux`, `native`, `cross-platform` |
| 功能域 | 依 MCP 主要操作對象命名（`docx`, `calendar`, `pdf`, `markdown`…）|
| 用途 | `ai-tools`, `automation`, `productivity`, `developer-tools` |
| 競品/生態 | `microsoft-word`, `office`, `apple-notes` 等（方便比較搜尋）|

### `gh repo edit` 參考指令

```bash
# 一次更新 description + homepage
gh repo edit {OWNER}/{REPO} \
  --description "..." \
  --homepage "https://github.com/{OWNER}/{REPO}/releases"

# 加 topics（可累積多次呼叫）
gh repo edit {OWNER}/{REPO} \
  --add-topic swift \
  --add-topic mcp \
  --add-topic mcp-server \
  --add-topic claude-code

# 查核目前狀態
gh repo view {OWNER}/{REPO} --json description,homepageUrl,repositoryTopics
```

### Deploy 前的審計

```bash
# description 長度 + 是否包含最新 tool 總數
CURRENT_DESC=$(gh repo view --json description -q .description)
TOOL_COUNT=$(...從 source 或 tools/list 抓)
echo "$CURRENT_DESC" | grep -q "$TOOL_COUNT tools" || echo "⚠️ Description 未反映 $TOOL_COUNT tools"

# topics 數量
TOPIC_COUNT=$(gh repo view --json repositoryTopics -q '.repositoryTopics | length')
[ "$TOPIC_COUNT" -ge 5 ] || echo "⚠️ Topics 只有 $TOPIC_COUNT 個（建議 15-20）"
```

## 例外

- 純 bug fix（patch release，tool 集合完全沒動）→ 只需 CHANGELOG，README / Description / Topics 皆不用
- 私有測試版本（未上架 release）→ 都可以延後，但 release 前必須補

## 和其他 skill 的關係

- `mcp-deploy` Step 2.6 會檢查 README/tool-count 一致性，不一致時 **BLOCK** 發布
- `mcp-upgrade` 若建議加新 tool，也會在建議清單末尾提醒「README 要補第 X 段」
- `mcp-new-app` 的 scaffold 會直接生成含正確 tool count placeholder 的 README 骨架

## TL;DR

**動了 `tools/list`，就動 README；沒動 README 就不要發 release。**
