---
name: mcp-install
description: |
  從 GitHub Release 下載 MCP Server binary 安裝到 ~/bin：偵測專案、選版本（latest 或指定）、下載、設權限、產出完成報告。
  與鄰近 skill 的分工：mcp-deploy 是把自己的 server 編譯後發到 Release；本 skill 是反向，從 Release 裝到本機。裝完發現行為不如預期、懷疑三處 binary 不一致時用 mcp-sync。
argument-hint: [version]
allowed-tools: Bash(gh:*), Bash(curl:*), Bash(chmod:*), Bash(ls:*), Bash(mkdir:*), Bash(rm:*), Read, Glob, AskUserQuestion
disable-model-invocation: true
---

# MCP Install - 從 GitHub 安裝 MCP Server

從 GitHub Release 下載並安裝 MCP Server binary 到 `~/bin`。

**部署新版本請用 `/harness-devtools:mcp-deploy`**

## 參數

- `$1` = 版本號（可選，如 `v1.2.0`）
  - 不指定：安裝最新版本
  - 指定版本：安裝指定版本（如 `v1.2.0`）
  - `--list`：列出所有可用版本

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="detect_project", description="Phase 0: 確認 MCP 專案目錄 + 讀專案資訊 + 確認 GitHub repo")
TaskCreate(name="version_selection", description="Phase 1: 選版本（latest / 指定 / list）")
TaskCreate(name="download_and_install", description="Phase 2: 確認 ~/bin + 取 binary 名 + 下載 + 設權限 + 驗證")
TaskCreate(name="report", description="Phase 3: 輸出完成報告")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 檢測專案

### Step 1: 確認目前在 MCP 專案目錄

檢查當前目錄是否為 MCP 專案：

```bash
pwd
ls -la
```

**必須存在的檔案**：
- `mcpb/manifest.json`

如果不存在，提示使用者：
> 請先 `cd` 到 MCP 專案目錄

### Step 2: 讀取專案資訊

從 `mcpb/manifest.json` 取得：
- `name`: 專案名稱（用於 GitHub repo）
- `homepage` 或 `repository.url`: GitHub URL

```bash
cat mcpb/manifest.json
```

### Step 3: 確認 GitHub repository

從 manifest.json 提取 GitHub owner 和 repo：

```bash
# 例：https://github.com/kiki830621/che-word-mcp → owner=kiki830621, repo=che-word-mcp
```

---

## Phase 1: 版本選擇

### 如果 `$1` = `--list`

列出所有可用版本：

```bash
gh release list --repo {owner}/{repo}
```

顯示結果後結束，不執行安裝。

### 如果 `$1` 有指定版本

使用指定版本（確保格式為 `v{version}`）：

```bash
VERSION="v1.2.0"  # 或使用者指定的版本
```

### 如果沒有指定版本

取得最新版本：

```bash
VERSION=$(gh release list --repo {owner}/{repo} --limit 1 --json tagName -q '.[0].tagName')
echo "最新版本: $VERSION"
```

---

## Phase 2: 下載並安裝

### Step 1: 確認 ~/bin 目錄存在

```bash
mkdir -p ~/bin
```

### Step 2: 取得 binary 名稱

從 manifest.json 取得 binary 名稱：

```bash
# 從 server.entry_point 取得：server/CheWordMCP → CheWordMCP
BINARY_NAME=$(cat mcpb/manifest.json | grep '"entry_point"' | sed 's/.*"server\/\([^"]*\)".*/\1/')
echo "Binary: $BINARY_NAME"
```

### Step 3: 下載 binary

```bash
gh release download {VERSION} \
  --repo {owner}/{repo} \
  --pattern "{BINARY_NAME}" \
  --output ~/bin/{BINARY_NAME} \
  --clobber
```

**參數說明**：
- `--pattern`: 只下載 binary 檔案（不下載 .mcpb）
- `--output`: 直接輸出到 ~/bin
- `--clobber`: 覆蓋已存在的檔案

### Step 4: 設定執行權限

```bash
chmod +x ~/bin/{BINARY_NAME}
```

### Step 5: 驗證安裝

```bash
ls -lh ~/bin/{BINARY_NAME}
file ~/bin/{BINARY_NAME}
```

---

## Phase 3: 完成報告

```markdown
# MCP 安裝完成

## 安裝資訊
- 專案: {project-name}
- 版本: {VERSION}
- Binary: ~/bin/{BINARY_NAME}

## GitHub Release
- URL: https://github.com/{owner}/{repo}/releases/tag/{VERSION}

## 下一步
- 測試: `claude mcp list` 確認 MCP 已連線
- 如需更新 Claude Code 設定，編輯 `~/.claude/settings.json`
```

---

## 快速參考

### 常用命令

```bash
# 安裝最新版
/mcp-install

# 安裝指定版本
/mcp-install v1.2.0

# 列出所有版本
/mcp-install --list
```

### 手動安裝（不使用 skill）

```bash
# 下載並安裝最新版
gh release download --repo kiki830621/che-word-mcp --pattern "CheWordMCP" --output ~/bin/CheWordMCP --clobber
chmod +x ~/bin/CheWordMCP
```

### 常見問題

| 問題 | 解決方案 |
|------|----------|
| gh 未登入 | 執行 `gh auth login` |
| 找不到 release | 確認版本號正確，使用 `--list` 查看 |
| 權限不足 | 確認 ~/bin 目錄權限 |
| binary 無法執行 | macOS 可能需要允許：System Settings → Privacy & Security |

### 與 mcp-deploy 的關係

| 命令 | 用途 | 使用時機 |
|------|------|----------|
| `/mcp-deploy` | 編譯 + 打包 + 發布 + 安裝 | 開發完成後發布新版 |
| `/mcp-install` | 從 GitHub 下載安裝 | 在其他機器安裝、更新版本 |

**Reproducibility**：`/mcp-install` 確保安裝的是已發布的 release 版本，可重現且版本明確。
