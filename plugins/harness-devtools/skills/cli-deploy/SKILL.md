---
name: cli-deploy
description: |
  發布 Swift CLI 工具：先更新版本號與 CHANGELOG、再編譯 universal binary（arm64 + x86_64）、建立 GitHub Release 上傳 asset、安裝到 ~/bin。須在 Swift CLI 專案目錄中執行。
  Use when: CLI 改完要出新版；「發布 CLI」「deploy 這個工具」「出 v1.2.0」「release」。
  防止的失敗：先 build 再改版本號，導致 binary 內嵌舊版號（--version 說謊）；Release 只附單一架構 binary，Intel 或 Apple Silicon 其中一邊裝不起來；忘了同步 CHANGELOG，marketplace 顯示過時資訊。
argument-hint: [version]
allowed-tools: Read, Write, Edit, Bash(swift:*), Bash(lipo:*), Bash(file:*), Bash(shasum:*), Bash(git:*), Bash(gh:*), Bash(rm:*), Bash(cp:*), Bash(mkdir:*), Bash(ls:*), Bash(chmod:*), Bash(codesign:*), Bash(xattr:*), Grep, Glob, AskUserQuestion
disable-model-invocation: true
---

# CLI Deploy — 部署 Swift CLI 工具

完整的 CLI 工具部署流程：版本更新 → 編譯 universal binary → GitHub Release。

**重要**：必須先 bump version 再 build，否則 binary 內嵌的版本號會是舊的。

## 參數

- `$1` = 版本號（可選，如 `1.0.0`）

---

## Phase 0: 檢測專案

### Step 1: 確認 Swift CLI 專案

```bash
pwd
ls Package.swift
```

**必須存在**：`Package.swift` 且包含 `executableTarget`

### Step 2: 取得 Binary 名稱

**重要**：Binary 名稱由 `products:` 區塊的 `.executable(name: ...)` 決定，**不是** `targets:` 區塊的 `executableTarget.name`。兩者可以不同（例如 `.executable(name: "gfh", targets: ["gfs"])` — binary 是 `gfh`，target 資料夾是 `gfs`）。抓錯的話後面 `lipo` / `curl` 會找不到檔案。

```bash
# 優先從 products 區塊抓 .executable(name: "X")
BINARY_NAME=$(grep -E '\.executable\(name:' Package.swift | head -1 | sed 's/.*name: *"\([^"]*\)".*/\1/')

# Fallback：只有當沒有 products 區塊時才用 executableTarget 名稱
if [ -z "$BINARY_NAME" ]; then
    BINARY_NAME=$(grep -A2 'executableTarget' Package.swift | grep 'name:' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
fi

echo "Binary: $BINARY_NAME"
```

若 `BINARY_NAME` 為空，**停下來**請使用者確認 — 繼續往下做會寫壞路徑。

### Step 3: 取得當前版本

搜尋版本號來源（依優先順序）：

1. `Sources/*/Version.swift` — 找 `static let current = "x.x.x"` 或類似
2. 最新 git tag：`git describe --tags --abbrev=0 2>/dev/null`
3. 如果都沒有，預設 `0.1.0`

### Step 4: 確認新版本號

如果提供了 `$1`，使用該版本。否則用 AskUserQuestion 詢問，預設 patch bump。

---

## Phase 1: 更新版本與文檔（先於 build！）

### Step 1: 更新版本號

找到版本號所在的檔案並更新：

- `Sources/*/Version.swift` — 更新版本字串
- 其他可能的位置由 Step 0.3 決定

### Step 2: 更新 CHANGELOG.md

**先檢查是否已有 `[Unreleased]` 區塊**：

- **若有** `[Unreleased]` 區塊 → 把標題改成 `[{version}] - {date}`（promote 既有內容，避免重複）：
  ```
  ## [Unreleased]        →   ## [{version}] - {date}
  ```
- **若無** `[Unreleased]` 區塊 → 在 CHANGELOG.md 頂部新增：
  ```markdown
  ## [{version}] - {date}

  ### Added
  - ...

  ### Changed
  - ...

  ### Fixed
  - ...
  ```

在沒有 `[Unreleased]` 的情況下，用 AskUserQuestion 詢問變更摘要。

### Step 3: 更新 README.md（如適用）

如果 README.md 有 Version History 區塊，加入新版本。

**CLI 特化檢查項目**（逐一核對；任何有改動的都必須連動 README）：

| 改動 | README 需要同步的位置 |
|------|--------------------|
| 新增 / 移除 subcommand | Usage 表格、Examples section |
| 改 flag / 預設值翻轉 | Flag 說明表、所有範例命令 |
| 位置參數順序變 | 所有範例命令 |
| 新增外部依賴（如 playwright） | Prerequisites / Installation |
| 新增輸出格式 / format matrix 變動 | Format matrix / Supported Formats 表 |

### Step 3.5: CLI surface ↔ README 一致性檢查（🔴 BLOCKING）

規則見 `rules/tool-readme-sync.md`。

```bash
# 先 build，能跑 --help 再檢查
swift build -c release 2>/dev/null || cargo build --release 2>/dev/null || true

# 1. 抓實際 subcommand 集合
ACTUAL=$(./.build/release/$BINARY_NAME --help 2>&1 | awk '/SUBCOMMANDS|Subcommands|COMMANDS/{flag=1;next} /^$/{flag=0} flag && /^  [a-z]/{print $1}' | sort -u)

# 2. 抓 README 文件化的 subcommand（基於 $BINARY_NAME xxx 這種 pattern）
DOCUMENTED=$(grep -oE "$BINARY_NAME [a-z-]+" README.md | awk '{print $2}' | sort -u)

# 3. diff
diff <(echo "$ACTUAL") <(echo "$DOCUMENTED") && echo "✅ README subcommand 對齊" || echo "⚠️ README 與 --help 不一致"
```

**BLOCKING**：不一致就停止 deploy，要求先更新 README（或使用者明確覆蓋）。

### Step 3.6: GitHub repo About metadata audit（WARN，不 BLOCK）

規則見 `rules/tool-readme-sync.md` 的 GitHub Repo About Metadata 章節。

```bash
gh auth status >/dev/null 2>&1 || { echo "⚠️ gh 未登入，跳過"; exit 0; }

REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -z "$REPO_SLUG" ] && { echo "⚠️ 非 GitHub repo 或無權限"; exit 0; }

# 1. Description 長度
DESC=$(gh repo view --json description -q .description)
DESC_LEN=${#DESC}
echo "Description ($DESC_LEN chars): $DESC"
[ "$DESC_LEN" -lt 50 ] && echo "⚠️ Description 太短（<50 chars）"

# 2. Description 是否提及主要 subcommand
MAJOR_SUBCMDS=$(./.build/release/$BINARY_NAME --help 2>&1 | awk '/SUBCOMMANDS|Subcommands|COMMANDS/{f=1;next} /^$/{f=0} f && /^  [a-z]/{print $1}' | head -3)
for s in $MAJOR_SUBCMDS; do
    echo "$DESC" | grep -qi "$s" || echo "💡 Description 未提到主要 subcommand: $s"
done

# 3. Topics
TOPIC_COUNT=$(gh repo view --json repositoryTopics -q '.repositoryTopics | length')
echo "Topics: $TOPIC_COUNT 個"
[ "$TOPIC_COUNT" -lt 5 ] && echo "⚠️ Topics 太少（$TOPIC_COUNT < 5）"
[ "$TOPIC_COUNT" -lt 15 ] && echo "💡 建議 15-20 個 topics（CLI 必備：cli, command-line-tool, swift/rust/go, macos/linux）"

# 4. Homepage
HOMEPAGE=$(gh repo view --json homepageUrl -q .homepageUrl)
[ -z "$HOMEPAGE" ] && echo "💡 建議設 Homepage = https://github.com/$REPO_SLUG/releases"
```

發現問題時用 AskUserQuestion 問要不要順手 `gh repo edit`。

---

## Phase 2: 編譯 Universal Binary

### Step 1: 清理舊 build

```bash
rm -rf .build 2>/dev/null || true
```

### Step 2: 編譯兩種架構

```bash
swift build -c release --arch arm64
swift build -c release --arch x86_64
```

### Step 3: 建立 Universal Binary

```bash
mkdir -p .release
lipo -create \
    .build/arm64-apple-macosx/release/$BINARY_NAME \
    .build/x86_64-apple-macosx/release/$BINARY_NAME \
    -output .release/$BINARY_NAME

# 清除 xattr 汙染（Dropbox 目錄 build 的 binary 帶 com.dropbox.attrs）
xattr -cr .release/$BINARY_NAME

# 重新簽名（lipo 破壞原始 code signature）
#
# 注意：這是 ad-hoc 簽名（`-` = 無 identity），**僅 macOS ≤ 25 dev path**。
# macOS 26 上 ad-hoc binary 無法觸發 TCC dialog；對外分發需走 Developer ID + notarization。
#
# **若 CLI 走 macOS 26 production path**：
#   1. 確認專案已裝簽章 pipeline（`scripts/sign-and-notarize.sh` 存在?）
#   2. 沒裝 → 提示使用者跑 `/harness-devtools:mcp-sign-pipeline`（CLI 同樣適用）
#   3. 已裝 + `DEVELOPER_ID` 已 export → 改呼叫 `./scripts/sign-and-notarize.sh .release/$BINARY_NAME`
#
# 偵測邏輯建議：
#   if [ -f "scripts/sign-and-notarize.sh" ] && [ -n "$DEVELOPER_ID" ]; then
#       ./scripts/sign-and-notarize.sh .release/$BINARY_NAME
#   else
#       codesign --force --sign - .release/$BINARY_NAME  # ad-hoc fallback
#       echo "⚠ ad-hoc signed; macOS 26 users may see Gatekeeper warning"
#       echo "  Install signing pipeline: /harness-devtools:mcp-sign-pipeline"
#   fi
codesign --force --sign - .release/$BINARY_NAME
```

### Step 4: 驗證 binary + 內嵌版本

```bash
file .release/$BINARY_NAME
lipo -info .release/$BINARY_NAME
.release/$BINARY_NAME version 2>/dev/null || .release/$BINARY_NAME --version 2>/dev/null
```

**預期**：
- `Mach-O universal binary with 2 architectures: [x86_64] [arm64]`
- 版本號顯示 `{version}`（如果顯示舊版本，表示 Phase 1 的 version bump 沒生效，**停下來檢查**）

---

## Phase 3: 發布到 GitHub

### Step 1: Commit + Push

**只 stage 本次 deploy 實際動過的檔案** — `git add -A` 會把使用者 working tree 裡無關的 modified files（例如 session-start hook 改的 `.claude/*`、`CLAUDE.md`）全部塞進 release commit，污染歷史。

```bash
# 只 stage Phase 1 改過的檔案
git add Sources/*/Version.swift CHANGELOG.md
[ -f README.md ] && git diff --cached --quiet README.md 2>/dev/null || git add README.md 2>/dev/null || true

# 檢查 staging 內容，確認沒混進無關檔案
git diff --cached --stat

git commit -m "v{version}: {change-summary}"
git push origin main
```

如果 `git diff --cached --stat` 顯示了非預期的檔案，停下來檢查 — 可能是 working tree 本來就髒。

### Step 2: 建立 GitHub Release

```bash
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# 建立 Release
RELEASE_ID=$(gh api repos/$OWNER_REPO/releases --method POST \
  -f tag_name="v{version}" \
  -f target_commitish="main" \
  -f name="v{version}" \
  -f body="{release-notes}" \
  -F draft=false \
  -F prerelease=false \
  --jq '.id')

echo "Release created: ID=$RELEASE_ID"

# 上傳 Binary（用 curl，支援進度條）
TOKEN=$(gh auth token)
curl -L -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "https://uploads.github.com/repos/$OWNER_REPO/releases/$RELEASE_ID/assets?name=$BINARY_NAME" \
  --data-binary "@.release/$BINARY_NAME" \
  --progress-bar -o /dev/null -w "Upload: HTTP %{http_code}, %{size_upload} bytes\n"

# 驗證
gh release view v{version} --json assets --jq '.assets[] | "\(.name) (\(.size) bytes)"'
```

Release Notes 模板：

```markdown
## Install

\```bash
curl -fsSL https://github.com/{owner}/{repo}/releases/latest/download/{binary} -o ~/bin/{binary} && chmod +x ~/bin/{binary}
\```

---

{CHANGELOG 內容}
```

### Step 3: 安裝到本地

```bash
cp .release/$BINARY_NAME ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
```

驗證：

```bash
~/bin/$BINARY_NAME version 2>/dev/null || ~/bin/$BINARY_NAME --version 2>/dev/null
```

### Step 4: 清理

```bash
rm -rf .release
```

---

## Phase 4: 完成報告

```markdown
# CLI Deploy 完成

- **專案**: {project-name}
- **版本**: v{version}
- **Binary**: {binary-name} (universal: arm64 + x86_64)
- **Release**: https://github.com/{owner}/{repo}/releases/tag/v{version}
- **本地**: ~/bin/{binary-name}

安裝指令（其他使用者）：
curl -fsSL https://github.com/{owner}/{repo}/releases/latest/download/{binary} -o ~/bin/{binary} && chmod +x ~/bin/{binary}
```

---

## 快速參考

### 版本號建議

| 變更類型 | 版本變更 | 範例 |
|---------|---------|------|
| 新功能 | MINOR +1 | 1.0.0 → 1.1.0 |
| Bug 修復 | PATCH +1 | 1.0.0 → 1.0.1 |
| 破壞性變更 | MAJOR +1 | 1.0.0 → 2.0.0 |

### 常見問題

| 問題 | 解決方案 |
|------|----------|
| Dropbox 衝突導致 build 失敗 | `rm -rf .build` 後重新編譯 |
| lipo 失敗 | 確認兩種架構都編譯成功 |
| gh release create 卡住 | 用 `gh api` + `curl` 分步驟上傳 |
| codesign 失敗 | `codesign --force --sign -` 用 ad-hoc 簽名 |
| binary 版本號是舊的 | 確認 Phase 1 已更新 Version.swift 再 build（不能先 build 再 bump） |
