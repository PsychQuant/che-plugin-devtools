---
name: mcp-upgrade
description: |
  分析既有 MCP Server 專案並提出升級建議，四個維度：依賴套件版本、MCP protocol 版本、專案結構、可加的新功能。彙整成報告後用 AskUserQuestion 讓你挑選，**核可的項目才動手改**（編輯 Package.swift、跑 swift package update / npm update / pip install --upgrade 等）。可用 focus-area 參數聚焦單一面向。
  依賴版本與 protocol 版本是兩件事：前者是函式庫（swift-sdk 0.12.0），後者是 spec 本身（YYYY-MM-DD），升一個不保證升另一個。protocol 版本一律現查官方文檔，不寫死在 skill 裡。
  與鄰近 skill 的分工：想看別人怎麼實作再決定要不要抄，用 mcp-clone（已知 repo）或 mcp-clone-references（要先搜尋）；本 skill 不建新專案（用 mcp-new-app）、不發布（用 mcp-deploy）。
argument-hint: [focus-area]
allowed-tools: Read, Write, Edit, Bash(swift:*), Bash(git:*), Bash(npm:*), Bash(pip:*), Bash(cat:*), Bash(grep:*), Bash(file:*), Bash(lipo:*), Bash(shasum:*), Bash(ls:*), Bash(rm:*), Grep, Glob, WebFetch, AskUserQuestion
disable-model-invocation: true
---

# MCP Upgrade - 專案升級建議

分析現有 MCP 專案，提出升級和改進建議，等待核可後執行。

**建立新專案請用 `/harness-devtools:mcp-new-app`**
**部署專案請用 `/harness-devtools:mcp-deploy`**

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
TaskCreate(name="protocol_version_check", description="Phase 1.5: MCP protocol 版本檢查（語言無關）——現查官方 current 版本、偵測專案宣告（硬編碼 / 靠 SDK / 未宣告）、跨 breaking change 時列出四個必要項")
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

## Phase 1.5: Protocol 版本檢查（語言無關）

Phase 1 查的是 **SDK 套件版本**。這一步查的是 **MCP protocol 版本**——兩者是不同的東西，升一個不保證升另一個：

```
SDK 版本        swift-sdk 0.12.0 / @modelcontextprotocol/sdk 1.x   ← 函式庫
protocol 版本   YYYY-MM-DD                                          ← spec 本身
```

### Step 1: 查官方 current 版本

**絕不把版本號寫進本 skill。** protocol 版本每隔數月就換一次，寫死等於埋一個保證過期的事實。每次執行都現查：

```bash
# 首選：llms.txt 的 versioning 頁（權威且穩定）
curl -fsSL https://modelcontextprotocol.io/llms.txt \
  | grep -oE 'docs/[0-9]{4}-[0-9]{2}-[0-9]{2}/' | head -1 | tr -d 'docs/'
```

或用 `livedocs:look-up` / WebFetch 讀 `modelcontextprotocol.io/docs/<ver>/learn/versioning.md`，該頁明文寫「The **current** protocol version is ...」。

同頁也列出版本規則：格式 `YYYY-MM-DD`，**只在 backwards-incompatible 變更時才遞增**。所以兩個版本之間的距離不是「幾個月」，是「幾次 breaking change」。

### Step 2: 偵測專案宣告的版本

三種情況要分開判定——**它們的風險完全不同**：

```bash
# 用 protocolVersion 當錨點，而不是裸抓日期字串
#（裸抓會撈到測試用的 date fixture，實測撈到過 "2026-13-01" 這種 13 月的假日期）
#
# --exclude-dir 不可省：.build/checkouts/ 底下是整包 MCP SDK 原始碼，
# 裡面當然有 protocolVersion 與各版本日期。不排除的話，一個「未宣告、
# 完全交給 SDK」的乾淨專案會被報成「硬編碼三個版本」。
HITS=$(grep -rhiE "protocolVersion" . \
  --include="*.swift" --include="*.py" --include="*.ts" --include="*.json" \
  --exclude-dir=.build --exclude-dir=node_modules --exclude-dir=.git \
  --exclude-dir=venv --exclude-dir=.venv --exclude-dir=__pycache__ \
  --exclude-dir=dist --exclude-dir=Pods 2>/dev/null || true)

DECLARED=$(printf '%s' "$HITS" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u || true)
MENTIONS=$(printf '%s' "$HITS" | grep -c . || true)   # `|| true`：無匹配時 grep exit 1，set -e 下會中斷
```

> **兩個親手踩過的坑，都會靜默給出錯的答案：**
>
> 1. **漏了 `--exclude-dir=.build`** —— 在 Claude Code 環境裡不會發現，因為它注入的 `grep` 其實是 `ugrep --ignore-files`（自動遵守 `.gitignore`，而 `.build/` 正在裡面）。同一個專案用原生 `grep` 掃出 184 行、用 Claude Code 的 `grep` 掃出 0 行。**skill 是給原生環境跑的，必須自己排除。**
>
> 2. **寫成 `|| echo 0`** —— `grep -c` 無匹配時**已經印了 `0`**，再 echo 一次會得到 `0\n0`，後續 `[ "$MENTIONS" -gt 0 ]` 直接報 `integer expression expected`。用 `|| true`。

| 情況 | 判定 | 風險 |
|---|---|---|
| `DECLARED` 非空 | **硬編碼**——版本鎖死在原始碼 | **最高**：SDK 升級也不會帶動它 |
| `DECLARED` 空但 `MENTIONS > 0` | 引用 SDK 提供的常數 | 中：跟著 SDK 走，但要確認 SDK 夠新 |
| 兩者皆空 | 完全由 SDK 處理 | 低：升 SDK 即可 |

### Step 3: 判定遷移工作量

若 `DECLARED` 落後於 current，**不要報告成「改個字串」**。跨越 breaking change 時實際要做的事，以 `2025-11-25 → 2026-07-28` 為例（現查該版 versioning 頁的 Negotiation 段確認細節）：

```
舊（handshake-based）  initialize 一次議定版本，之後沿用
新（per-request）      每個 request 在 _meta 帶 io.modelcontextprotocol/protocolVersion
                       server 逐一接受或拒絕，不支援時回 UnsupportedProtocolVersionError
                       Streamable HTTP 另在 MCP-Protocol-Version header 帶同值
                       新增 mandatory RPC: server/discover
```

四個必要項，**缺一不可**：

1. per-request `_meta` 版本宣告
2. 實作 `server/discover`（**mandatory**）
3. Streamable HTTP 的 header 處理（若有 HTTP transport）
4. **保留對 handshake-based 舊版的相容**

第 4 項最容易漏——直接切到新機制會讓還在跑舊 client 的環境全斷。官方有 Backward Compatibility 專節，遷移前必讀。

**報告時只列查證到的事實**：目前宣告什麼、官方 current 是什麼、該版本的 Negotiation 段實際要求什麼。不要憑記憶複述遷移步驟——那正是會過期的部分。

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
- 是否需要同步（建議使用 `/harness-devtools:mcp-sync`）

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

## 🔌 Protocol 版本

| | 值 |
|---|---|
| 專案宣告 | {硬編碼 YYYY-MM-DD / 由 SDK 決定 / 未宣告} |
| 官方 current | {現查所得，附查詢時間} |
| 判定 | {up-to-date / 落後（跨 N 次 breaking change）/ 無法判定} |

落後時列出該版 Negotiation 段實際要求的必要項（per-request `_meta` / `server/discover` / HTTP header / backward compat），**逐項標明「已符合 / 待實作 / 不適用」**——不適用要寫理由（例如無 HTTP transport 則 header 那項不適用）。

up-to-date 或未宣告（完全靠 SDK）時，本段只留一行結論，不展開。

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
- 建議: {如需同步，使用 `/harness-devtools:mcp-sync`}

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
- [ ] **Protocol 版本遷移**（僅在 Phase 1.5 判定落後時出現；跨 breaking change 屬大改動，建議獨立成一次 commit）
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
- **是，繼續部署** - 執行 `/harness-devtools:mcp-deploy`
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
