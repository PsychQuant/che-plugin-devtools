---
name: mcp-clone-references
description: Clone 競品 MCP Server 原始碼到 references/ 進行分析
argument-hint: [search-query]
allowed-tools: Bash(gh:*), Bash(git:*), Bash(ls:*), Bash(mkdir:*), Bash(rm:*), Read, Write, Edit, Grep, Glob, AskUserQuestion, Task
disable-model-invocation: true
---

# MCP Clone References - 競品原始碼分析

搜尋並 clone 相關 MCP Server 的原始碼到 `references/` 資料夾，用於競品分析。

## 參數

- `$1` = 搜尋關鍵字（可選，如 `calendar`、`apple reminders`）
  - 不指定：從當前專案推斷搜尋關鍵字
  - `--list`：列出已 clone 的 references
  - `--clean`：清除 references/ 資料夾

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="detect_project", description="Phase 0: 確認 MCP 專案 + 推斷搜尋關鍵字")
TaskCreate(name="search_competitors", description="Phase 1: GitHub 搜尋 + 補充搜尋 + 讓使用者選")
TaskCreate(name="setup_references_folder", description="Phase 2: 建 references/ + .gitignore")
TaskCreate(name="clone_selected_repos", description="Phase 3: 逐一 clone + 驗證")
TaskCreate(name="competitor_analysis", description="Phase 4 (可選): 分析競品")
TaskCreate(name="report", description="Phase 5: 完成報告")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 檢測專案

### Step 1: 確認目前在 MCP 專案目錄

```bash
pwd
ls -la
```

**判斷依據**（至少符合一項）：
- `Package.swift` 存在（Swift MCP）
- `package.json` 存在且含 `mcp` 相關依賴（TypeScript MCP）
- `pyproject.toml` 存在且含 `mcp` 相關依賴（Python MCP）
- `mcpb/manifest.json` 存在

### Step 2: 推斷搜尋關鍵字

如果使用者沒指定 `$1`，從專案資訊推斷：

1. 讀取 `README.md` 或 `mcpb/manifest.json` 取得專案描述
2. 提取核心功能關鍵字（如 `calendar`、`reminders`、`apple mail`）
3. 組合搜尋查詢：`mcp {keyword}` 或 `mcp server {keyword}`

**向使用者確認**推斷的搜尋關鍵字後再繼續。

---

## Phase 1: 搜尋競品

### Step 1: GitHub 搜尋

使用 `gh search repos` 搜尋相關 MCP servers：

```bash
gh search repos "{search-query} mcp" \
  --sort stars \
  --order desc \
  --limit 20 \
  --json fullName,description,stargazersCount,language,updatedAt \
  --jq '.[] | "\(.stargazersCount)⭐ \(.fullName) [\(.language)] - \(.description)"'
```

### Step 2: 補充搜尋（可選）

如果結果不夠，可嘗試不同關鍵字組合：

```bash
# 更廣泛的搜尋
gh search repos "{keyword} mcp server" --sort stars --limit 10 ...
gh search repos "{keyword} model context protocol" --sort stars --limit 10 ...
```

### Step 3: 讓使用者選擇

將搜尋結果呈現給使用者，格式如下：

```
## 搜尋結果

| # | Stars | Repo | Language | Description |
|---|-------|------|----------|-------------|
| 1 | 3000  | supermemoryai/apple-mcp | TypeScript | ... |
| 2 | 1100  | mattt/iMCP | Swift | ... |
| ...

請選擇要 clone 的 repos（輸入編號，用逗號分隔，例如 `1,2,4`）：
```

使用 `AskUserQuestion` 讓使用者選擇。

**排除自己的 repo**：如果搜尋結果包含當前專案，自動排除。

---

## Phase 2: 設置 references 資料夾

### Step 1: 建立資料夾

```bash
mkdir -p references
```

### Step 2: 建立 .gitignore

如果 `references/.gitignore` 不存在，建立：

```
# Competitor source code - local reference only
*
!.gitignore
```

**重要**：這確保競品原始碼不會被 commit 到自己的 repo。

---

## Phase 3: Clone 選定的 repos

### Step 1: 逐一 clone

對每個選定的 repo：

```bash
REPO_NAME=$(echo "{full_name}" | cut -d'/' -f2)

# 如果已存在，跳過或詢問是否更新
if [ -d "references/$REPO_NAME" ]; then
  echo "⚠️ references/$REPO_NAME 已存在"
  # 詢問使用者：跳過 / 更新 (git pull) / 重新 clone
else
  git clone --depth 1 "https://github.com/{full_name}.git" "references/$REPO_NAME"
fi
```

**使用 `--depth 1`** 減少下載量（只需原始碼，不需完整歷史）。

### Step 2: 驗證

```bash
ls -la references/
```

---

## Phase 4: 競品分析（可選）

### 詢問使用者是否要執行分析

使用 `AskUserQuestion` 詢問：

> 已 clone {N} 個 repos。要執行自動競品分析嗎？
> - 是，分析所有 repos
> - 否，我自己看

### 如果要分析

對每個 clone 的 repo，啟動一個平行的 `Task` agent 進行分析：

```
分析重點：
1. Architecture: 語言、框架、核心設計模式
2. Tools: 完整工具清單、參數、功能
3. Limitations: 致命弱點、缺少的功能
4. Unique features: 值得學習的獨特設計
5. Code quality: 錯誤處理、i18n、日期處理、測試
```

**同時啟動**對自己專案的分析 agent，用於比較。

### 整合分析結果

所有 agent 完成後，將結果整合為 `docs/COMPETITIVE_ANALYSIS.md`：

- 功能矩陣表
- 各競品深度分析摘要
- 自身優勢與待改善項目
- 可借鏡的功能列表

---

## 特殊命令

### `--list`：列出已 clone 的 references

```bash
echo "=== References ==="
for dir in references/*/; do
  if [ -d "$dir/.git" ]; then
    REMOTE=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "unknown")
    echo "  📁 $(basename $dir) → $REMOTE"
  fi
done
```

### `--clean`：清除 references

```bash
# 先確認
echo "將刪除 references/ 下所有 clone 的 repos"
# AskUserQuestion 確認
rm -rf references/*/
# 保留 .gitignore
```

---

## Phase 5: 完成報告

```markdown
# 競品 Clone 完成

## 已 clone 的 repos
| Repo | Stars | Language | Path |
|------|-------|----------|------|
| supermemoryai/apple-mcp | 3000 | TypeScript | references/apple-mcp/ |
| mattt/iMCP | 1100 | Swift | references/iMCP/ |
| ... | ... | ... | ... |

## 資料夾結構
references/
├── .gitignore          # 防止 commit 競品程式碼
├── apple-mcp/          # --depth 1 clone
├── iMCP/
└── ...

## 下一步
- 瀏覽原始碼：`ls references/{repo}/`
- 執行分析：重新執行 `/mcp-clone-references` 選擇分析
- 撰寫比較文件：結果會寫入 `docs/COMPETITIVE_ANALYSIS.md`
```

---

## 快速參考

### 常用命令

```bash
# 搜尋並 clone calendar 相關 MCP servers
/mcp-clone-references calendar

# 搜尋並 clone apple reminders 相關
/mcp-clone-references apple reminders

# 自動推斷關鍵字
/mcp-clone-references

# 列出已 clone 的 repos
/mcp-clone-references --list

# 清除 references
/mcp-clone-references --clean
```

### 與其他命令的關係

| 命令 | 用途 | 使用時機 |
|------|------|----------|
| `/mcp-clone-references` | Clone 競品原始碼 | 開發初期，了解市場 |
| `/mcp-upgrade` | 分析並提議升級 | 借鏡競品後改善自己 |
| `/mcp-deploy` | 編譯打包發布 | 改善完成後發布 |
