---
name: mcp-debug
description: |
  MCP Server 功能層除錯：已連線但 tool 行為錯誤時，做框架識別、權限問題排查、錯誤訊息分析，產出除錯日誌。可把錯誤訊息當第二個參數傳入。
  Use when: 某個 mcp__* tool 叫得出來但回錯誤或結果不對；被 permission denied 擋掉；「這個 MCP tool 壞了」「為什麼回權限錯誤」「debug MCP」。
  與鄰近 skill 的分工：完全連不上先跑 mcp-diagnose；本 skill 針對單一 tool 的行為問題；全面回歸驗證用 mcp-test。
argument-hint: <mcp-server-name> [error-message]
allowed-tools: Bash(sdef:*), Bash(osascript:*), Bash(claude mcp:*), Bash(pkill:*), Bash(swift:*), Bash(tccutil:*), Bash(open:*), Bash(lipo:*), Bash(file:*), Bash(shasum:*), Bash(cp:*), Bash(chmod:*), Bash(rm:*), Bash(ls:*), Bash(grep:*), Bash(codesign:*), Read, Write, Grep, Glob
---

# MCP Debug - 功能除錯

當 MCP Server 功能有問題時，使用此流程診斷。

**連線問題請用 `/harness-devtools:mcp-diagnose`**
**完整測試請用 `/harness-devtools:mcp-test`**

## 參數

- `$1` = MCP Server 名稱（如 `che-things-mcp`、`che-ical-mcp`）
- `$2` = 可選的錯誤訊息（用於快速判斷問題類型）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="quick_diagnose", description="Phase 0: 建除錯日誌目錄 + 檢查連線 + 快速測試 + 錯誤分析")
TaskCreate(name="identify_framework", description="Phase 1: 找原始碼 + 判斷框架（Swift/Python/TS）")
TaskCreate(name="diagnosis_report", description="Phase 2: 產生報告 + 儲存")
TaskCreate(name="post_fix_verify", description="Phase 3: 若修復了，重新 build + sync binary 驗證")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 快速診斷

### Step 0: 建立除錯日誌目錄

在專案根目錄建立 `logs/mcptools/debug/` 結構：

```bash
cd ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/$1
mkdir -p logs/mcptools/debug
```

**目錄結構**：
```
<project>/
└── logs/
    └── mcptools/
        └── debug/          ← 除錯報告存放處
            └── debug-report-<timestamp>.md
```

### Step 1: 檢查連線狀態

```bash
claude mcp list 2>&1 | grep -A1 "$1"
```

**結果判讀**：
- `✓ Connected` → 連線正常，進入 Phase 1
- `✗ Failed` 或找不到 → 先用 `/harness-devtools:mcp-diagnose`

### Step 2: 快速測試（3 個讀取類 tools）

直接呼叫 MCP tools 測試基本功能：

1. 找到該 MCP Server 的讀取類 tools（`list_*`、`get_*`）
2. 呼叫 3 個不需要參數的 tools
3. 根據結果判斷：
   - 全部成功 → 基本功能正常
   - 部分失敗 → 進入框架特定除錯
   - 全部失敗 → 可能是權限問題

### Step 3: 錯誤訊息分析

如果有錯誤訊息（`$2`），快速判斷問題類型：

| 錯誤關鍵字 | 問題類型 | 進入流程 |
|-----------|---------|---------|
| `access denied` / `permission` | 權限問題 | → B3 權限除錯 |
| `not found` / `does not exist` | 資源不存在 | → 檢查參數 |
| `Can't set property` | AppleScript 唯讀 | → A2 Dictionary 分析 |
| `connection` / `timeout` | 連線問題 | → Phase 3 重啟 |
| `parse` / `invalid` | 參數格式錯誤 | → 檢查參數格式 |

---

## Phase 1: 識別框架類型

### Step 1: 找到原始碼

```bash
ls -la ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/$1/
```

### Step 2: 判斷框架

```bash
# 檢查 Swift imports
grep -r "^import" $1/Sources/ 2>/dev/null | head -20
```

| 特徵 | 框架類型 | 除錯流程 |
|------|----------|----------|
| `import EventKit` | **EventKit** | → 框架 B |
| `tell application` / `NSAppleScript` | **AppleScript** | → 框架 A |
| `import Contacts` | **Contacts** | → 框架 C |
| HTTP/REST calls | **Web API** | → 框架 C |

---

## 框架 A: AppleScript 除錯

適用於：`che-things-mcp`、`che-apple-mail-mcp`

### A1: 匯出 Dictionary

```bash
sdef /Applications/<AppName>.app > /tmp/<AppName>-dictionary.xml
```

### A2: 分析 Dictionary

```bash
# 找唯讀屬性
grep 'access="r"' /tmp/<AppName>-dictionary.xml

# 找可用命令
grep 'command name=' /tmp/<AppName>-dictionary.xml
```

### A3: 測試 AppleScript 層

```bash
osascript -e 'tell application "<AppName>" to <test-code>'
```

### A4: 常見錯誤

| 錯誤 | 原因 | 解決 |
|------|------|------|
| `Can't set property` | 屬性唯讀 | 用替代命令 |
| `Can't get list "Inbox"` | localized 名稱 | 用 internal ID |

---

## 框架 B: EventKit 除錯

適用於：`che-ical-mcp`

### B1: 讀取程式碼

```bash
cat $1/Sources/*/EventKitManager.swift
```

### B2: 關鍵模式

| 模式 | 功能 |
|------|------|
| `EKEventStore` | 存取行事曆 |
| `requestAccess` | 權限請求 |
| `predicateForEvents` | 查詢事件 |

### B3: 權限除錯（最常見問題！）

#### Step 1: 開啟系統設定

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
```

#### Step 2: 找到正確的授權對象

**重要**：要授權的是 **IDE**，不是 binary！

| 你使用的工具 | 要授權的項目 |
|-------------|-------------|
| Cursor | **Cursor** |
| VS Code | **Code** |
| Terminal | **Terminal** / **iTerm** |
| Claude Desktop | **Claude** |

#### Step 3: 如果列表中沒有項目

```bash
# 重置權限
tccutil reset Calendars
tccutil reset Reminders

# 觸發權限請求
osascript -e 'tell application "Calendar" to get name of every calendar'
osascript -e 'tell application "Reminders" to get name of every list'
```

### B4: 權限機制說明

```
┌─────────────────────────────────────────────────────────┐
│  AppleScript (osascript)  vs  EventKit Framework        │
├─────────────────────────────────────────────────────────┤
│  osascript 成功          │  MCP (EventKit) 失敗         │
│  ↓                       │  ↓                           │
│  Apple Events 權限       │  Privacy - Calendars/        │
│  (Automation)            │  Reminders 權限              │
├─────────────────────────────────────────────────────────┤
│  這是兩個不同的權限機制！                                │
│  AppleScript 能用不代表 EventKit 也能用                 │
└─────────────────────────────────────────────────────────┘
```

---

## 框架 C: 其他 Framework

### C1: 讀取程式碼

```bash
grep -r "class.*Manager\|class.*Service" $1/Sources/
cat $1/Package.swift
```

---

## Phase 2: 診斷報告

### Step 1: 產生報告

將報告存到 `logs/mcptools/debug/debug-report-<timestamp>.md`：

```bash
# 報告檔案路徑
REPORT_FILE="logs/mcptools/debug/debug-report-$(date +%Y%m%d-%H%M%S).md"
```

### Step 2: 報告格式

```markdown
# MCP Debug Report: <server-name>
Generated: <timestamp>

## 問題摘要
- 錯誤訊息: <error>
- 問題類型: 權限 / 參數 / 連線 / 其他

## 框架識別
- 類型: AppleScript / EventKit / Other
- 除錯流程: 框架 A / B / C

## 診斷結果
- 快速測試: ✅ / ❌
- 問題根因: <root-cause>

## 修復建議
1. <step-1>
2. <step-2>
```

### Step 3: 儲存報告

使用 Write 工具將報告寫入 `$REPORT_FILE`。

完成後輸出：
```
✅ 除錯報告已儲存: logs/mcptools/debug/debug-report-<timestamp>.md
```

---

## Phase 3: 修復後驗證

### Step 1: 重新建置

```bash
cd $1
swift build -c release
```

### Step 2: 同步 Binary 到 mcpb/server 和 ~/bin

取得 Binary 名稱：

```bash
BINARY_NAME=$(grep -A5 'executableTarget' Package.swift | grep 'name:' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
```

#### 情況 A: 兩種架構的 build 都存在 → 用 lipo 合併

```bash
if [ -f ".build/arm64-apple-macosx/release/$BINARY_NAME" ] && [ -f ".build/x86_64-apple-macosx/release/$BINARY_NAME" ]; then
    echo "Building universal binary..."
    lipo -create \
        .build/arm64-apple-macosx/release/$BINARY_NAME \
        .build/x86_64-apple-macosx/release/$BINARY_NAME \
        -output mcpb/server/$BINARY_NAME
    codesign --force --sign - mcpb/server/$BINARY_NAME
else
    echo "Single-arch build detected, copying directly..."
    # 找到可用的 release binary
    BUILD_BIN=$(ls .build/arm64-apple-macosx/release/$BINARY_NAME .build/x86_64-apple-macosx/release/$BINARY_NAME .build/release/$BINARY_NAME 2>/dev/null | head -1)
    if [ -n "$BUILD_BIN" ]; then
        cp "$BUILD_BIN" mcpb/server/$BINARY_NAME
    fi
fi
```

#### 複製到 ~/bin

```bash
cp mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
codesign --force --sign - ~/bin/$BINARY_NAME
```

#### 驗證同步

```bash
echo "=== Post-rebuild Sync Verification ==="
shasum -a 256 mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
file mcpb/server/$BINARY_NAME
file ~/bin/$BINARY_NAME
```

### Step 3: 重啟 Server

```bash
pkill -f <BinaryName>
claude mcp list 2>&1 | grep -A1 "$1"
```

---

## 快速參考

### MCP Server 對應表

| MCP Server | 框架 | Binary |
|------------|------|--------|
| che-things-mcp | AppleScript | CheThingsMCP |
| che-apple-mail-mcp | AppleScript | CheAppleMailMCP |
| che-ical-mcp | EventKit | CheICalMCP |

### Things 3 List IDs

| 清單 | ID |
|------|-----|
| Inbox | `TMInboxListSource` |
| Today | `TMTodayListSource` |
| Upcoming | `TMCalendarListSource` |
| Anytime | `TMNextListSource` |
| Someday | `TMSomedayListSource` |
| Logbook | `TMLogbookListSource` |
