---
name: mcp-diagnose
description: |
  MCP Server 連線層診斷：檢查 server 有沒有連上、binary 在不在 ~/bin、基本 tool 呼叫通不通，並產出診斷日誌。
  Use when: mcp__* tool 完全叫不出來；Claude 說找不到某個 MCP 工具；剛裝完 MCP 想確認有沒有活；「MCP 連不上」「mcp 沒反應」「diagnose MCP」。
  與鄰近 skill 的分工：完全連不上用本 skill；連得上但某個 tool 行為錯用 mcp-debug；想逐一驗證每個 tool 都能用跑 mcp-test。
argument-hint: <mcp-server-name>
allowed-tools: Bash(ls:*, file:*, claude:mcp*), Read, Grep, mcp__*
---

# MCP Diagnose - 連線診斷

診斷 MCP Server 連線問題。**功能除錯請用 `/devtools:mcp-debug`**。

## 參數

- `$1` = MCP Server 名稱（如 `che-things-mcp`、`che-ical-mcp`）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="setup_log_dir", description="建立 logs/mcptools/debug/ 目錄")
TaskCreate(name="check_connection", description="Step 1: 檢查 MCP Server 連線狀態")
TaskCreate(name="basic_functional_test", description="Step 2: 跑 3 個讀取類 tool 快速測試")
TaskCreate(name="analyze_errors", description="Step 3: 錯誤訊息分析（若有）")
TaskCreate(name="output_report", description="Step 4: 輸出診斷報告到 logs")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

## 診斷流程

### Step 0.5: 建立診斷日誌目錄

在專案根目錄建立 `logs/mcptools/debug/` 結構（diagnose 報告也存在 debug 目錄）：

```bash
cd ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/$1
mkdir -p logs/mcptools/debug
```

### Step 1: 檢查連線狀態

```bash
claude mcp list 2>&1 | grep -A1 "$1"
```

**結果判讀**：
- `✓ Connected` → 進入 Step 2
- `✗ Failed` 或找不到 → 進入「未連接診斷」

### Step 2: 基本功能測試

**如果已連接**：直接呼叫一個 read-only tool 測試：

```
# 例如 che-things-mcp
呼叫 mcp__che-things-mcp__get_projects

# 例如 che-ical-mcp
呼叫 mcp__che-ical-mcp__list_calendars
```

成功 → MCP Server 運作正常
失敗 → 進入 `/devtools:mcp-debug` 進行功能除錯

### Step 3: 輸出診斷報告

將報告存到 `logs/mcptools/debug/diagnose-report-<timestamp>.md`：

```bash
# 報告檔案路徑
REPORT_FILE="logs/mcptools/debug/diagnose-report-$(date +%Y%m%d-%H%M%S).md"
```

**報告格式**：

```markdown
# MCP Diagnose Report: <server-name>
Generated: <timestamp>

## 連線狀態
- 狀態: ✓ 已連接 / ✗ 未連接
- Binary: /path/to/binary

## 測試結果
- 基本連線測試: ✓ / ✗

## 診斷結論
- 結果: 正常 / 需要進一步除錯
- 建議: <如果需要>
```

使用 Write 工具將報告寫入 `$REPORT_FILE`。

完成後輸出：
```
✅ 診斷報告已儲存: logs/mcptools/debug/diagnose-report-<timestamp>.md
```

---

## 未連接診斷

### 找到 Binary 路徑

```bash
# 從 settings.json 找
grep -A5 "$1" ~/.claude/settings.json
```

### 測試 Binary

```bash
# 確認檔案存在且可執行
ls -la "$BINARY_PATH"
file "$BINARY_PATH"
```

### 加入 MCP Server

```bash
claude mcp add <name> /path/to/binary
```

---

## 常見問題

| 問題 | 可能原因 | 解決方案 |
|------|----------|----------|
| Server disconnected | Binary crash | 檢查 binary 是否有 `waitUntilCompleted()` |
| Tool 呼叫卡住 | Event Loop 阻塞 | 使用背景執行緒處理同步操作 |
| Permission denied | 權限問題 | → `/devtools:mcp-debug` |

---

## 相關工具

- `/devtools:mcp-debug` - 功能除錯（權限、框架特定問題）
- `/devtools:mcp-test` - 完整功能測試
