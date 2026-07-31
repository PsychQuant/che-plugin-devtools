---
name: mcp-test
description: |
  MCP Server 完整功能測試：發現該 server 的所有 tool、逐一實際呼叫驗證、產出測試報告與日誌。
  Use when: 改完 MCP server 想確認沒有 regression；發 release 前的驗收；接手別人的 MCP 想知道哪些 tool 真的能用；「測一下這個 MCP」「跑 MCP 測試」。
  與鄰近 skill 的分工：連不上用 mcp-diagnose；單一 tool 出錯用 mcp-debug；本 skill 是全面掃描，最慢但最完整。
argument-hint: <mcp-server-name>
allowed-tools: Bash(claude mcp:*), Bash(grep:*), Read, Grep, Glob
---

# MCP Test - 完整功能測試

開發完成後，使用此流程驗證 MCP Server 所有功能。

**問題診斷請用 `/harness-devtools:mcp-debug`**

## 參數

- `$1` = MCP Server 名稱（如 `che-things-mcp`、`che-ical-mcp`）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="prepare", description="Phase 0: 檢查連線 + 識別框架 + 建測試日誌目錄")
TaskCreate(name="tool_discovery", description="Phase 1: 提取所有 tools + 自動分類 + 產生清單")
TaskCreate(name="run_unit_tests", description="Phase 2: 執行單元測試（逐一呼叫 tools）")
TaskCreate(name="generate_report", description="Phase 3: 產生測試報告 + 儲存")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 準備

### Step 1: 檢查連線

```bash
claude mcp list 2>&1 | grep -A1 "$1"
```

如果連線失敗，請先使用 `/harness-devtools:mcp-diagnose` 診斷問題。

### Step 2: 識別框架（簡化）

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-mcp-project.sh"
PROJ=$(require_mcp_project "$1") || exit 1
grep -r "^import" "$PROJ/Sources/" 2>/dev/null | head -10
```

### Step 3: 建立測試日誌目錄

在專案根目錄建立 `logs/mcptools/test/` 結構：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-mcp-project.sh"
cd "$(require_mcp_project "$1")" || exit 1
mkdir -p logs/mcptools/test
```

**目錄結構**：
```
<project>/
└── logs/
    └── mcptools/
        └── test/           ← 測試報告存放處
            └── test-report-<timestamp>.md
```

---

## Phase 1: Tool 發現

### Step 1: 提取所有 Tools

從 `Server.swift` 讀取所有 tool 定義：

```bash
grep -E 'name:.*"[a-z_]+"' $1/Sources/*/Server.swift | sed 's/.*name: *"\([^"]*\)".*/\1/' | sort -u
```

### Step 2: 自動分類

根據命名規則分類：

| 前綴 | 類型 | 測試方式 |
|------|------|----------|
| `list_*`, `get_*` | 讀取 | 直接呼叫，無參數 |
| `search_*`, `find_*`, `check_*` | 搜尋 | 提供測試參數 |
| `create_*`, `add_*` | 建立 | 生命週期測試 |
| `update_*`, `edit_*`, `complete_*`, `copy_*`, `move_*` | 修改 | 生命週期測試 |
| `delete_*`, `remove_*` | 刪除 | 生命週期測試 |

### Step 3: 產生 Tool 清單

```markdown
## Tool 清單（自動產生）

| # | Tool 名稱 | 類型 | 測試狀態 |
|---|-----------|------|----------|
| 1 | list_xxx | 讀取 | ⏳ 待測 |
| 2 | search_xxx | 搜尋 | ⏳ 待測 |
| 3 | create_xxx | 建立 | ⏳ 待測 |
...
```

---

## Phase 2: 執行單元測試

### 2.1 讀取類 Tools（全部測試）

對每個 `list_*` / `get_*` tool：

1. 呼叫 tool（無參數或最小參數）
2. 記錄結果：✅ 成功 / ❌ 失敗

**範例**（che-ical-mcp）：
- `list_calendars` → 無參數
- `list_reminders` → 無參數
- `list_events_quick` → `range: "today"`

### 2.2 搜尋類 Tools（全部測試）

對每個 `search_*` / `find_*` / `check_*` tool：

1. 準備測試參數
2. 呼叫 tool
3. 記錄結果

**範例**：
- `search_events` → `keyword: "test", start_date: "...", end_date: "..."`
- `check_conflicts` → `start_time: "...", end_time: "..."`

### 2.3 建立/修改/刪除類 Tools（生命週期測試）

**核心原則**：
- 所有測試資料用 `MCP_DEBUG_TEST_` 前綴
- 建立後立即記錄 ID
- 測試結束必須刪除所有測試資料
- 如果刪除失敗，報告殘留 ID

#### Event 生命週期

```
create_event (MCP_DEBUG_TEST_EVENT)
    ↓ 記錄 event_id
update_event (修改 title)
    ↓ 用同一個 event_id
copy_event (複製到另一個日曆)
    ↓ 記錄 copied_event_id
delete_event (刪除原始)
    ↓
delete_event (刪除複製)
    ↓
✅ 清理完成
```

#### Reminder 生命週期

```
create_reminder (MCP_DEBUG_TEST_REMINDER)
    ↓ 記錄 reminder_id
update_reminder (修改 title)
    ↓
complete_reminder (標記完成)
    ↓
delete_reminder (刪除)
    ↓
✅ 清理完成
```

#### Calendar 生命週期

```
create_calendar (MCP_DEBUG_TEST_CALENDAR)
    ↓ 記錄 calendar_id
create_event (在測試日曆中建立事件)
    ↓
delete_calendar (刪除日曆，事件一併刪除)
    ↓
✅ 清理完成
```

#### Batch 操作

```
create_events_batch (3 個測試事件)
    ↓ 記錄所有 event_ids
move_events_batch (移動到另一個日曆)
    ↓
delete_events_batch (刪除所有)
    ↓
✅ 清理完成
```

---

## Phase 3: 測試報告

### Step 1: 產生報告

將報告存到 `logs/mcptools/test/test-report-<timestamp>.md`：

```bash
# 報告檔案路徑
REPORT_FILE="logs/mcptools/test/test-report-$(date +%Y%m%d-%H%M%S).md"
```

### Step 2: 報告格式

```markdown
# MCP Test Report: <server-name>
Generated: <timestamp>

## 測試摘要
- 總 Tools: <n>
- 測試通過: <pass>
- 測試失敗: <fail>
- 覆蓋率: <pass/n * 100>%

## 測試結果

### 讀取類 (n/n)
| Tool | 結果 | 備註 |
|------|------|------|
| list_calendars | ✅ | - |
| list_reminders | ✅ | - |

### 搜尋類 (n/n)
| Tool | 結果 | 備註 |
|------|------|------|
| search_events | ✅ | - |

### 建立/修改/刪除類 (n/n)
| Tool | 結果 | 備註 |
|------|------|------|
| create_event | ✅ | 已清理 |
| update_event | ✅ | - |
| delete_event | ✅ | - |

## 清理狀態
- 測試資料已全部清理: ✅ / ❌
- 殘留 ID: <如果有>

## 失敗項目分析
（如果有失敗）

| Tool | 錯誤訊息 | 可能原因 |
|------|----------|----------|
| ... | ... | ... |
```

### Step 3: 儲存報告

使用 Write 工具將報告寫入 `$REPORT_FILE`。

完成後輸出：
```
✅ 測試報告已儲存: logs/mcptools/test/test-report-<timestamp>.md
```

---

## 快速參考

### 測試參數範例

#### che-ical-mcp

| Tool | 測試參數 |
|------|----------|
| `list_events` | `start_date: "2026-01-01T00:00:00+08:00", end_date: "2026-01-31T23:59:59+08:00"` |
| `list_events_quick` | `range: "today"` |
| `search_events` | `keyword: "test", start_date: "...", end_date: "..."` |
| `create_event` | `title: "MCP_DEBUG_TEST_EVENT", start_time: "...", end_time: "...", calendar_name: "...", calendar_source: "iCloud"` |
| `create_reminder` | `title: "MCP_DEBUG_TEST_REMINDER", calendar_name: "..."` |

#### che-things-mcp

| Tool | 測試參數 |
|------|----------|
| `get_today` | 無參數 |
| `search_todos` | `query: "test"` |
| `add_todo` | `name: "MCP_DEBUG_TEST_TODO"` |

### 測試資料命名規則

| 類型 | 前綴 |
|------|------|
| Event | `MCP_DEBUG_TEST_EVENT` |
| Reminder | `MCP_DEBUG_TEST_REMINDER` |
| Calendar | `MCP_DEBUG_TEST_CALENDAR` |
| Todo | `MCP_DEBUG_TEST_TODO` |
| Project | `MCP_DEBUG_TEST_PROJECT` |
