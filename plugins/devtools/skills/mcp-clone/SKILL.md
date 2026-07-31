---
name: mcp-clone
description: |
  Clone 一個指定的參考 MCP Server（給定 GitHub URL）到目標專案的 references/，建立 references/README.md，並自動分析該 repo 有哪些功能值得移植。
  與鄰近 skill 的分工：已經知道要看哪個 repo 用本 skill；還不知道有哪些競品、想先搜尋再挑，用 mcp-clone-references。
argument-hint: <github-url> [target-mcp-project]
allowed-tools: Bash(git:*), Bash(ls:*), Bash(mkdir:*), Bash(rm:*), Bash(gh:*), Read, Write, Edit, Grep, Glob, AskUserQuestion, Task, Skill, WebFetch
disable-model-invocation: true
---

# MCP Clone - 參考原始碼 Clone + 升級分析

直接 clone 指定的 GitHub repo 到當前 MCP 專案的 `references/` 資料夾，自動分析可借鏡的功能並產生升級建議。

**搜尋競品請用 `/devtools:mcp-clone-references`**
**手動升級分析請用 `/devtools:mcp-upgrade`**

## 參數

- `$1` = GitHub URL（必要，如 `https://github.com/user/repo`）
- `$2` = 目標 MCP 專案名稱（可選，如 `che-apple-mail-mcp`）
  - 不指定：從 cwd 推斷或詢問使用者
  - `--list`：列出所有 MCP 專案的 references

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="locate_target", description="Phase 0: 解析 GitHub URL + 確認目標 + 驗證存在")
TaskCreate(name="clone_to_references", description="Phase 1: 建 references/ + .gitignore + clone + 驗證")
TaskCreate(name="create_readme", description="Phase 2: 寫 references/README.md 記錄 ref repo 資訊")
TaskCreate(name="auto_analyze", description="Phase 3: 快速掃描 ref + 比對自己的 MCP 專案")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 定位目標 MCP 專案

### Step 1: 解析 GitHub URL

從 `$1` 提取：
- `REPO_OWNER`: GitHub 使用者/組織名
- `REPO_NAME`: repo 名稱
- `CLONE_URL`: 完整 clone URL

```bash
# 支援多種 URL 格式
# https://github.com/user/repo
# https://github.com/user/repo.git
# git@github.com:user/repo.git
```

### Step 2: 確認目標 MCP 專案

**情況 A**：`$2` 有指定 → 直接使用

```bash
MCP_PROJECT_DIR=~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/$2
```

**情況 B**：cwd 是 MCP 專案（有 `Package.swift` 或 `pyproject.toml` 或 `mcpb/`）→ 使用 cwd

**情況 C**：都沒有 → 列出 `~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/` 下的 MCP 專案，讓使用者選

```bash
ls -d ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/che-*/
```

使用 `AskUserQuestion` 讓使用者選擇目標專案。

### Step 3: 驗證目標專案存在

```bash
ls "$MCP_PROJECT_DIR/Package.swift" "$MCP_PROJECT_DIR/pyproject.toml" "$MCP_PROJECT_DIR/package.json" 2>/dev/null
```

至少要有一個存在。

---

## Phase 1: Clone 到 references/

### Step 1: 建立 references 資料夾

```bash
cd "$MCP_PROJECT_DIR"
mkdir -p references
```

### Step 2: 建立 .gitignore（如不存在）

建立 `references/.gitignore`：

```
# Reference source code - local only, do not commit
*
!.gitignore
!README.md
```

### Step 3: Clone

```bash
CLONE_DIR="references/$REPO_NAME"

if [ -d "$CLONE_DIR" ]; then
  echo "references/$REPO_NAME 已存在"
  # 詢問使用者：跳過 / 更新 (git pull) / 重新 clone
else
  git clone --depth 1 "$CLONE_URL" "$CLONE_DIR"
fi
```

### Step 4: 驗證 clone 成功

```bash
ls "$CLONE_DIR"
```

---

## Phase 2: 建立 references/README.md

### Step 1: 讀取參考 repo 資訊

使用 WebFetch 取得 repo 的 GitHub 頁面資訊（或讀取 clone 下來的 README）：

```bash
# 讀取 repo 的 README 取得描述
head -20 "$CLONE_DIR/README.md"
```

### Step 2: 建立或更新 README.md

如果 `references/README.md` 不存在，建立新檔。如果已存在，附加新條目。

**格式**：

```markdown
# References

參考用原始碼，僅供本地分析，不納入版本控制。

## 已 Clone 的參考專案

| Repo | URL | Language | Clone 日期 | 用途 |
|------|-----|----------|-----------|------|
| {REPO_NAME} | {GITHUB_URL} | {LANGUAGE} | {DATE} | 功能參考 |
```

---

## Phase 3: 自動分析參考 repo

### Step 1: 快速掃描參考 repo

啟動一個 `Explore` agent 分析參考 repo 的 MCP 功能：

```
分析重點：
1. 支援的 MCP tools 清單（名稱 + 功能描述 + 參數）
2. 核心架構和設計模式
3. 特色功能（error handling, i18n, batch ops, search 等）
4. 依賴和框架
```

### Step 2: 同時掃描自己的 MCP 專案

啟動另一個 `Explore` agent 分析自己的專案：

```
分析重點：
1. 現有 MCP tools 清單
2. 已實作的功能
```

**兩個 agent 平行執行**。

### Step 3: 功能比較矩陣

等兩個 agent 都完成後，建立功能比較表：

```markdown
## 功能比較

| 功能 | 自己 | {REPO_NAME} | 可借鏡？ |
|------|------|-------------|---------|
| search_messages | ✅ | ✅ | - |
| move_messages | ❌ | ✅ | ✅ |
| flag_message | ❌ | ✅ | ✅ |
| batch_operations | ❌ | ✅ | ✅ |
| attachment_handling | 基本 | 完整 | ✅ |
```

---

## Phase 4: 升級建議

### Step 1: 產生升級建議

基於 Phase 3 的比較結果，產生具體的升級建議：

```markdown
# 升級建議：基於 {REPO_NAME} 參考分析

**專案**: {MCP_PROJECT_NAME}
**參考**: {REPO_NAME} ({GITHUB_URL})
**分析日期**: {DATE}

---

## 可借鏡的功能

### 高優先（核心缺失）
| 功能 | 參考實作 | 建議方式 | 複雜度 |
|------|----------|----------|--------|
| move_messages | mail_connector.py:678 | 新增 move_email tool | 中 |

### 中優先（體驗提升）
| 功能 | 參考實作 | 建議方式 | 複雜度 |
|------|----------|----------|--------|

### 低優先（進階功能）
| 功能 | 參考實作 | 建議方式 | 複雜度 |
|------|----------|----------|--------|

---

## 設計模式可借鏡

| 模式 | 參考做法 | 自己現況 | 建議 |
|------|----------|----------|------|
| Error handling | 自定義 Exception 類 | 通用 error | 引入分類 |
| Input validation | sanitize + escape | 部分 | 完善 |

---

## 下一步

- [ ] 確認要實作哪些功能
- [ ] 用 `/devtools:mcp-upgrade features` 執行正式升級流程
- [ ] 完成後用 `/devtools:mcp-deploy` 部署新版
```

### Step 2: 儲存報告

報告儲存到 `docs/reference-analysis-{REPO_NAME}.md`。

```bash
mkdir -p "$MCP_PROJECT_DIR/docs"
```

### Step 3: 詢問是否執行升級

使用 `AskUserQuestion` 詢問：

> 分析完成！發現 {N} 個可借鏡的功能。要怎麼處理？

**選項**：
- **執行 mcp-upgrade** — 串接 `/devtools:mcp-upgrade features` 正式升級
- **我先看報告** — 結束，使用者自行決定
- **直接開始實作** — 從高優先功能開始實作

如果選擇「執行 mcp-upgrade」：

```
Skill: mcp-tools:mcp-upgrade
Args: features
```

---

## 特殊命令

### `--list`：列出所有 references

```bash
echo "=== MCP 專案 References ==="
for project in ~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/che-*/; do
  if [ -d "$project/references" ]; then
    echo ""
    echo "$(basename $project):"
    for dir in "$project"/references/*/; do
      if [ -d "$dir/.git" ]; then
        REMOTE=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "unknown")
        echo "  $(basename $dir) -> $REMOTE"
      fi
    done
  fi
done
```

---

## 快速參考

### 使用範例

```bash
# Clone 指定 repo 到當前 MCP 專案
/devtools:mcp-clone https://github.com/s-morgan-jeffries/apple-mail-mcp

# Clone 到指定 MCP 專案
/devtools:mcp-clone https://github.com/user/repo che-apple-mail-mcp

# 列出所有 references
/devtools:mcp-clone --list
```

### 與其他命令的關係

```
/devtools:mcp-clone <url>           直接 clone + 分析
        │
        ├── 自動產生功能比較和升級建議
        │
        ▼
/devtools:mcp-upgrade features  （可選）正式升級流程
        │
        ▼
/devtools:mcp-deploy            部署新版
```

| 命令 | 用途 | 輸入 |
|------|------|------|
| `/devtools:mcp-clone` | 給 URL，clone + 分析 | GitHub URL |
| `/devtools:mcp-clone-references` | 搜尋競品，批次 clone | 關鍵字 |
| `/devtools:mcp-upgrade` | 正式升級流程 | focus area |
