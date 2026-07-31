---
name: mcp-issue
description: |
  對 MCP Server 的 GitHub repo 快速開 issue（bug / feature / 改善建議），自動從 git remote、Claude Code MCP 設定、或 plugin 的 mcp.json 三種來源推斷 repo 位置。
  Use when: 用 MCP 時發現問題但當下不想處理，想先記下來；「幫這個 MCP 開個 issue」「記一下這個 bug」「file issue for MCP」。
  防止的失敗：想到問題卻沒地方記，過幾天就忘了；手動翻找 repo 位置（MCP 的 repo 通常不在當前工作目錄）。
argument-hint: <mcp-server-name> <問題描述>
allowed-tools: Bash(gh:*, ls:*, cat:*), Read, Grep, Glob
---

# MCP Issue - 快速開 GitHub Issue

對 MCP Server 的 GitHub repo 開 issue，記錄問題或需求，不中斷當前工作流程。

## 參數

- `$1` = MCP Server 名稱（如 `che-things-mcp`、`che-ical-mcp`）
- `$2+` = 問題描述（自然語言）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="locate_repo", description="Step 1: 從 MCP Server 名稱推斷 GitHub repo")
TaskCreate(name="categorize_issue", description="Step 2: 分類 issue type（bug/feature/improvement）+ 決定 label")
TaskCreate(name="create_issue", description="Step 3: gh issue create 含標題、body、label")
TaskCreate(name="report_result", description="Step 4: 回報 issue number + URL")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

## 流程

### Step 1: 找到 MCP Server 的 GitHub repo

從 MCP Server 名稱推斷 repo 位置：

```bash
# 方法 1: 從本地專案目錄的 git remote 推斷
cd ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/$1 2>/dev/null && git remote get-url origin 2>/dev/null

# 方法 2: 從 Claude Code MCP 設定推斷
cat ~/.claude.json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
servers = data.get('mcpServers', {})
name = '$1'
if name in servers:
    print(json.dumps(servers[name], indent=2))
else:
    print(f'MCP server {name} not found in config')
"

# 方法 3: 從 plugin MCP 設定推斷
# 搜尋 ~/.claude/plugins/ 中的 mcp.json
```

如果找不到 repo，問用戶提供 GitHub repo URL。

### Step 2: 分類 Issue

根據問題描述自動分類：

| 關鍵字 | Label | Title 前綴 |
|--------|-------|-----------|
| bug、壞了、錯誤、crash、fail | `bug` | `fix:` |
| feature、功能、新增、加入 | `enhancement` | `feat:` |
| 改善、優化、refactor | `enhancement` | `improve:` |
| 其他 | `enhancement` | `chore:` |

### Step 3: 建立 Issue

```bash
gh issue create \
  --repo {owner}/{repo} \
  --title "{prefix} {簡短標題}" \
  --body "$(cat <<'EOF'
## 描述

{用戶的問題描述，整理成結構化格式}

## 環境

- MCP Server: {$1}
- 版本: {從 binary 或 package.json 取得}
- 平台: macOS

## 備註

從 Claude Code 對話中記錄，待後續處理。

---
*Created via `/harness-devtools:mcp-issue`*
EOF
)" \
  --label "{label}"
```

### Step 4: 回報結果

輸出：
- Issue URL
- Issue 編號
- 分類 label

格式：
```
Issue 已建立: {url}
#{number} [{label}] {title}
```
