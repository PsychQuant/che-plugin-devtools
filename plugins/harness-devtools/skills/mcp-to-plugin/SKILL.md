---
name: mcp-to-plugin
description: 把現有 MCP Server 轉換成完整的 Claude Code Plugin。當用戶想把 MCP server 包裝成 plugin、從 ~/.claude.json 遷移 MCP 設定到 plugin、或建立帶 Keychain 密鑰管理的 MCP wrapper 時使用。也適用於「把這個 MCP 變成 plugin」、「幫我的 MCP 建 plugin wrapper」、「把密鑰從 config 移到 Keychain」等請求。
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash(security:*)
  - Bash(mkdir:*)
  - Bash(chmod:*)
  - Bash(cp:*)
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(grep:*)
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(swift:*)
  - Bash(python:*)
  - Bash(node:*)
  - AskUserQuestion
---

# MCP → Plugin 轉換器

把一個已存在的 MCP Server 轉換成標準 Claude Code Plugin，包含自動下載 wrapper、macOS Keychain 密鑰管理、session start hook、以及 command/skill 骨架。

## 為什麼要轉成 Plugin？

MCP Server 直接寫在 `~/.claude.json` 有幾個問題：
- **密鑰明文暴露** — API key 直接寫在 JSON 裡
- **不可攜** — 換機器要手動重設
- **無附加功能** — 沒有 slash commands、skills、hooks
- **無版本管理** — 沒辦法追蹤或更新

Plugin 解決以上所有問題：wrapper script 從 Keychain 讀密鑰、hook 自動檢查安裝狀態、commands 提供快捷操作、skills 提供使用指南。

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="gather_info", description="Phase 0: 識別 MCP server + 確認 plugin 參數 + 多 MCP 合併（若需）")
TaskCreate(name="create_plugin_structure", description="Phase 1: 建目錄 + plugin.json + .mcp.json")
TaskCreate(name="migrate_keychain_secrets", description="Phase 2: 儲存密鑰到 Keychain + 驗證 + 提醒使用者")
TaskCreate(name="create_wrapper_script", description="Phase 3: 寫 bin/*-wrapper.sh（含 auto-download from release）")
TaskCreate(name="create_session_hook", description="Phase 4: 寫 hooks/session-start.sh")
TaskCreate(name="generate_commands", description="Phase 5: 建 commands/ 骨架")
TaskCreate(name="sync_marketplace", description="更新 marketplace.json + 安裝")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 蒐集資訊

開始之前，需要確定以下資訊。如果能從 `~/.claude.json` 或專案目錄自動偵測就用偵測的，偵測不到的用 AskUserQuestion 問。

### Step 1: 識別 MCP Server

**情境 A**：用戶指定了一個已在 `~/.claude.json` 中設定的 MCP

```bash
# 從 ~/.claude.json 讀取 MCP 設定
cat ~/.claude.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for name, cfg in d.get('mcpServers', {}).items():
    print(f'{name}: {json.dumps(cfg, indent=2)}')
"
```

從中提取：
- `mcp_name` — MCP 名稱（如 `che-telegram-all-mcp`）
- `binary_path` — binary 路徑
- `env_vars` — 環境變數（這些就是要移到 Keychain 的密鑰）

**情境 B**：用戶指定了一個本機專案目錄

```bash
# 偵測 binary 名稱和 GitHub repo
ls Package.swift pyproject.toml package.json 2>/dev/null  # 偵測語言
gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null  # GitHub repo
```

### Step 2: 確認 Plugin 參數

用 AskUserQuestion 確認（如果無法自動偵測）：

| 參數 | 說明 | 範例 |
|------|------|------|
| `plugin_name` | Plugin 目錄名 | `che-telegram-mcp` |
| `github_repo` | GitHub owner/repo | `kiki830621/che-telegram-all-mcp` |
| `binary_name` | 執行檔名稱 | `CheTelegramAllMCP` |
| `description` | 簡短描述 | `Telegram 全功能 MCP Server` |
| `env_vars` | 需要的環境變數列表 | `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` |
| `keychain_account` | Keychain 帳號名稱 | 通常跟 mcp_name 一樣 |

### Step 3: 多 MCP 合併（可選）

如果用戶想把多個相關的 MCP Server 合併成一個 Plugin（例如 telegram-bot + telegram-all），確認：
- 每個 MCP 的 binary_name、env_vars、keychain_account
- Plugin 統一名稱

---

## Phase 1: 建立 Plugin 結構

> **Note**: Plugin 基礎結構（目錄、plugin.json、CLAUDE.md、marketplace.json）也可以用
> `/harness-devtools:plugin-create {plugin_name}` 一鍵建立。本 phase 保留手動步驟是因為
> MCP plugin 需要額外的 `bin/` 和 `.mcp.json`，plugin-create 不會自動建這些。

Plugin 目標路徑：marketplace repo 下的 `plugins/{plugin_name}/`

### Step 1: 建立目錄

```bash
PLUGIN_DIR="$MARKETPLACE_ROOT/plugins/{plugin_name}"
mkdir -p "$PLUGIN_DIR/.claude-plugin"
mkdir -p "$PLUGIN_DIR/bin"
mkdir -p "$PLUGIN_DIR/commands"
mkdir -p "$PLUGIN_DIR/hooks"
mkdir -p "$PLUGIN_DIR/skills/{skill_name}"
```

### Step 2: 建立 `.claude-plugin/plugin.json`

```json
{
  "name": "{plugin_name}",
  "version": "1.0.0",
  "description": "{description}",
  "author": { "name": "Che Cheng" },
  "license": "MIT",
  "keywords": ["mcp", "{relevant}", "{keywords}"]
}
```

### Step 3: 建立 `.mcp.json`

單一 MCP：
```json
{
  "{server_id}": {
    "type": "stdio",
    "command": "${CLAUDE_PLUGIN_ROOT}/bin/{plugin_name}-wrapper.sh",
    "description": "{description}"
  }
}
```

多 MCP（合併情境）：
```json
{
  "{server_id_1}": {
    "type": "stdio",
    "command": "${CLAUDE_PLUGIN_ROOT}/bin/{mcp1}-wrapper.sh",
    "description": "{description_1}"
  },
  "{server_id_2}": {
    "type": "stdio",
    "command": "${CLAUDE_PLUGIN_ROOT}/bin/{mcp2}-wrapper.sh",
    "description": "{description_2}"
  }
}
```

`server_id` 是 MCP 在 Claude Code 裡的識別名（出現在 tool 名稱前綴），應該簡短有意義。

---

## Phase 2: Keychain 密鑰遷移

這是轉換的核心價值 — 把 `~/.claude.json` 裡的明文密鑰移到 macOS Keychain。

### Step 1: 儲存密鑰到 Keychain

對每個環境變數執行：

```bash
security add-generic-password \
  -a "{keychain_account}" \
  -s "{ENV_VAR_NAME}" \
  -w "{secret_value}" \
  -U
```

`-a` (account) 用 MCP 名稱分組，`-s` (service) 用環境變數名，`-U` 表示如果已存在就更新。

### Step 2: 驗證能讀取

```bash
security find-generic-password -a "{keychain_account}" -s "{ENV_VAR_NAME}" -w
```

### Step 3: 提醒用戶

告知用戶：
- Keychain 密鑰綁定 macOS 使用者帳號（Login Keychain）
- 重灌 macOS 後需重新設定（但可從原始來源取回）
- 列出重灌後的恢復指令供用戶備忘

---

## Phase 3: 建立 Wrapper Script

Wrapper script 的職責：找到 binary → 從 Keychain 讀密鑰 → 啟動 MCP。

### 模板 A: 有 GitHub Release 的 MCP（可自動下載）

```bash
#!/bin/bash
# Auto-download wrapper for {binary_name}
REPO="{github_repo}"
BINARY_NAME="{binary_name}"
INSTALL_DIR="$HOME/bin"

# Find binary
BINARY=""
for loc in "$INSTALL_DIR/$BINARY_NAME" "/usr/local/bin/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

if [[ -z "$BINARY" ]]; then
    echo "$BINARY_NAME not found. Downloading from GitHub..." >&2
    mkdir -p "$INSTALL_DIR"
    URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"browser_download_url"' | grep "$BINARY_NAME" | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/')
    if [[ -n "$URL" ]]; then
        curl -sL "$URL" -o "$INSTALL_DIR/$BINARY_NAME" && chmod +x "$INSTALL_DIR/$BINARY_NAME" \
            || { echo "ERROR: Download failed." >&2; exit 1; }
        BINARY="$INSTALL_DIR/$BINARY_NAME"
        echo "Installed $BINARY_NAME to $INSTALL_DIR/" >&2
    else
        echo "No release found. Build from source: https://github.com/$REPO" >&2
        exit 1
    fi
fi

# Read credentials from macOS Keychain
{keychain_exports}

{keychain_validation}

exec "$BINARY" "$@"
```

### 模板 B: 需要從 source build 的 MCP（如依賴 TDLib）

跟模板 A 類似，但 binary 搜尋路徑多加 build 目錄，找不到時提示 build 指令而非自動下載：

```bash
# 額外搜尋 build 目錄
for loc in ... "$HOME/Developer/che-mcps/{repo_name}/.build/release/$BINARY_NAME"; do
```

找不到時：
```bash
echo "Build from source:" >&2
echo "  git clone https://github.com/$REPO.git" >&2
echo "  cd {repo_name} && swift build -c release" >&2
```

### Keychain 讀取區塊模板

對每個環境變數生成：
```bash
export {ENV_VAR}="$(security find-generic-password -a "{keychain_account}" -s "{ENV_VAR}" -w 2>/dev/null)"
```

驗證區塊：
```bash
if [[ -z "${ENV_VAR_1}" || -z "${ENV_VAR_2}" ]]; then
    echo "Credentials not found in Keychain. Set them up:" >&2
    echo "  security add-generic-password -a {keychain_account} -s {ENV_VAR_1} -w 'VALUE' -U" >&2
    echo "  security add-generic-password -a {keychain_account} -s {ENV_VAR_2} -w 'VALUE' -U" >&2
    exit 1
fi
```

**設定 executable 權限**：
```bash
chmod +x "$PLUGIN_DIR/bin/"*.sh
```

---

## Phase 4: 建立 Session Start Hook

Hook 在每次 Claude Code 啟動時檢查 MCP 安裝狀態和 Keychain 密鑰。

### hooks/hooks.json

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-mcp.sh"
      }
    ]
  }
}
```

### hooks/check-mcp.sh

為每個 MCP 生成檢查區塊：

```bash
#!/bin/bash
check_binary() {
    local name="$1" repo="$2" label="$3"
    local found=false
    for loc in "$HOME/bin/$name" "/usr/local/bin/$name" "$HOME/.local/bin/$name" "$HOME/Developer/che-mcps/$(echo "$repo" | cut -d/ -f2)/.build/release/$name"; do
        [[ -x "$loc" ]] && found=true && break
    done
    if [[ "$found" == "true" ]]; then
        echo "✓ $label installed"
    else
        echo "⚠️  $label not found"
        echo "   Install: https://github.com/$repo"
    fi
}

check_keychain() {
    local account="$1" service="$2" label="$3"
    if security find-generic-password -a "$account" -s "$service" -w &>/dev/null; then
        echo "✓ $label in Keychain"
    else
        echo "⚠️  $label not in Keychain"
        echo "   Run: security add-generic-password -a $account -s $service -w 'VALUE' -U"
    fi
}

echo "── {Plugin Name} Status ──"
# 對每個 MCP 生成 check_binary 和 check_keychain 呼叫
```

記得 `chmod +x hooks/check-mcp.sh`。

---

## Phase 5: 生成 Commands 骨架

根據 MCP 的工具列表，生成 3-5 個最常用的 slash commands。

### 偵測 MCP 工具

從 MCP source code 提取工具名稱：

```bash
# Swift MCP
grep -oE 'case "[a-z_]+"' Sources/*/Server.swift | sed 's/case "//;s/"//'

# Python MCP
grep -oE '@server\.tool\("[a-z_]+"' src/*.py | sed 's/@server\.tool("//;s/"//'

# TypeScript MCP
grep -oE 'server\.tool\("[a-z_]+"' src/*.ts | sed 's/server\.tool("//;s/"//'
```

### Command 模板

每個 command 是一個 `.md` 檔：

```markdown
---
name: {command_name}
description: {一行描述}
allowed-tools:
  - mcp__{plugin_name}__{tool_1}
  - mcp__{plugin_name}__{tool_2}
---

# {Command Title}

{使用步驟，2-5 步}
```

**挑選 command 的原則**：
- 優先選「使用者最常做的操作」而非「所有工具的一對一映射」
- 常見模式：list/overview、create/send、search、auth/setup
- 每個 command 通常組合 2-3 個 tools 完成一個工作流

---

## Phase 6: 生成 Skill 骨架

建立一個綜合性的 skill，涵蓋所有 MCP 工具的使用指南。

### Skill 模板

```markdown
---
name: {skill_name}
description: {觸發描述 — 什麼情況下使用這個 skill}
allowed-tools:
  - mcp__{plugin_name}__{tool_1}
  - mcp__{plugin_name}__{tool_2}
  ...
---

# {Skill Title}

## Tool Categories

### 1. Discovery (Start Here)
| Tool | Purpose |
|------|---------|
| ... | ... |

### 2. {Core Operations}
| Tool | Purpose |
|------|---------|
| ... | ... |

## Common Workflows

### {Workflow 1}
步驟...

### {Workflow 2}
步驟...

## Best Practices
1. ...
2. ...
```

---

## Phase 7: 清理 ~/.claude.json

把轉換完成的 MCP 從 `~/.claude.json` 移除，因為 Plugin 的 `.mcp.json` 會接管。

### Step 1: 備份

```bash
cp ~/.claude.json ~/.claude.json.backup.$(date +%s)
```

### Step 2: 移除 MCP 設定

用 Edit 工具從 `~/.claude.json` 的 `mcpServers` 中移除已轉換的 MCP entry。

### Step 3: 驗證

提醒用戶重啟 Claude Code 後，MCP 會透過 Plugin 載入而非 `~/.claude.json`。

---

## Phase 8: 完成報告

```markdown
# MCP → Plugin 轉換完成

## Plugin 資訊
- 名稱: {plugin_name}
- 位置: $MARKETPLACE_ROOT/plugins/{plugin_name}/
- MCP Servers: {列出所有 server_id}

## 密鑰管理
- 儲存位置: macOS Keychain (Login Keychain)
- 帳號: {keychain_account}
- 密鑰: {列出 ENV_VAR 名稱，不含值}

## 已建立的檔案
- .claude-plugin/plugin.json
- .mcp.json
- bin/{wrapper scripts}
- hooks/hooks.json + check-mcp.sh
- commands/{列出 commands}
- skills/{skill_name}/SKILL.md
- README.md

## 重灌恢復指令
{列出 security add-generic-password 指令，值用 placeholder}

## 下一步
- 重啟 Claude Code 載入新 Plugin
- 測試: 使用 slash commands 驗證功能
- 如需發布到 marketplace: `/harness-devtools:plugin-deploy {plugin_name}`
```
