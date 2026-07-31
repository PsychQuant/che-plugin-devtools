---
name: mcp-publish
description: |
  把 MCP Server 上架或更新到官方 MCP Registry，以及 Glama、awesome-mcp-servers 等第三方平台：建立或更新 server.json、通過認證、執行發布。
  與鄰近 skill 的分工：mcp-deploy 是發到自己的 GitHub Release（決定別人裝不裝得到）；本 skill 是對外曝光那一層（決定別人找不找得到）。兩者都要做，順序是先 deploy 後 publish。
argument-hint: [project-name]
allowed-tools: Read, Write, Edit, Bash(brew:*), Bash(curl:*), Bash(mcp-publisher:*), Bash(shasum:*), Bash(git:*), Bash(gh:*), Bash(ls:*), Bash(cat:*), Bash(which:*), Bash(open:*), Bash(python3:*), Bash(cd:*), Bash(osascript:*), Bash(sleep:*), Bash(agent-browser:*), Grep, Glob, AskUserQuestion
disable-model-invocation: true
---

# MCP Publish - 發布到 MCP Registry 及公開平台

將 MCP Server 發布（或更新）到 [官方 MCP Registry](https://registry.modelcontextprotocol.io)，並可選擇提交到第三方平台。

**前置作業**：請先用 `/devtools:mcp-deploy` 完成 GitHub Release。

## 參數

- `$1` = 專案名稱（可選，如 `che-ical-mcp`）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="env_check", description="Phase 0: 確認專案 + 檢查 GitHub Release + 安裝 mcp-publisher + Registry 狀態")
TaskCreate(name="create_server_json", description="Phase 1 (首次): 收集資訊 + 算 SHA-256 + 寫 server.json + Registry API 驗證")
TaskCreate(name="update_server_json", description="Phase 1-U (更新): 讀現有 server.json + 取新版本 binary 資訊")
TaskCreate(name="publish_to_registry", description="Phase 2: 實際 publish 到 MCP Registry")
TaskCreate(name="verify_publication", description="Phase 3: 驗證已上架 + 測試安裝")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 環境檢查

### Step 1: 確認專案目錄

如果提供了 `$1`，嘗試 `cd` 到該目錄：

```bash
# 常見位置
ls -d ~/Developer/mcp/$1 2>/dev/null || ls -d ~/Developer/$1 2>/dev/null
```

否則確認當前目錄是 MCP 專案。

### Step 2: 檢查 GitHub Release 是否存在

```bash
REPO_URL=$(git remote get-url origin 2>/dev/null)
OWNER_REPO=$(echo "$REPO_URL" | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/')
gh release list --repo "$OWNER_REPO" --limit 3
```

**沒有 Release？** 提示：
> 請先執行 `/devtools:mcp-deploy` 建立 GitHub Release。

### Step 3: 取得專案資訊

```bash
# 專案名稱
PROJECT_NAME=$(basename $(pwd))

# GitHub owner — namespace 用，一律從 remote 推導，不要硬編碼
# （umbrella 內兩種都有：個人 repo = kiki830621，org repo = PsychQuant）
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)

# 最新版本和 Release 資訊
LATEST_TAG=$(gh release list --repo "$OWNER_REPO" --limit 1 --json tagName -q '.[0].tagName')
LATEST_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//')
echo "專案: $PROJECT_NAME"
echo "Repo: $OWNER_REPO"
echo "Owner: $OWNER"
echo "最新版本: $LATEST_TAG ($LATEST_VERSION)"
```

> **⚠️ Namespace 隨 repo owner 走**：MCP Registry 的 server `name` 就是唯一識別。`io.github.kiki830621/X` 與 `io.github.PsychQuant/X` 是**兩個不同的 server**（repo 若在 org 間轉移，發布到新 owner 命名空間 = 新增條目，舊條目停在最後發布的版本）。所有 server.json 模板的 `{owner}` 一律代入上面推導的 `$OWNER`，且必須與 `repository.url` 的 owner 一致。發到 `io.github.<org>/*`（如 PsychQuant）需登入的 GitHub 帳號是該 org 成員。

### Step 4: 安裝 mcp-publisher CLI

```bash
which mcp-publisher
```

如果未安裝：

```bash
brew install mcp-publisher
```

如果 brew 不可用，使用 curl：

```bash
curl -fsSL https://registry.modelcontextprotocol.io/cli/install.sh | sh
```

驗證安裝：

```bash
mcp-publisher --version
```

### Step 5: 檢查 Registry 發布狀態

```bash
curl -s "https://registry.modelcontextprotocol.io/v0.1/servers?search=$PROJECT_NAME" | python3 -m json.tool 2>/dev/null || echo "尚未發布"
```

根據結果判斷模式：

| `metadata.count` | 模式 | 下一步 |
|---|---|---|
| 0 | **首次發布** | → Phase 1 建立 server.json |
| > 0 | **版本更新** | → 比較 Registry 版本與 GitHub Release 版本 |

#### 版本更新判斷

如果已發布過，比較版本：
- **Registry latest 版本** = `servers[-1].server.version`（`_meta` 中 `isLatest: true` 的那筆）
- **GitHub Release 版本** = `$LATEST_VERSION`

| 情況 | 處理 |
|---|---|
| Registry 版本 = Release 版本 | 已是最新，跳到 Phase 4 處理第三方平台 |
| Registry 版本 < Release 版本 | → Phase 1-U 更新 server.json |

---

## Phase 1: 建立 server.json（首次發布）

### Step 1: 確認是否已有 server.json

```bash
ls server.json 2>/dev/null
```

如果已存在，跳到 Step 5 驗證內容。

### Step 2: 收集必要資訊

```bash
# Binary 名稱（Swift 專案）
BINARY_NAME=$(ls mcpb/server/ | grep -v '.sh' | grep -v '.mcpb' | head -1)

# 從 manifest.json 或 Package.swift 取得描述
cat mcpb/manifest.json 2>/dev/null
```

### Step 3: 計算 SHA-256 Hash

```bash
# 使用本地 binary（如果剛 deploy 過，應與 Release 一致）
shasum -a 256 mcpb/server/$BINARY_NAME | awk '{print $1}'
```

**重要**：`fileSha256` 必須對應 GitHub Release 上的 binary。建議從 Release 下載驗證：

```bash
DOWNLOAD_URL="https://github.com/$OWNER_REPO/releases/download/$LATEST_TAG/$BINARY_NAME"
curl -sL "$DOWNLOAD_URL" -o /tmp/_verify_binary
shasum -a 256 /tmp/_verify_binary | awk '{print $1}'
rm /tmp/_verify_binary
```

如果兩個 hash 不一致，使用 Release 上的 hash。

### Step 4: 編寫 server.json

**⚠️ 重要：所有欄位名使用 camelCase**

#### Swift (MCPB Binary) 模板

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.{owner}/{project-name}",
  "description": "{description, max 100 chars}",
  "version": "{version}",
  "repository": {
    "url": "https://github.com/{owner}/{project-name}",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "mcpb",
      "identifier": "https://github.com/{owner}/{project-name}/releases/download/v{version}/{BinaryName}",
      "version": "{version}",
      "transport": {
        "type": "stdio"
      },
      "fileSha256": "{sha256-hash}"
    }
  ]
}
```

#### Python (PyPI) 模板

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.{owner}/{project-name}",
  "description": "{description, max 100 chars}",
  "version": "{version}",
  "repository": {
    "url": "https://github.com/{owner}/{project-name}",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "pypi",
      "identifier": "{pypi-package-name}",
      "version": "{version}",
      "transport": {
        "type": "stdio"
      }
    }
  ]
}
```

#### TypeScript (npm) 模板

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.{owner}/{project-name}",
  "description": "{description, max 100 chars}",
  "version": "{version}",
  "repository": {
    "url": "https://github.com/{owner}/{project-name}",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "npm",
      "identifier": "{npm-package-name}",
      "version": "{version}",
      "transport": {
        "type": "stdio"
      }
    }
  ]
}
```

**⚠️ 常見格式錯誤**：

| 錯誤 | 正確 |
|------|------|
| `"name": "che-word-mcp"` | `"name": "io.github.{owner}/che-word-mcp"`（`{owner}` = repo owner）|
| `"version_detail": {...}` | `"version": "1.0.0"` |
| `"registry_type"` (snake_case) | `"registryType"` (camelCase) |
| `"file_sha256"` (snake_case) | `"fileSha256"` (camelCase) |
| `"repository": { "license": "MIT" }` | 不支援 `license`，移除 |
| 缺少 `transport` | 必須包含 `"transport": {"type": "stdio"}` |
| packages 中含 `name`、`environment`、`runtime` | 這些欄位不被接受 |
| `description` 超過 100 字元 | 精簡到 100 字元以內 |

### Step 5: 用 Registry API 驗證

**發布前必做**：使用 `/validate` endpoint 確認格式正確：

```bash
cat server.json | curl -s -X POST "https://registry.modelcontextprotocol.io/v0.1/validate" \
  -H "Content-Type: application/json" -d @- | python3 -m json.tool
```

**預期輸出**：`{"valid": true, "issues": []}`

如果有錯誤，根據 `errors[].message` 和 `errors[].location` 修正後重新驗證。

---

## Phase 1-U: 更新 server.json（版本更新）

當 server.json 已存在且需要更新到新版本時：

### Step 1: 讀取現有 server.json

```bash
cat server.json
```

### Step 2: 取得新版本的 Binary 資訊

```bash
# 找出 Release 上的 binary 檔名
gh release view "$LATEST_TAG" --repo "$OWNER_REPO" --json assets -q '.assets[].name'
```

### Step 3: 計算新版本 SHA-256

```bash
# 從 Release 下載並計算 hash
BINARY_NAME=$(gh release view "$LATEST_TAG" --repo "$OWNER_REPO" --json assets -q '.assets[0].name')
DOWNLOAD_URL="https://github.com/$OWNER_REPO/releases/download/$LATEST_TAG/$BINARY_NAME"
curl -sL "$DOWNLOAD_URL" -o /tmp/_verify_binary
NEW_SHA256=$(shasum -a 256 /tmp/_verify_binary | awk '{print $1}')
rm /tmp/_verify_binary
echo "New SHA-256: $NEW_SHA256"
```

### Step 4: 更新 server.json

需要更新以下欄位：

| 欄位 | 舊值 | 新值 |
|------|------|------|
| `version` (頂層) | 舊版本 | `$LATEST_VERSION` |
| `packages[].version` | 舊版本 | `$LATEST_VERSION` |
| `packages[].identifier` | 舊版本的 URL | 新版本的 download URL |
| `packages[].fileSha256` | 舊 hash | `$NEW_SHA256` |

用 Edit tool 修改 server.json，或用 python3 更新：

```bash
python3 -c "
import json
with open('server.json') as f:
    data = json.load(f)
data['version'] = '$LATEST_VERSION'
for pkg in data.get('packages', []):
    pkg['version'] = '$LATEST_VERSION'
    if 'identifier' in pkg and 'releases/download/' in pkg['identifier']:
        # Update download URL to new version
        parts = pkg['identifier'].rsplit('/releases/download/', 1)
        repo_url = parts[0]
        binary_name = parts[1].split('/')[-1]
        pkg['identifier'] = f'{repo_url}/releases/download/$LATEST_TAG/{binary_name}'
    if 'fileSha256' in pkg:
        pkg['fileSha256'] = '$NEW_SHA256'
with open('server.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print('Updated server.json')
"
```

### Step 5: 驗證更新後的 server.json

```bash
cat server.json | python3 -m json.tool
cat server.json | curl -s -X POST "https://registry.modelcontextprotocol.io/v0.1/validate" \
  -H "Content-Type: application/json" -d @- | python3 -m json.tool
```

確認 `{"valid": true, "issues": []}` 後繼續。

---

## Phase 2: 認證與發布

### Step 1: 登入 GitHub

```bash
mcp-publisher login github
```

這會顯示 device code，需要在瀏覽器中前往 https://github.com/login/device 輸入。

**Namespace 規則**：
- GitHub 認證後，你的 namespace 是 `io.github.{username}`，以及**你所屬 org 的** `io.github.{org}`
- 例如：`io.github.kiki830621/che-ical-mcp`（個人）或 `io.github.PsychQuant/che-ical-mcp`（org，登入帳號須為 PsychQuant 成員）
- server.json 的 `name` owner 必須與 `repository.url` 的 owner 一致

**注意**：token 會過期，如果 publish 時收到 401 錯誤，重新 `mcp-publisher login github`。

### Step 2: 發布

```bash
mcp-publisher publish
```

CLI 會：
1. 讀取當前目錄的 `server.json`
2. 驗證格式
3. 上傳 metadata 到 Registry（Registry 只存 metadata，不存 binary）
4. 回傳發布結果

**預期輸出**（首次）：
```
Publishing to https://registry.modelcontextprotocol.io...
✓ Successfully published
✓ Server io.github.{owner}/{project-name} version {version}
```

**預期輸出**（更新）：
```
Publishing to https://registry.modelcontextprotocol.io...
✓ Successfully published
✓ Server io.github.{owner}/{project-name} version {new-version}
```

**注意**：不能覆蓋已發布的版本。如果版本號相同會報錯，必須使用新版本號。

### Step 3: 驗證發布成功

```bash
curl -s "https://registry.modelcontextprotocol.io/v0.1/servers?search=$PROJECT_NAME" | python3 -m json.tool
```

確認：
- `metadata.count` > 0
- 最新版本的 `_meta.isLatest` 為 `true`
- `version` 與 `$LATEST_VERSION` 一致

---

## Phase 3: 更新專案文件

### Step 1: 將 server.json 變更加入版本控制

首次發布：
```bash
git add server.json
git commit -m "Add server.json for MCP Registry publishing

Published as io.github.{owner}/{project-name} on the official MCP Registry.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
git push origin main
```

版本更新：
```bash
git add server.json
git commit -m "Update server.json to {version} for MCP Registry

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
git push origin main
```

### Step 2: 更新 README.md（首次發布時）

在 README 的 Installation 區塊加入：

```markdown
### MCP Registry

Published on the [Official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.{owner}/{project-name}`.
```

**檢查**：如果 README 已有此資訊則跳過。所有語言版本的 README 都要同步更新。

### Step 3: 提交文件更新

```bash
git add README.md README_zh-TW.md 2>/dev/null
git commit -m "Add MCP Registry information to README

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
git push origin main
```

---

## Phase 4: 第三方平台

使用 AskUserQuestion 詢問：
> 是否要提交到第三方平台？（可多選）
> 1. 不需要（只發布到官方 Registry）
> 2. Glama（glama.ai — 有 Docker 檢查流程）
> 3. awesome-mcp-servers（GitHub Awesome List）
> 4. mcpservers.org

### 選項 A: Glama

使用 `agent-browser`（Playwright）搭配 `--session glama` 保存登入狀態。

#### 檢查是否已在 Glama 上

```bash
agent-browser open "https://glama.ai/mcp/servers?search=$PROJECT_NAME" --session glama --headed
agent-browser snapshot -i --session glama --headed
```

從 snapshot 中搜尋是否有該專案的連結。如果找到，表示已提交過，跳過。

#### 登入檢查

如果 snapshot 中出現 `Sign Up` 按鈕而非使用者頭像，表示未登入：

```bash
# 導航到登入頁面
agent-browser open "https://glama.ai/auth/sign-in" --session glama --headed
```

使用 AskUserQuestion 提示使用者：
> 請在彈出的瀏覽器視窗中完成 GitHub 登入（點 GitHub 圖示）。登入完成後告訴我。

`--session glama` 會保存登入狀態，後續操作不需要再登入。

#### 提交到 Glama

1. 導航到 MCP Servers 頁面並點擊「Add Server」：

```bash
agent-browser open "https://glama.ai/mcp/servers" --session glama --headed
agent-browser snapshot -i --session glama --headed
# 找到 "Add Server" 按鈕的 ref（通常在前 20 個元素中）
agent-browser click @eN --session glama --headed  # N = Add Server 按鈕的 ref
```

2. 等彈窗出現後，取得表單欄位 ref：

```bash
agent-browser snapshot -i --session glama --headed
# 預期看到：textbox "Name", textbox "Description", textbox "GitHub Repository URL", button "Submit for Review"
```

3. 填入表單：

```bash
agent-browser fill @eN "PROJECT_NAME" --session glama --headed
agent-browser fill @eN "DESCRIPTION" --session glama --headed
agent-browser fill @eN "https://github.com/OWNER/REPO" --session glama --headed
```

替換 `@eN` 為 snapshot 中對應欄位的 ref，替換 `PROJECT_NAME`、`DESCRIPTION`、`OWNER/REPO` 為實際值。

4. 截圖確認填寫內容後，點擊提交：

```bash
agent-browser screenshot /tmp/glama-filled.png --session glama --headed
agent-browser click @eN --session glama --headed  # N = Submit for Review 按鈕的 ref
```

5. 等待確認：

```bash
sleep 3
agent-browser screenshot /tmp/glama-submitted.png --session glama --headed
```

如果表單已關閉回到主頁面，表示提交成功。

6. 關閉瀏覽器（session 會保留）：

```bash
agent-browser close --session glama
```

**注意事項**：
- `--session glama` 保存登入狀態，下次執行不需要重新登入
- `--headed` 讓瀏覽器可見，方便使用者在需要時手動介入（如 2FA）
- Glama 審核需要時間，提交後狀態為 pending review
- macOS-only server 無法通過 Docker 檢查，但通常人工審核會放行
- 如果出現 `A submission for this repository is already pending review`，表示已提交成功
- 審核通過後，Glama 頁面 URL 通常為 `https://glama.ai/mcp/servers/{owner}-{project-name}`

### 選項 B: awesome-mcp-servers

```bash
open "https://github.com/punkpeye/awesome-mcp-servers"
```

Fork repo → 在對應分類加入條目 → 提交 PR。

**最新要求**（2025-03 起）：
- 必須先在 Glama 上通過審核
- PR 中需附上 Glama 連結（格式：`[glama](https://glama.ai/mcp/servers/...)`）
- 需放在 GitHub repo 連結之後

### 選項 C: mcpservers.org

```bash
open "https://mcpservers.org"
```

通常需要填寫表單或提交 PR。提示使用者手動完成。

---

## Phase 5: 完成報告

```markdown
# MCP 發布完成

## 專案資訊
- 專案: {project-name}
- 版本: {version}
- Namespace: io.github.{owner}/{project-name}

## 發布狀態

### 官方 MCP Registry
- 狀態: {首次發布 / 更新到 {version} / 已是最新}
- 搜尋: https://registry.modelcontextprotocol.io/v0.1/servers?search={project-name}

### Glama
- 狀態: {已提交等待審核 / 已上線 / 未提交}
- 連結: https://glama.ai/mcp/servers/{owner}-{project-name}

### awesome-mcp-servers
- 狀態: {PR 已提交 / 已合併 / 未提交}

### mcpservers.org
- 狀態: {已提交 / 未提交}

## 已完成
- [x] server.json 已建立/更新並驗證
- [x] mcp-publisher 認證完成
- [x] 發布到 MCP Registry
- [x] 驗證 Registry 可查詢
- [x] server.json 已提交到 git
- [x] README 已更新
- [ ] Glama（{狀態}）
- [ ] awesome-mcp-servers（{狀態}）
- [ ] mcpservers.org（{狀態}）

## 後續版本更新
更新版本時：
1. 執行 `/devtools:mcp-deploy` 部署新版本
2. 執行 `/devtools:mcp-publish` 更新 Registry（自動偵測需要更新）
```

---

## 快速參考

### server.json 必要欄位

| 欄位 | 必要 | 說明 |
|------|:---:|------|
| `name` | ✅ | `io.github.{username}/{project}` 格式 |
| `description` | ✅ | 最多 100 字元 |
| `version` | ✅ | 語義化版本號（字串） |
| `packages` | ✅ | 至少一個套件 |
| `packages[].registryType` | ✅ | `mcpb`/`npm`/`pypi`/`nuget`/`oci` |
| `packages[].identifier` | ✅ | 套件識別符 |
| `packages[].transport` | ✅ | `{"type": "stdio"}` |
| `packages[].fileSha256` | 推薦 | MCPB 類型建議提供 |
| `repository` | 推薦 | `url` + `source` |

### mcp-publisher 命令

| 命令 | 說明 |
|------|------|
| `mcp-publisher init` | 生成 server.json 模板 |
| `mcp-publisher login github` | GitHub OAuth 認證（device code flow） |
| `mcp-publisher publish` | 發布到 Registry |
| `mcp-publisher logout` | 清除認證 |

### Registry API

| Endpoint | 說明 |
|----------|------|
| `GET /v0.1/servers?search={query}` | 搜尋 |
| `POST /v0.1/validate` | 驗證 server.json |

### Namespace 規則

| 認證方式 | Namespace |
|---------|-----------|
| GitHub | `io.github.{username}/*` |
| GitLab | `io.gitlab.{username}/*` |
| DNS | `{domain}/*` |

### 公開平台一覽

| 平台 | 類型 | 提交方式 | 審核 |
|------|------|----------|------|
| [MCP Registry](https://registry.modelcontextprotocol.io) | 官方 | `mcp-publisher publish` | 即時 |
| [Glama](https://glama.ai/mcp/servers) | 第三方 | agent-browser（`--session glama`） | 人工審核 |
| [awesome-mcp-servers](https://github.com/punkpeye/awesome-mcp-servers) | GitHub List | PR | 人工審核（需 Glama 連結） |
| [mcpservers.org](https://mcpservers.org) | 第三方 | Web 表單/PR | 視情況 |

### 常見問題

| 問題 | 解決方案 |
|------|----------|
| `mcp-publisher` 找不到 | `brew install mcp-publisher` |
| 401 token expired | 重新 `mcp-publisher login github` |
| 422 validation failed | 用 `/validate` endpoint 查看具體錯誤 |
| `description` 太長 | 精簡到 100 字元以內 |
| `name` 格式錯誤 | 必須是 `namespace/project` 格式 |
| 缺少 `transport` | 加入 `"transport": {"type": "stdio"}` |
| snake_case 欄位被拒 | 全部改 camelCase（`registryType`、`fileSha256`） |
| 版本衝突 | 不能覆蓋已發布版本，需要新版本號 |
| Glama 表單填值失敗 | 確認用 `agent-browser fill` 而非 `type`，fill 會清除再填入 |
| Glama 未登入 | 用 `agent-browser open "https://glama.ai/auth/sign-in" --session glama --headed` 讓使用者手動登入，session 會保存 |
| Glama session 過期 | 重新用 `--session glama --headed` 開啟登入頁面，手動登入即可 |
| awesome-mcp-servers 要求 Glama | 先完成 Glama 提交並通過審核 |
