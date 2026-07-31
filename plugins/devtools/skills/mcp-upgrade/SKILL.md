---
name: mcp-upgrade
description: |
  分析既有 MCP Server 專案並提出升級建議，分三個 phase：依賴版本、專案結構、可加的新功能。可用 focus-area 參數聚焦單一面向。
  與鄰近 skill 的分工：本 skill 只分析與提議、不改動 code；想看別人怎麼實作再決定要不要抄，用 mcp-clone（已知 repo）或 mcp-clone-references（要先搜尋）。
argument-hint: [focus-area]
allowed-tools: Read, Write, Edit, Bash(swift:*), Bash(git:*), Bash(npm:*), Bash(pip:*), Bash(cat:*), Bash(grep:*), Bash(file:*), Bash(lipo:*), Bash(shasum:*), Bash(ls:*), Bash(rm:*), Grep, Glob, WebFetch, AskUserQuestion
disable-model-invocation: true
---

# MCP Upgrade - 專案升級建議

分析現有 MCP 專案，提出升級和改進建議，等待核可後執行。

**建立新專案請用 `/devtools:mcp-new-app`**
**部署專案請用 `/devtools:mcp-deploy`**

## 參數

- `$1` = 聚焦領域（可選）
  - `deps` - 只檢查依賴更新
  - `structure` - 只檢查結構優化
  - `features` - 只建議新功能
  - `all` - 全面分析（預設）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="project_analysis", description="Phase 0: 確認專案位置 + 識別語言/框架 + 收集資訊")
TaskCreate(name="dependency_analysis", description="Phase 1: 依賴分析（過時、安全漏洞、版本差距）")
TaskCreate(name="structure_analysis", description="Phase 2: 目錄結構 + 程式碼品質 + Binary 一致性（Swift only）")
TaskCreate(name="feature_analysis", description="Phase 3: 現有工具 + API 能力對比 + 建議新功能")
TaskCreate(name="generate_upgrade_report", description="Phase 4: 彙整報告，列出所有建議 + 優先級")
TaskCreate(name="await_approval_and_execute", description="Phase 5: AskUserQuestion 讓使用者挑選後執行")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 專案分析

### Step 1: 確認專案位置

```bash
pwd
ls -la
```

**必須存在**：
- MCP 專案根目錄
- `mcpb/manifest.json`

### Step 2: 識別語言和框架

| 檔案 | 語言 |
|------|------|
| `Package.swift` | Swift |
| `pyproject.toml` | Python |
| `package.json` + `tsconfig.json` | TypeScript |

### Step 3: 收集專案資訊

讀取以下檔案：
- `mcpb/manifest.json` - 版本、工具列表
- `CHANGELOG.md` - 變更歷史
- `README.md` - 功能說明
- 主要 Server 程式碼

---

## Phase 1: 依賴分析（Dependency Analysis）

### Swift 依賴檢查

#### 1A: 讀取當前依賴

```bash
cat Package.swift | grep -A5 'dependencies'
cat Package.resolved | grep -A2 '"version"' | head -20
```

#### 1B: 檢查 MCP SDK 最新版本

使用 WebFetch 查詢：
- https://github.com/modelcontextprotocol/swift-sdk/releases

#### 1C: 檢查其他依賴

常用 Swift 依賴的最新版本：
| 套件 | 用途 | 檢查 URL |
|------|------|----------|
| swift-sdk | MCP 協議 | github.com/modelcontextprotocol/swift-sdk |
| swift-log | 日誌 | github.com/apple/swift-log |

---

### Python 依賴檢查

#### 1A: 讀取當前依賴

```bash
cat pyproject.toml | grep -A20 'dependencies'
pip list --outdated 2>/dev/null
```

#### 1B: 檢查 MCP 套件最新版本

```bash
pip index versions mcp 2>/dev/null | head -5
```

---

### TypeScript 依賴檢查

#### 1A: 讀取當前依賴

```bash
cat package.json | grep -A20 '"dependencies"'
npm outdated 2>/dev/null
```

#### 1B: 檢查最新版本

```bash
npm view @modelcontextprotocol/sdk version
```

---

## Phase 2: 結構分析（Structure Analysis）

### Step 1: 檢查目錄結構

根據語言檢查是否符合最佳實踐：

#### Swift 最佳結構
```
✅ Sources/{Name}/main.swift          - 進入點
✅ Sources/{Name}Core/Server.swift    - 核心邏輯
✅ Sources/{Name}Core/{Name}Manager.swift - 業務邏輯
✅ Tests/{Name}Tests/                 - 單元測試
✅ mcpb/manifest.json                 - MCPB 套件
✅ mcpb/PRIVACY.md                    - 隱私政策
✅ .gitattributes                     - LFS 設定
```

#### 缺失項目建議
| 缺失 | 建議 | 優先級 |
|------|------|--------|
| Tests/ | 加入單元測試 | 中 |
| docs/ | 加入文檔目錄 | 低 |
| .gitattributes | 設定 Git LFS | 高（如有 binary） |
| mcpb/icon.png | 加入圖示 | 低 |
| README Version History | 加入版本歷史表格（所有語言版本） | 中 |
| README Technical Details | 更新 Current Version 和 SDK 版本 | 中 |
| CHANGELOG.md | 加入變更日誌 | 中 |
| LICENSE | 加入授權檔案 | 高 |

### Step 2: 檢查程式碼品質

#### Swift 程式碼檢查
```bash
# 檢查是否有 TODO/FIXME
grep -rn "TODO\|FIXME" Sources/

# 檢查是否有硬編碼
grep -rn "hardcode\|HARDCODE" Sources/

# 檢查錯誤處理
grep -rn "try!" Sources/  # 不安全的 try
```

#### 常見問題
| 問題 | 建議 |
|------|------|
| `try!` 使用 | 改用 `try` + error handling |
| 硬編碼字串 | 提取為常數 |
| 缺少註解 | 為 public API 加入文檔註解 |

### Step 3: Binary 一致性檢查（Swift 專案限定）

**注意**：此步驟只適用於 Swift 專案。Python/TypeScript 使用 wrapper script，跳過。

#### 3A: 取得 Binary 名稱

```bash
BINARY_NAME=$(grep -A5 'executableTarget' Package.swift | grep 'name:' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
```

#### 3B: 比對 mcpb/server 和 ~/bin

```bash
echo "=== Binary Consistency Check ==="

# Hash 比對
shasum -a 256 mcpb/server/$BINARY_NAME 2>/dev/null
shasum -a 256 ~/bin/$BINARY_NAME 2>/dev/null

# 架構比對
echo "--- mcpb/server ---"
file mcpb/server/$BINARY_NAME 2>/dev/null
lipo -info mcpb/server/$BINARY_NAME 2>/dev/null

echo "--- ~/bin ---"
file ~/bin/$BINARY_NAME 2>/dev/null
lipo -info ~/bin/$BINARY_NAME 2>/dev/null
```

#### 3C: Architecture-aware 比對

如果 hash 不同，可能是因為一個是 universal、一個是 single-arch：

```bash
# 如果 mcpb/server 是 universal，~/bin 是 arm64-only
TMPFILE="/tmp/_mcpb_upgrade_check_$$"
lipo -thin arm64 mcpb/server/$BINARY_NAME -output "$TMPFILE" 2>/dev/null
if [ -f "$TMPFILE" ]; then
    echo "--- arm64 slice comparison ---"
    shasum -a 256 "$TMPFILE" ~/bin/$BINARY_NAME 2>/dev/null
    rm -f "$TMPFILE"
fi
```

#### 3D: 檢查 mcpb/server 是否為 universal binary

```bash
lipo -info mcpb/server/$BINARY_NAME 2>/dev/null
```

**預期**：應為 universal binary（`x86_64 arm64`）。
**問題**：如果只有 `arm64`，建議在下次 deploy 時重新用 `lipo -create` 建立 universal binary。

#### 3E: 記錄一致性狀態

在報告中記錄以下資訊：
- mcpb/server 和 ~/bin 的 hash 是否一致
- 兩者的架構是否相同
- 是否需要同步（建議使用 `/devtools:mcp-sync`）

---

## Phase 3: 功能分析（Feature Analysis）

### Step 1: 分析現有工具

讀取 `mcpb/manifest.json` 中的 tools 列表，分析：
- 工具數量
- 工具分類（讀取/寫入/刪除/查詢）
- 是否有批次操作
- 是否支援 i18n

### Step 2: 對比 API 能力

根據框架類型，檢查是否有未實作的 API：

#### AppleScript 框架
```bash
# 匯出 Dictionary
sdef /Applications/{AppName}.app > /tmp/app-dict.xml

# 比對已實作的命令
grep 'command name=' /tmp/app-dict.xml
```

#### EventKit 框架
檢查是否支援：
- [ ] 日曆事件 CRUD
- [ ] 提醒事項 CRUD
- [ ] 重複事件
- [ ] 提醒通知
- [ ] 批次操作

### Step 3: 建議新功能

根據分析結果，建議可能的新功能：

| 類型 | 建議 | 複雜度 |
|------|------|--------|
| 批次操作 | 如果沒有 `*_batch` 工具 | 中 |
| 搜尋功能 | 如果沒有 `search_*` 工具 | 低 |
| 匯出功能 | 如果沒有 `export_*` 工具 | 中 |
| UI 操作 | 如果沒有 `show_*` 工具 | 低 |

---

## Phase 4: 生成升級建議報告

### 報告格式

```markdown
# MCP 升級建議報告

**專案**: {project-name}
**當前版本**: {current-version}
**分析時間**: {timestamp}
**語言**: Swift / Python / TypeScript

---

## 📦 依賴更新

### 需要更新
| 套件 | 當前版本 | 最新版本 | 重要性 |
|------|----------|----------|--------|
| swift-sdk | 0.9.0 | 0.10.0 | 🔴 高 |

### 更新指令
```bash
# Swift: 編輯 Package.swift
.package(url: "...", from: "0.10.0")

# 然後執行
swift package update
```

---

## 🏗️ 結構優化

### 建議改進
| 項目 | 現狀 | 建議 | 優先級 |
|------|------|------|--------|
| 單元測試 | ❌ 缺失 | 加入 Tests/ | 🟡 中 |
| Git LFS | ❌ 未設定 | 加入 .gitattributes | 🔴 高 |

### 改進步驟
1. **加入 .gitattributes**
   ```
   *.mcpb filter=lfs diff=lfs merge=lfs -text
   mcpb/server/* filter=lfs diff=lfs merge=lfs -text
   ```

---

## ✨ 新功能建議

### 可實作功能
| 功能 | 描述 | 複雜度 | API 支援 |
|------|------|--------|----------|
| search_items | 關鍵字搜尋 | 低 | ✅ |
| export_data | 匯出為 JSON | 中 | ✅ |
| batch_update | 批次更新 | 中 | ✅ |

### 實作優先順序
1. 🔴 **高優先**: search_items（用戶常用）
2. 🟡 **中優先**: batch_update（效率提升）
3. 🟢 **低優先**: export_data（進階功能）

---

## ⚠️ 潛在問題

| 問題 | 位置 | 建議 |
|------|------|------|
| 不安全的 try! | Server.swift:45 | 改用 do-catch |
| 硬編碼路徑 | Manager.swift:23 | 使用環境變數 |

---

## 🔗 Binary 一致性（Swift 專案）

| 位置 | 存在 | 架構 | Hash (前 12 碼) | 狀態 |
|------|------|------|-----------------|------|
| mcpb/server/{Binary} | ✅/❌ | universal/arm64 | abc123... | - |
| ~/bin/{Binary} | ✅/❌ | universal/arm64 | abc123... | - |

- mcpb/server ↔ ~/bin: ✅ 一致 / ❌ 不一致
- 建議: {如需同步，使用 `/devtools:mcp-sync`}

---

## 📋 執行計畫

### 建議執行順序
1. [ ] 更新依賴
2. [ ] 修復潛在問題
3. [ ] 結構優化
4. [ ] 實作新功能
5. [ ] 測試和部署

---

**請確認要執行哪些升級項目？**
```

---

## Phase 5: 等待核可並執行

### Step 1: 詢問用戶

使用 AskUserQuestion 詢問要執行哪些項目：

**選項**：
- [ ] 更新依賴
- [ ] 結構優化（加入缺失檔案）
- [ ] 修復潛在問題
- [ ] 實作新功能（需另外討論細節）
- [ ] 全部執行
- [ ] 暫不執行（只保留報告）

### Step 2: 執行核可的項目

根據用戶選擇，執行對應的修改：

#### 更新依賴
```bash
# Swift
# 編輯 Package.swift，然後：
swift package update

# Python
pip install --upgrade mcp

# TypeScript
npm update
```

#### 加入缺失檔案
使用 Write 工具建立缺失的檔案（.gitattributes、Tests/、docs/ 等）

#### 修復問題
使用 Edit 工具修復程式碼問題

#### 更新版本相關檔案（如有變更）
如果執行了任何升級項目，需要更新以下檔案：

1. **CHANGELOG.md** - 加入新版本的變更記錄
2. **README.md（所有語言版本）**：
   - Technical Details 區塊的版本號
   - Framework/SDK 版本號
   - Version History 表格加入新版本
3. **Version.swift / package.json** - 更新版本常數
4. **mcpb/manifest.json** - 更新版本號

**檢查清單**：
```bash
# 檢查需要更新的檔案
grep -l "version" README*.md CHANGELOG.md mcpb/manifest.json Sources/*/Version.swift 2>/dev/null
```

### Step 3: 驗證修改

```bash
# Swift
swift build

# Python
python -m pytest

# TypeScript
npm run build
```

### Step 4: 串接部署（可選）

如果有執行任何升級項目，使用 AskUserQuestion 詢問：

> 升級完成！是否要繼續部署新版本？

**選項**：
- **是，繼續部署** - 執行 `/devtools:mcp-deploy`
- **否，稍後部署** - 結束 upgrade 流程

如果選擇「是」：
1. 使用 AskUserQuestion 詢問新版本號（建議根據變更類型：功能 → MINOR+1，修復 → PATCH+1）
2. 呼叫 Skill tool 執行 `mcp-deploy {version}`

```
Skill: mcp-tools:mcp-deploy
Args: {suggested-version}
```

---

## 快速參考

### 常見升級項目

| 項目 | 檢查方式 | 升級方式 |
|------|----------|----------|
| MCP SDK | 比對 GitHub releases | 更新 Package.swift |
| 缺少測試 | 檢查 Tests/ 目錄 | 建立測試檔案 |
| 缺少 LFS | 檢查 .gitattributes | 建立並設定 |
| README 版本過期 | `grep "Current Version" README*.md` | 更新所有 README 的版本號和歷史 |
| 缺少 CHANGELOG | 檢查 CHANGELOG.md | 建立變更日誌 |
| 缺少 LICENSE | 檢查根目錄 | 建立授權檔案 |
| 程式碼品質 | grep TODO/FIXME/try! | 逐一修復 |

### 升級風險評估

| 風險等級 | 說明 | 建議 |
|----------|------|------|
| 🟢 低 | 文檔、結構優化 | 可直接執行 |
| 🟡 中 | 依賴更新、新功能 | 建議測試後部署 |
| 🔴 高 | 破壞性 API 變更 | 需要仔細審查 |

### MCP SDK 版本歷史

| 版本 | 重要變更 |
|------|----------|
| 0.10.0 | Tool annotations 支援 |
| 0.9.0 | StdioTransport 改進 |
| 0.8.0 | 初始穩定版本 |
