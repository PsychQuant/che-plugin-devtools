---
name: mcp-deploy
description: |
  部署 MCP Server 專案：編譯 binary、更新版本號、打包 .mcpb bundle、建立 GitHub Release 並上傳 asset。須在 MCP 專案目錄中執行。
  與鄰近 skill 的分工：本 skill 發到自己的 GitHub Release（讓人裝得到）；要讓人「找得到」需另外用 mcp-publish 上架官方 Registry；發完若懷疑改動沒生效，用 mcp-sync 檢查三處 binary 一致性。
argument-hint: [version]
allowed-tools: Read, Write, Edit, Bash(swift:*), Bash(lipo:*), Bash(file:*), Bash(shasum:*), Bash(git:*), Bash(gh:*), Bash(zip:*), Bash(rm:*), Bash(cp:*), Bash(mkdir:*), Bash(ls:*), Bash(chmod:*), Bash(npm:*), Bash(python:*), Bash(pip:*), Bash(codesign:*), Grep, Glob, AskUserQuestion
disable-model-invocation: true
---

# MCP Deploy - 部署 MCP 專案

完整的 MCP 專案部署流程：編譯 → 打包 → 發布。

**建立新專案請用 `/harness-devtools:mcp-new-app`**

## 參數

- `$1` = 版本號（可選，如 `1.0.0`）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 stage-level todo list：

```
TaskCreate(name="detect_project", description="Phase 0: 確認 MCP 專案目錄 + 識別語言 + 讀當前版本 + 確認新版本號")
TaskCreate(name="compile_binary", description="Phase 1: 編譯（Swift/Python/TS），Swift 要做 universal binary + codesign")
TaskCreate(name="update_version_and_package", description="Phase 2: manifest.json + CHANGELOG + README + 打包 .mcpb + 驗證格式")
TaskCreate(name="publish_to_github", description="Phase 3: git commit/push + gh release create + curl upload assets（大 binary 必須 curl）")
TaskCreate(name="verify_binary_consistency", description="Phase 3.5 (Swift only)：hash 比對 + 架構確認")
TaskCreate(name="publish_plugin", description="Phase 4 (可選)：發布為 Claude Code Plugin，更新 marketplace.json + cache 同步")
TaskCreate(name="report_completion", description="Phase 5: 輸出版本資訊、Release URL、下一步提示")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

**為什麼強制**：mcp-deploy 有 5+ phases、每個 phase 有多個 step（總共 ~30 sub-steps），沒 task list 很容易漏步——特別是 Phase 3.5 binary consistency check 和 Phase 4 Phase 4 的 plugin sync（兩者都是 silent failure 的常見點）。

---

## Phase 0: 檢測專案

### Step 1: 確認目前在 MCP 專案目錄

檢查當前目錄是否為 MCP 專案：

```bash
pwd
ls -la
```

**必須存在的檔案/目錄**：
- `mcpb/` 目錄
- `mcpb/manifest.json`

如果不存在，提示使用者：
> 請先 `cd` 到 MCP 專案目錄，或使用 `/harness-devtools:mcp-new-app` 建立新專案

### Step 2: 識別語言類型

| 檔案 | 語言 |
|------|------|
| `Package.swift` | Swift |
| `pyproject.toml` 或 `setup.py` | Python |
| `package.json` + `tsconfig.json` | TypeScript |

### Step 3: 讀取當前版本

```bash
cat mcpb/manifest.json | grep '"version"'
```

### Step 4: 確認版本號

如果提供了 `$1`，使用該版本號。
否則使用 AskUserQuestion 詢問新版本號。

**版本號規則**（Semantic Versioning）：
- `MAJOR.MINOR.PATCH`
- 例：`1.0.0`、`0.8.1`、`2.1.0`

---

## Phase 1: 編譯

根據語言類型執行對應的編譯流程。

### 語言 A: Swift 編譯

#### A1: 清理舊 build（避免 Dropbox 衝突）

```bash
rm -rf .build 2>/dev/null || true
```

#### A2: 編譯兩種架構

```bash
swift build -c release --arch arm64
swift build -c release --arch x86_64
```

#### A3: 建立 Universal Binary

```bash
# 取得 binary 名稱（從 Package.swift）
BINARY_NAME=$(grep -A5 'executableTarget' Package.swift | grep 'name:' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

lipo -create \
    .build/arm64-apple-macosx/release/$BINARY_NAME \
    .build/x86_64-apple-macosx/release/$BINARY_NAME \
    -output mcpb/server/$BINARY_NAME

# 清除 Dropbox xattr 汙染（從 Dropbox 目錄 build 的 binary 帶 com.dropbox.attrs，macOS 會靜默 hang）
xattr -cr mcpb/server/$BINARY_NAME

# 重新簽名（lipo 會破壞原始 code signature，未簽名會被 macOS SIGKILL）
#
# 注意：這裡是 ad-hoc 簽名（`-` 表示無 identity），**僅適用 macOS ≤ 25 dev/test**。
# macOS 26 上 ad-hoc binary 無法觸發 Calendar / Reminders / AppleEvents 等 TCC dialog；
# 若 MCP 會打到隱私 API，必須走 Developer ID 簽章 + notarization。
#
# **若你的 MCP 走 macOS 26 production path**：
#   1. 確認專案已裝簽章 pipeline（`scripts/sign-and-notarize.sh` 存在?）
#   2. 沒裝 → 提示使用者跑 `/harness-devtools:mcp-sign-pipeline` 補裝（一次性 setup）
#   3. 已裝 → 改成呼叫 `./scripts/sign-and-notarize.sh mcpb/server/$BINARY_NAME`
#      (要求 `DEVELOPER_ID` + `NOTARY_PROFILE` env vars 已設)
#
# 偵測邏輯建議：
#   if [ -f "scripts/sign-and-notarize.sh" ] && [ -n "$DEVELOPER_ID" ]; then
#       ./scripts/sign-and-notarize.sh mcpb/server/$BINARY_NAME
#   else
#       codesign --force --sign - mcpb/server/$BINARY_NAME  # ad-hoc fallback
#       echo "⚠ ad-hoc signed; macOS 26 users will hit TCC blockage"
#       echo "  Install signing pipeline: /harness-devtools:mcp-sign-pipeline"
#   fi
codesign --force --sign - mcpb/server/$BINARY_NAME
```

#### A4: 驗證 Universal Binary

```bash
file mcpb/server/$BINARY_NAME
lipo -info mcpb/server/$BINARY_NAME
```

**預期輸出**：
```
mcpb/server/YourMCP: Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]
Architectures in the fat file: mcpb/server/YourMCP are: x86_64 arm64
```

---

### 語言 B: Python 打包

#### B1: 確認虛擬環境

```bash
python3 -m venv .venv 2>/dev/null || true
source .venv/bin/activate
pip install -e .
```

#### B2: 建立可執行腳本

```bash
# 建立 wrapper script
cat > mcpb/server/run.sh << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."
source .venv/bin/activate 2>/dev/null || true
python -m {project_name}
EOF
chmod +x mcpb/server/run.sh
```

**注意**：Python MCP 通常不打包成 binary，而是使用 wrapper script。

---

### 語言 C: TypeScript 編譯

#### C1: 安裝依賴

```bash
npm install
```

#### C2: 編譯

```bash
npm run build
```

#### C3: 建立可執行腳本

```bash
cat > mcpb/server/run.sh << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
node "$SCRIPT_DIR/../../dist/index.js"
EOF
chmod +x mcpb/server/run.sh
```

---

## Phase 2: 更新版本和打包

### Step 1: 更新 mcpb/manifest.json 版本

讀取並更新版本號：

```bash
# 使用 Edit 工具更新 "version": "x.x.x"
```

### Step 2: 更新 Server.swift / package.json 版本（如適用）

確保所有地方的版本號一致：
- `mcpb/manifest.json`
- Swift: `Server.swift` 中的 `version: "x.x.x"`
- Python: `pyproject.toml`
- TypeScript: `package.json`

### Step 3: 更新 CHANGELOG.md

在 CHANGELOG.md 頂部加入新版本：

```markdown
## [{version}] - {date}

### Added
- 新功能描述

### Changed
- 變更描述

### Fixed
- 修復描述
```

使用 AskUserQuestion 詢問這個版本的變更摘要。

### Step 4: 更新 README.md 版本歷史

**重要**：更新所有語言版本的 README（如 `README.md`、`README_zh-TW.md` 等）

需要更新的內容：
1. **Technical Details / 技術細節** 區塊的版本號
   - `Current Version: v{version}`
   - Framework 版本（如 MCP Swift SDK 版本）

2. **Version History / 版本歷史** 表格加入新版本：

```markdown
## Version History

| Version | Changes |
|---------|---------|
| v{version} | {change-summary} |
| ... | ... |
```

**檢查清單**：
- [ ] README.md 已更新
- [ ] README_zh-TW.md 已更新（如存在）
- [ ] 其他語言版本已更新（如存在）

如果 README.md 沒有 Version History 區塊，在 `## Installation` 之前加入。

### Step 4.5: 更新功能文檔（如有重要功能變更）

如果此版本新增了重要功能或 breaking change，除了 Version History 表格外，還需更新 README 中的功能說明。

使用 AskUserQuestion 確認：
> 這個版本有需要更新 README 功能文檔的重大變更嗎？
> - 是（新增工具參數 / response format 變更 / 新功能）
> - 否（只是 bug fix 或小改動，Version History 就夠了）

如果選「是」，根據 CHANGELOG 的變更內容，更新 README 中對應的段落：

| 變更類型 | Version History | Tool 描述 | 使用範例 | 新功能區塊 |
|---------|:-:|:-:|:-:|:-:|
| Bug fix (PATCH) | ✅ | ❌ | ❌ | ❌ |
| 小功能 (MINOR) | ✅ | ✅ | 可選 | ❌ |
| 大功能/Breaking (MAJOR) | ✅ | ✅ | ✅ | ✅ |

**具體更新項目**：
1. **Tool 描述表格**：更新受影響工具的描述（在「All Tools」區塊）
2. **使用範例**：新增展示新功能的範例
3. **新功能說明**：如有重大功能（如新的日期格式、新的參數），考慮新增獨立區塊說明

**提醒**：所有語言版本的 README 都要同步更新。

### Step 4.6: Tool-list ↔ README 一致性檢查（🔴 BLOCKING）

規則見 `rules/tool-readme-sync.md`。這步是上兩步 README 更新的**驗證**，不是重複。

```bash
# 1. 實際 tool count（從 Server source 數，或啟動後打 tools/list）
ACTUAL_COUNT=$(grep -oE 'name:\s*"[a-z_]+"' Sources/*/Server.swift 2>/dev/null | sort -u | wc -l | tr -d ' ')
# 若 Python / TS project，改用對應抓法

# 2. README 宣稱的 count
README_COUNT_EN=$(grep -oE '[0-9]+ (MCP )?[Tt]ools' README.md | head -1 | grep -oE '[0-9]+')
README_COUNT_ZH=$(grep -oE '[0-9]+ 個 MCP 工具' README_zh-TW.md 2>/dev/null | head -1 | grep -oE '[0-9]+')

echo "Actual: $ACTUAL_COUNT / README EN: $README_COUNT_EN / README zh-TW: $README_COUNT_ZH"

# 3. Comparison table 的數字
grep -E 'Tools Count|工具數量' README*.md
```

**BLOCKING**：如果 actual ≠ README（任何一種語言），**停止 deploy**，要求先更新 README。
使用者可明確覆蓋（「我知道這次 tool count 沒變」）才繼續。

補救清單（出現不一致時）：
- [ ] Features 列表的 "X MCP Tools"
- [ ] Available Tools (X Total) heading
- [ ] 分類工具表格每一列（新增的 tool）
- [ ] Comparison table 的 Tools Count 行
- [ ] 雙語 README 同步

### Step 4.7: GitHub repo About metadata audit（WARN，不 BLOCK）

規則見 `rules/tool-readme-sync.md` 的 GitHub Repo About Metadata 章節。
非 BLOCKING，但 minor / major bump 時強烈建議同步；patch 一般可略。

```bash
# 先確認 gh 已登入，且這個 repo 在 GitHub 上
gh auth status >/dev/null 2>&1 || { echo "⚠️ gh 未登入，跳過 metadata audit"; exit 0; }

REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -z "$REPO_SLUG" ] && { echo "⚠️ 非 GitHub repo 或無權限"; exit 0; }

# 1. Description 長度與時效
DESC=$(gh repo view --json description -q .description)
DESC_LEN=${#DESC}
echo "Description ($DESC_LEN chars): $DESC"
[ "$DESC_LEN" -lt 50 ] && echo "⚠️ Description 太短（<50 chars），建議補到 200-350 chars"

# 2. Description 是否反映目前 tool count
TOOL_COUNT=$(grep -oE 'name:\s*"[a-z_]+"' Sources/*/Server.swift 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "$TOOL_COUNT" -gt 0 ]; then
    echo "$DESC" | grep -qE "$TOOL_COUNT (MCP |tools|tool)" || echo "⚠️ Description 未反映 $TOOL_COUNT tools"
fi

# 3. Topics
TOPIC_COUNT=$(gh repo view --json repositoryTopics -q '.repositoryTopics | length')
echo "Topics: $TOPIC_COUNT 個"
[ "$TOPIC_COUNT" -lt 5 ] && echo "⚠️ Topics 太少（$TOPIC_COUNT < 5），search visibility 幾乎是零"
[ "$TOPIC_COUNT" -lt 15 ] && echo "💡 建議補到 15-20 個 topics"

# 4. Homepage URL
HOMEPAGE=$(gh repo view --json homepageUrl -q .homepageUrl)
[ -z "$HOMEPAGE" ] && echo "💡 建議設 Homepage = https://github.com/$REPO_SLUG/releases"
```

發現問題時，詢問使用者要不要順手 `gh repo edit` 更新：

```bash
AskUserQuestion "Repo metadata 和 README 不一致，要順便更新嗎？"
  - 是，現在更新（我提供新 description + topics 草案）
  - 否，deploy 後手動處理
  - Dry run 看草案再決定
```

AI 草擬 description + topics 時的模板見 `rules/tool-readme-sync.md`。

### Step 5: 清理舊的 mcpb 檔案

```bash
rm -f mcpb/*.mcpb 2>/dev/null || true
```

### Step 6: 打包 MCPB

```bash
# 取得專案名稱
PROJECT_NAME=$(cat mcpb/manifest.json | grep '"id"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | tr -d ' ')

# 打包到 mcpb/ 目錄內
cd mcpb && zip -r ${PROJECT_NAME}.mcpb . -x ".*" -x "*.mcpb" && cd ..
```

### Step 7: 驗證 MCPB 套件

```bash
ls -lh mcpb/*.mcpb
unzip -l mcpb/*.mcpb | head -20
```

**必須包含**：
- `manifest.json`
- `PRIVACY.md`
- `server/` 目錄（含 binary 或 script）
- `icon.png`（推薦）

### Step 8: 驗證 manifest.json 格式

**重要**：manifest.json 必須符合 MCPB 0.3 規範，否則 Claude Desktop 會顯示 "Invalid manifest" 錯誤。

**必要欄位**：
```json
{
  "manifest_version": "0.3",
  "name": "{project-name}",
  "version": "{version}",
  "description": "{description}",
  "author": {
    "name": "Che Cheng"
  },
  "server": {
    "type": "binary",
    "entry_point": "server/{BinaryName}",
    "mcp_config": {
      "command": "${__dirname}/server/{BinaryName}",
      "args": [],
      "env": {}
    }
  }
}
```

**常見錯誤**：
| 錯誤格式 | 正確格式 |
|---------|---------|
| `"author": "Name"` | `"author": { "name": "Name" }` |
| `"repository": "url"` | `"repository": { "type": "git", "url": "..." }` |
| `"entrypoint": {...}` | `"server": {...}` |
| 缺少 `manifest_version` | `"manifest_version": "0.3"` |
| `"path": "..."` | `"entry_point": "..."` |

**不支援的欄位**（會導致錯誤）：
- ~~`id`~~ - 使用 `name`
- ~~`platforms`~~ - 不支援
- ~~`capabilities`~~ - 不支援
- ~~`display_name`~~ - 不支援
- ~~`tools`~~ - 工具從 Server 動態取得

---

## Phase 3: 發布到 GitHub

### Step 1: Git 狀態檢查

```bash
git status
```

### Step 2: 提交變更

```bash
git add -A
git commit -m "v{version}: {change-summary}

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

### Step 3: 推送到 GitHub

```bash
git push origin main
```

**注意**：如果使用 Git LFS，會自動上傳大型檔案。

### Step 4: 建立 GitHub Release

使用 AskUserQuestion 詢問：
1. Release 標題（預設：`v{version}`）
2. Release 說明（可從 CHANGELOG.md 複製）

**Release Notes 模板**：

在 CHANGELOG 內容之前加入安裝指引（用 `---` 分隔）：

```markdown
## Install

### Claude Desktop (One-Click)
Download `{project-name}.mcpb` below and double-click to install.

### Claude Code (CLI)
\```bash
curl -L https://github.com/{owner}/{repo}/releases/download/v{version}/{BinaryName} -o ~/bin/{BinaryName}
chmod +x ~/bin/{BinaryName}
claude mcp add --scope user --transport stdio {project-name} -- ~/bin/{BinaryName}
\```

### MCP Registry
Published as `io.github.{owner}/{project-name}` on the [Official MCP Registry](https://registry.modelcontextprotocol.io).

---

{CHANGELOG 內容}
```

#### 方法 A: 使用 gh api + curl（推薦）

`gh release create` 上傳大型 binary 容易卡住或 timeout。改用分步驟方式更可靠：

```bash
# 準備變數
PROJECT_NAME=$(cat mcpb/manifest.json | grep '"name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | tr -d ' ')
BINARY_NAME=$(ls mcpb/server/ | grep -v '.sh' | grep -v '.gitkeep' | head -1)
MCPB_FILE=$(ls mcpb/*.mcpb | head -1)
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Step 1: 建立 Release（不帶 assets，秒完成）
RELEASE_ID=$(gh api repos/$OWNER_REPO/releases --method POST \
  -f tag_name="v{version}" \
  -f target_commitish="main" \
  -f name="v{version} - {title}" \
  -f body="{release-notes}" \
  -F draft=false \
  -F prerelease=false \
  --jq '.id')

echo "Release created: ID=$RELEASE_ID"

# Step 2: 用 curl 上傳 Binary（支援進度條，不會 timeout）
TOKEN=$(gh auth token)

curl -L -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "https://uploads.github.com/repos/$OWNER_REPO/releases/$RELEASE_ID/assets?name=$BINARY_NAME" \
  --data-binary "@mcpb/server/$BINARY_NAME" \
  --progress-bar -o /dev/null -w "Binary upload: HTTP %{http_code}, %{size_upload} bytes\n"

# Step 3: 用 curl 上傳 MCPB
MCPB_FILENAME=$(basename $MCPB_FILE)
curl -L -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "https://uploads.github.com/repos/$OWNER_REPO/releases/$RELEASE_ID/assets?name=$MCPB_FILENAME" \
  --data-binary "@$MCPB_FILE" \
  --progress-bar -o /dev/null -w "MCPB upload: HTTP %{http_code}, %{size_upload} bytes\n"

# Step 4: 驗證
gh release view v{version} --json assets --jq '.assets[] | "\(.name) (\(.size) bytes)"'
```

**為什麼不用 `gh release create` 帶 assets**：
- 大型 binary（>10MB）上傳容易卡住，無進度回報
- 上傳失敗時 release 會變成 untagged draft，需手動清理
- `curl` 有進度條且不會 timeout

#### 方法 B: 使用 gh release create（小型專案 Fallback）

只適合 binary < 10MB 的小型專案：

```bash
gh release create v{version} \
  --title "v{version} - {title}" \
  --notes "{release-notes}" \
  mcpb/server/$BINARY_NAME \
  $MCPB_FILE
```

**注意**：如果遇到 `workflow scope may be required` 錯誤，必須改用方法 A。

### Step 4.5: 更新 GitHub Repo About 描述

如果工具數量、主要功能、或支援範圍有變更，更新 repo 的 About 描述：

```bash
gh repo edit {owner}/{repo} --description "{updated-description}"
```

**常見需更新的情況**：
- 工具數量變更（如 20 → 24）
- 新增重要功能關鍵字
- 支援平台變更

用 `gh repo view --json description` 先確認現有描述，再決定是否需要更新。

### Step 5: 本地安裝（可選）

使用 AskUserQuestion 詢問：
> 是否要將 binary 安裝到 ~/bin？（如果使用 plugin wrapper 的自動下載機制，可以跳過）

如果選擇「是」：

```bash
cp mcpb/server/$BINARY_NAME ~/bin/
chmod +x ~/bin/$BINARY_NAME
xattr -cr ~/bin/$BINARY_NAME
codesign --force --sign - ~/bin/$BINARY_NAME
```

**驗證**：
```bash
file ~/bin/$BINARY_NAME
lipo -info ~/bin/$BINARY_NAME
codesign -dv ~/bin/$BINARY_NAME
```

如果選擇「否」，跳到 Phase 4。Binary 已在 `mcpb/server/` 和 GitHub Release 中，plugin wrapper 會在需要時自動下載。

---

## Phase 3.5: Binary 一致性驗證（Swift 專案限定，僅在 Step 5 選「是」時執行）

**注意**：此 Phase 只適用於 Swift 專案且已安裝到 ~/bin 的情況。

### Step 1: Hash 比對

```bash
echo "=== Binary Consistency Check ==="
shasum -a 256 mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
```

**預期**：兩個 hash 完全一致（因為剛從 mcpb/server 複製到 ~/bin）。

### Step 2: 架構確認

```bash
echo "=== mcpb/server ==="
lipo -info mcpb/server/$BINARY_NAME

echo "=== ~/bin ==="
lipo -info ~/bin/$BINARY_NAME
```

**預期**：兩者都顯示 `x86_64 arm64`（universal binary）。

### Step 3: 驗證結果

如果 hash 不一致，**停止並報錯**：

> ❌ Binary 一致性驗證失敗！mcpb/server 和 ~/bin 的 binary 不一致。
> 請使用 `/harness-devtools:mcp-sync` 修復。

---

## Phase 4: 發布為 Claude Code Plugin（可選）

使用 AskUserQuestion 詢問：
> 是否要同時發布為 Claude Code Plugin？

如果選擇「否」，跳到 Phase 5。

### Step 0: 動態解析環境變數

在開始之前，動態取得所有需要的路徑和名稱（避免硬編碼）：

```bash
# 1. 當前 MCP 專案的 GitHub owner/repo
MCP_REPO_FULL=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
MCP_OWNER="${MCP_REPO_FULL%%/*}"

# 2. 找到 plugins marketplace repo 的本地路徑
#    搜尋包含此 project 的 marketplace.json
PLUGINS_REPO=$(find ~/Developer ~/Library/CloudStorage -maxdepth 5 -name "marketplace.json" -path "*/.claude-plugin/*" -exec grep -l "{project-name}" {} \; 2>/dev/null | head -1 | sed 's|/.claude-plugin/marketplace.json||')

# 3. 衍生變數
MARKETPLACE_NAME=$(basename "$PLUGINS_REPO")
PLUGIN_DIR="$PLUGINS_REPO/plugins/{project-name}"
MARKETPLACE_JSON="$PLUGINS_REPO/.claude-plugin/marketplace.json"
```

**如果 `PLUGINS_REPO` 找不到**，使用 AskUserQuestion 詢問 plugins marketplace repo 的本地路徑。

### Step 1: 確認 Plugin 目錄存在

```bash
mkdir -p "$PLUGIN_DIR/.claude-plugin"
mkdir -p "$PLUGIN_DIR/bin"
```

### Step 2: 建立 .mcp.json

```bash
cat > "$PLUGIN_DIR/.mcp.json" << 'EOF'
{
  "{project-name}": {
    "type": "stdio",
    "command": "${CLAUDE_PLUGIN_ROOT}/bin/{project-name}-wrapper.sh",
    "description": "{description}"
  }
}
EOF
```

### Step 3: 建立 plugin.json

```bash
cat > "$PLUGIN_DIR/.claude-plugin/plugin.json" << 'EOF'
{
  "name": "{project-name}",
  "version": "{version}",
  "description": "{description}",
  "author": { "name": "Che Cheng" },
  "license": "MIT",
  "keywords": ["mcp", "{keywords}"]
}
EOF
```

### Step 4: 建立 wrapper script

Wrapper script 會自動從 GitHub Release 下載 binary（如果本機沒有）。

```bash
cat > "$PLUGIN_DIR/bin/{project-name}-wrapper.sh" << 'WRAPPER'
#!/bin/bash
# Auto-download wrapper for {BinaryName}
REPO="$MCP_REPO_FULL"
BINARY_NAME="{BinaryName}"
INSTALL_DIR="$HOME/bin"

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
    if [[ -z "$URL" ]]; then
        echo "ERROR: No download URL found. Install manually: https://github.com/$REPO/releases" >&2
        exit 1
    fi
    curl -sL "$URL" -o "$INSTALL_DIR/$BINARY_NAME" && chmod +x "$INSTALL_DIR/$BINARY_NAME" \
        || { echo "ERROR: Download failed." >&2; exit 1; }
    BINARY="$INSTALL_DIR/$BINARY_NAME"
    echo "Installed $BINARY_NAME to $INSTALL_DIR/" >&2
fi

exec "$BINARY" "$@"
WRAPPER
chmod +x "$PLUGIN_DIR/bin/{project-name}-wrapper.sh"
```

### Step 5: 建立 README.md

從專案的 README.md 複製並簡化，或使用 manifest.json 中的資訊生成：

```markdown
# {project-name}

**{description}**

## 安裝

### 1. 編譯 Binary

\```bash
cd /path/to/{project-name}
swift build -c release
cp .build/release/{BinaryName} ~/bin/
\```

### 2. 安裝 Plugin

\```bash
claude /plugin {project-name}
\```

## 版本

- **當前版本**: {version}
- **GitHub**: https://github.com/$MCP_REPO_FULL
```

### Step 6: 同步到已安裝的 plugins 目錄

```bash
INSTALLED_DIR="$HOME/.claude/plugins/marketplaces/$MARKETPLACE_NAME/plugins/{project-name}"
mkdir -p "$INSTALLED_DIR/.claude-plugin"
mkdir -p "$INSTALLED_DIR/bin"
cp "$PLUGIN_DIR/.mcp.json" "$INSTALLED_DIR/.mcp.json"
cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$INSTALLED_DIR/.claude-plugin/plugin.json"
cp "$PLUGIN_DIR/bin/{project-name}-wrapper.sh" "$INSTALLED_DIR/bin/"
```

### Step 7: 更新 marketplace.json（必要！）

**這一步經常被遺忘，會導致 `/plugin` 顯示舊版本號。**

讀取並更新 marketplace.json 中對應 plugin 的 `version` 和 `description`：

```bash
MARKETPLACE="$MARKETPLACE_JSON"
# 用 Edit 工具更新 marketplace.json 中 {project-name} 的 version 和 description
```

**必須更新的欄位**：
- `"version": "{version}"` — 新版本號
- `"description": "..."` — 如果 tool 數量或功能描述有變

### Step 8: 更新 installed_plugins.json

更新 `~/.claude/plugins/installed_plugins.json` 中對應 plugin 的記錄：

```bash
# 用 Edit 工具更新以下欄位：
# - "installPath": 指向新版本的 cache 目錄
# - "version": 新版本號
# - "lastUpdated": 當前時間 (ISO 8601)
# - "gitCommitSha": plugins marketplace repo 的最新 commit SHA
```

同時同步 cache 目錄：

```bash
CACHE_DIR="$HOME/.claude/plugins/cache/$MARKETPLACE_NAME/{project-name}/{version}"
mkdir -p "$CACHE_DIR/.claude-plugin" "$CACHE_DIR/bin"
cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$CACHE_DIR/.claude-plugin/"
cp "$PLUGIN_DIR/.mcp.json" "$CACHE_DIR/"
cp "$PLUGIN_DIR/bin/{project-name}-wrapper.sh" "$CACHE_DIR/bin/"
cp "$PLUGIN_DIR/README.md" "$CACHE_DIR/" 2>/dev/null || true
```

### Step 9: 提交 Plugin 變更

```bash
cd "$PLUGINS_REPO"
git add plugins/{project-name} .claude-plugin/marketplace.json
git commit -m "Update {project-name} plugin to v{version}

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
git push origin main
```

---

## Phase 5: 完成報告

```markdown
# MCP 部署完成

## 版本資訊
- 專案: {project-name}
- 版本: v{version}
- 語言: Swift / Python / TypeScript

## 發布的檔案
- Binary: `mcpb/server/{BinaryName}`
- MCPB: `{project-name}.mcpb`

## GitHub Release
- URL: https://github.com/$MCP_REPO_FULL/releases/tag/v{version}

## 本地安裝
- [ ] 已安裝到 ~/bin（如選擇安裝）
- [ ] 未安裝（plugin wrapper 會在需要時自動從 GitHub Release 下載）

## Claude Code Plugin（如有發布）
- Plugin 目錄: `$MARKETPLACE_NAME/plugins/{project-name}`
- 已同步到: `~/.claude/plugins/marketplaces/$MARKETPLACE_NAME/plugins/{project-name}`

## 下一步
- 測試: `claude mcp list` 確認 MCP 已連線
- 重啟 Claude Code 以載入新版本
```

---

## 快速參考

### 版本號建議

| 變更類型 | 版本變更 | 範例 |
|---------|---------|------|
| 新功能 | MINOR +1 | 1.0.0 → 1.1.0 |
| Bug 修復 | PATCH +1 | 1.0.0 → 1.0.1 |
| 破壞性變更 | MAJOR +1 | 1.0.0 → 2.0.0 |
| 文檔更新 | PATCH +1 | 1.0.0 → 1.0.1 |

### CHANGELOG 格式

```markdown
## [版本] - 日期

### Added（新功能）
### Changed（變更）
### Fixed（修復）
### Removed（移除）
```

### 常見問題

| 問題 | 解決方案 |
|------|----------|
| Dropbox 衝突導致 build 失敗 | `rm -rf .build` 後重新編譯 |
| lipo 失敗 | 確認兩種架構都編譯成功 |
| gh release create 卡住（大型 binary） | 改用方法 A（`gh api` + `curl`，見 Step 4） |
| gh release 失敗（workflow scope） | 改用方法 A（`gh api` + `curl`） |
| Release 變成 untagged draft | `gh release delete` 清理後重建 |
| Fork tag 衝突 | `git tag -d vX.Y.Z` 刪本地舊 tag，或 `git fetch fork --no-tags` |
| LFS lock 認證錯誤 | `GIT_LFS_SKIP_PUSH=1 git push` 跳過 LFS lock 驗證 |
| curl 上傳 binary 失敗 | 確認 `gh auth token` 有效，檔案路徑正確 |

### MCP Server 對應表

| MCP Server | Binary 名稱 |
|------------|------------|
| che-things-mcp | CheThingsMCP |
| che-ical-mcp | CheICalMCP |
| che-apple-mail-mcp | CheAppleMailMCP |
| che-word-mcp | CheWordMCP |
