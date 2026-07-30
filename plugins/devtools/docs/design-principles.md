# MCP Tools 設計原理

本文件記錄 mcp-tools plugin 各命令的設計決策和原理。

---

## 命令分工設計

### 開發 vs 使用分離

```
開發者視角                    使用者視角
    │                             │
    ▼                             ▼
┌──────────────┐           ┌──────────────┐
│  mcp-deploy  │  ──────→  │  mcp-install │
└──────────────┘  發布後   └──────────────┘
    │                             │
本地編譯+發布                從 GitHub 下載
```

**為什麼分開？**

| 考量 | mcp-deploy | mcp-install |
|------|------------|-------------|
| **版本來源** | 本地 build（可能未 commit） | GitHub Release（已發布） |
| **可重現性** | 低（依賴本地環境） | 高（任何人都能下載同版本） |
| **使用情境** | 開發機器 | 任何機器 |
| **需要原始碼** | 是 | 否 |

**設計原則**：Reproducibility > Convenience

---

## mcp-deploy 設計

### Phase 設計

```
Phase 0: 檢測 → Phase 1: 編譯 → Phase 2: 打包 → Phase 3: 發布
```

**為什麼用 Phase？**
1. **可中斷**：每個 Phase 完成後都是穩定狀態
2. **可跳過**：未來可支援 `--skip-build` 等參數
3. **易除錯**：問題發生時容易定位是哪個階段

### Universal Binary

```bash
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create ... -output
```

**為什麼不只編譯 arm64？**
- 相容性：仍有使用者使用 Intel Mac
- 發布一次：不需要維護兩個 binary
- macOS 標準：Apple 自己的 binary 都是 Universal

### MCPB 套件結構

```
mcpb/
├── manifest.json      # 套件 metadata
├── PRIVACY.md         # 隱私政策（MCPB 規範要求）
├── server/            # 執行檔
│   └── BinaryName
└── project.mcpb       # 打包後的 ZIP
```

**為什麼 .mcpb 放在 mcpb/ 內？**
- 避免根目錄混亂
- 方便 .gitignore 管理
- 與 server/ 和 manifest.json 放一起，結構清晰

---

## mcp-install 設計

### 只從 GitHub 下載

**為什麼不支援本地安裝？**

```
選項 A: 本地 + GitHub    選項 B: 只有 GitHub ✓
    │                         │
複雜度高                   單一來源
版本混淆                   版本明確
難以重現                   可重現
```

**設計決策**：mcp-deploy 結尾已經會 `cp` 到 `~/bin`，所以開發階段不需要另外的本地安裝命令。

### gh CLI vs curl

```bash
# gh（選用）
gh release download v1.2.0 --pattern "Binary" --output ~/bin/Binary

# curl（替代方案）
curl -L -o ~/bin/Binary https://github.com/.../releases/download/v1.2.0/Binary
```

**為什麼用 gh？**
1. **認證**：私有 repo 自動處理認證
2. **簡潔**：`--pattern` 可以只下載特定檔案
3. **錯誤處理**：版本不存在時有清楚錯誤訊息

---

## mcp-upgrade 設計

### 分析範圍

```
依賴更新 (deps)     結構優化 (structure)    功能建議 (features)
    │                     │                      │
    ▼                     ▼                      ▼
MCP SDK 版本         缺少 LICENSE?           批次操作?
其他套件更新         缺少 CHANGELOG?         搜尋功能?
```

**為什麼分三類？**
- 使用者可以選擇只看某一類
- 不同類別的修復優先級不同
- 避免報告過長

### 功能建議邏輯

```
現有 tools 分析
    │
    ▼
有 create_X 但沒有 create_X_batch? → 建議批次操作
有 get_X 但沒有 search_X?          → 建議搜尋功能
有 list_X 但沒有 get_X_detail?     → 建議詳情功能
```

**設計原則**：基於現有 tools 推斷缺失功能，而非通用建議

---

## 除錯流程設計

### 三層診斷

```
diagnose (連線層) → debug (功能層) → test (驗證層)
     │                  │                │
     ▼                  ▼                ▼
  Server 能連?      功能有 bug?      所有功能正常?
```

**為什麼分三個命令？**

| 情境 | 適合命令 |
|------|----------|
| Server 完全無反應 | diagnose |
| 某功能報錯 | debug |
| 開發完成想驗證 | test |

**設計原則**：從粗到細，逐步縮小問題範圍

---

## 檔案組織設計

### 目錄結構

```
mcp-tools/
├── .claude-plugin/
│   └── plugin.json      # Plugin metadata
├── commands/            # Skill 定義檔
│   ├── new-mcp-app.md
│   ├── mcp-deploy.md
│   ├── mcp-install.md
│   ├── mcp-upgrade.md
│   ├── diagnose.md
│   ├── debug.md
│   └── test.md
├── docs/                # 設計文檔
│   └── design-principles.md
└── README.md            # 使用說明
```

**為什麼 commands/ 用 .md？**
- Claude Code Skill 格式要求
- Markdown 可讀性高
- 支援 YAML front matter 定義 metadata

### 命名慣例

| 類型 | 命名 | 範例 |
|------|------|------|
| 開發流程 | `mcp-*` | mcp-deploy, mcp-install |
| 除錯工具 | 動詞 | diagnose, debug, test |

---

## 版本策略

### Semantic Versioning

```
MAJOR.MINOR.PATCH
  │     │     │
  │     │     └── Bug fix, 文檔更新
  │     └──────── 新功能（向後相容）
  └────────────── 破壞性變更
```

### 變更紀錄

| 版本 | 類型 | 說明 |
|------|------|------|
| 1.5.0 | MINOR | 新增 mcp-install |
| 1.4.x | PATCH | 修正 manifest 格式 |
| 1.2.0 | MINOR | 新增 mcp-deploy, mcp-upgrade |
| 1.1.0 | MINOR | 新增 debug, test |
| 1.0.0 | MAJOR | 初始版本 |

---

## Swift MCP 開發陷阱

### actor vs class

**問題**：使用 Swift `actor` 作為 MCP Server 類型會導致 "Failed to connect" 錯誤。

```swift
// ✗ 不能用 - actor 隔離機制與 MCP SDK 不相容
actor WordMCPServer {
    init() { ... }
}

// ✓ 正確 - 使用 class
class WordMCPServer {
    init() async { ... }
}
```

**原因**：
- Swift `actor` 提供嚴格的資料隔離
- MCP SDK 的 callback handlers 無法正確跨越 actor 邊界
- 導致 stdin/stdout 通訊失敗

### capabilities 宣告

**問題**：Server 初始化時未宣告 capabilities 會導致連線失敗。

```swift
// ✗ 不能用 - 缺少 capabilities
Server(name: "...", version: "...")

// ✓ 正確 - 宣告 tools capability
Server(
    name: "...",
    version: "...",
    capabilities: .init(tools: .init())
)
```

**原因**：MCP client 需要知道 server 支援什麼功能才能正確初始化。

### Handler 註冊時機

**問題**：Handler 註冊順序不正確可能導致競爭條件。

```swift
// ✓ 推薦 - 在 init() 中註冊
init() async {
    self.server = Server(...)
    await registerHandlers()  // 在 start() 之前
}

func run() async throws {
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
}
```

### lipo 合併後必須重新簽名

**問題**：`lipo -create` 合併的 universal binary 執行時被 macOS 以 SIGKILL (exit 137) 終止。

```bash
# ✗ binary 啟動即被殺掉
lipo -create .build/arm64/.../Binary .build/x86_64/.../Binary -output ~/bin/Binary
~/bin/Binary  # exit 137 (SIGKILL)

# ✓ 正確 - lipo 後必須 codesign
lipo -create .build/arm64/.../Binary .build/x86_64/.../Binary -output ~/bin/Binary
codesign --force --sign - ~/bin/Binary
~/bin/Binary  # 正常啟動
```

**原因**：
- `swift build` 產出的 binary 帶有 adhoc linker-signed signature
- `lipo -create` 合併兩個架構時，會**破壞**原始 code signature
- macOS runtime enforcement 偵測到 signature 無效，直接 SIGKILL
- `cp` 複製 binary 也可能導致 signature 失效（視檔案系統而定）

**規則**：任何 `lipo` 或 `cp` binary 操作後，都必須執行：

```bash
codesign --force --sign - <binary-path>
```

**影響的命令**：
- `mcp-deploy`：Phase 1 A3 (lipo) + Phase 3 Step 5 (cp to ~/bin)
- `mcpb-sync`：所有同步選項
- `debug`：Phase 3 rebuild 後同步

### AppleScript MCP 啟動時 TCC 權限 Timeout

**問題**：AppleScript-based MCP Server（che-apple-mail-mcp、che-things-mcp 等）首次啟動時，macOS TCC (Transparency, Consent, and Control) 會在第一次 AppleScript 呼叫時彈出權限對話框。但此時 MCP client 已經連線並發送 tool call，等不到回應就 timeout，返回 `-1743: Not authorized` 錯誤。

```
時序問題：
MCP Client         MCP Server              macOS TCC
    │                   │                      │
    ├── connect ──────→ │                      │
    ├── tool call ────→ │                      │
    │                   ├── AppleScript ─────→ │
    │                   │                      ├── 彈出權限對話框
    │   timeout! ←──────┤                      │  （使用者還沒來得及點）
    │                   │                      │
```

**解決方案**：在 MCP server 啟動前（`server.start(transport:)` 之前）加入輕量級的 AppleScript warm-up，提前觸發權限對話框。

```swift
// MailController.swift — 新增 checkAccess() 方法
actor MailController {
    // ...

    /// Trigger a minimal AppleScript to prompt macOS permission dialog early.
    @discardableResult
    func checkAccess() -> Bool {
        let script = """
        tell application "Mail"
            return application version
        end tell
        """
        do {
            let _ = try runScript(script)
            FileHandle.standardError.write(
                Data("[server-name] AppleScript access: granted\n".utf8)
            )
            return true
        } catch {
            FileHandle.standardError.write(
                Data("[server-name] AppleScript access: denied - \(error.localizedDescription)\n".utf8)
            )
            return false
        }
    }
}

// main.swift — 在 server 啟動前呼叫
await MailController.shared.checkAccess()

let server = try await MyCoolMCPServer()
try await server.run()
```

**設計要點**：

| 決策 | 原因 |
|------|------|
| 用 `application version` | 最輕量的唯讀 AppleScript，不修改任何狀態 |
| 不 throw | 失敗不阻擋 server 啟動（graceful degradation） |
| 日誌寫 stderr | stdout 保留給 MCP stdio transport 的 JSON-RPC |
| `@discardableResult` | 呼叫端可選擇忽略回傳值 |
| 在 `server.start()` 前 | 此時 MCP client 尚未連線，不會有 timeout |

```
修正後時序：
MCP Client         MCP Server              macOS TCC
    │                   │                      │
    │                   ├── warm-up ──────────→ │
    │                   │                      ├── 彈出權限對話框
    │                   │                      ├── 使用者點允許 ✓
    │                   │ ←── granted ─────────┤
    ├── connect ──────→ │                      │
    ├── tool call ────→ │                      │
    │                   ├── AppleScript ─────→ │  （已有權限，立即執行）
    │   success ←───────┤                      │
```

**適用 MCP**：所有使用 AppleScript 的 MCP Server（che-apple-mail-mcp、che-things-mcp 等）。

**驗證方式**：
```bash
# 模擬首次執行（重置 TCC 權限）
tccutil reset AppleEvents ~/bin/BinaryName

# 直接執行 binary，確認 stderr 輸出
~/bin/BinaryName 2>&1 | head -1
# 預期：[server-name] AppleScript access: granted 或 denied
```

### Plugin .mcp.json server key 命名限制

**問題**：Claude API 限制 tool name 最長 **64 字元**。Plugin 透過 `.mcp.json` 掛載 MCP server 時，tool name 格式為：

```
mcp__plugin_{plugin-name}_{server-key}__{tool-name}
```

當 server key 與 plugin 同名（例如 `che-apple-mail-mcp`），前綴就佔 49 字元，留給 tool name 只剩 15 字元。

```
# ✗ server key = plugin name → 前綴 49 字元，最長 tool 76 字元
mcp__plugin_che-apple-mail-mcp_che-apple-mail-mcp__extract_name_from_address (76)

# ✓ 短 server key → 前綴 35 字元，最長 tool 62 字元
mcp__plugin_che-apple-mail-mcp_mail__extract_name_from_address (62)
```

**API 錯誤訊息**：
```
400 invalid_request_error: tool_reference.tool_name: String should have at most 64 characters
```

**規則**：`.mcp.json` 的 server key 使用短名稱：

| Plugin | Server Key | 前綴長度 | 最長 tool 全名 |
|--------|-----------|---------|--------------|
| che-apple-mail-mcp | `mail` | 35 | 62 |
| che-things-mcp | `things` | 37 | 57 |
| che-word-mcp | `word` | 33 | 57 |
| che-ical-mcp | `ical` | 33 | 55 |
| che-duckdb-mcp | `duckdb` | 37 | 54 |

**注意**：這只影響 plugin 掛載的 MCP（`mcp__plugin_*` namespace）。直接在 `~/.claude.json` 或 `.mcp.json`（非 plugin）掛載的 MCP server 使用 `mcp__{server-key}__` 格式，前綴短很多，通常不會超限。

### 參考實作

參考 che-ical-mcp 的 Server.swift 作為標準模式。

---

## 未來考量

### 可能的擴展

1. **mcp-init**：在現有專案加入 MCP 支援（vs new-mcp-app 建立新專案）
2. **mcp-publish**：發布到 MCPB marketplace（如果有的話）
3. **mcp-doctor**：整合 diagnose + debug + test 的一站式健康檢查

### 不會加入的功能

1. **GUI**：保持 CLI-first 設計
2. **自動修復**：只提供建議，修復交給使用者決定
3. **多專案管理**：每個專案獨立，避免 monorepo 複雜度
