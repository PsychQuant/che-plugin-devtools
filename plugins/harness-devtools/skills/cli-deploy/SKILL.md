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

Phase 3 Step 1.5（`scripts/release-tag.sh`）會讀的版本來源是封閉列舉：`Sources/*/Version.swift` 的 `static let|var version|current`（可帶 `: String`）、`Sources/*/Server.swift` 的 `version: "…"`（字串必須是整個引數；只計以「數字.數字」開頭的字串，`"v1.2.3"`、`"dev"` 不算來源。檔案裡每個這種 `version:` 都算，不是套件版本的（例如回應結構的欄位）會讓發版停下——它是檔案裡唯一的 `version:` 時回 20（不一致），與真正的版本並存時回 21（兩個不同的值）：改成具名常數，或移出 Server.swift）、`mcpb/manifest.json`、`package.json`、`pyproject.toml`（`[project].version`、`[tool.poetry].version`，或 hatch `path` 指到的檔案，照 hatch 自己的讀法）、`.claude-plugin/plugin.json` 或根目錄的 `plugin.json`。repo 裡有的都要改成同一個版本，漏改一個 Step 1.5 就會停止、不建 release（#42）。樹裡沒有任何版本字串（build 時才算）也可以，Step 1.5 會直接用這次的 `{version}`。Phase 3 Step 1 會把清單裡改過的檔案都 stage 進 release commit；改了 hatch `path` 指到的檔案時，那個檔案要自己 `git add`。

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

### Step 1: Commit，推送前檢查，然後 Push

**只 stage 本次 deploy 實際動過的檔案** — `git add -A` 會把使用者 working tree 裡無關的 modified files（例如 session-start hook 改的 `.claude/*`、`CLAUDE.md`）全部塞進 release commit，污染歷史。

commit 訊息、release 標題、release notes、repo 描述都是自由文字，內容常來自 CHANGELOG，可能有反引號、`$( )`、引號。**這些文字不寫進 bash 區塊**：shell 會執行雙引號裡的反引號與 `$( )`，引號會把字串截斷（#50）。做法是用 Write 工具把文字寫成檔案，區塊只從檔案讀。

這個目錄在 `.git` 底下。Claude Code 把 `.git` 列為受保護目錄（官方文件 permission-modes 的 Protected paths）：default、acceptEdits 模式每寫一個檔案都會問一次；auto 模式交給分類器；dontAsk 模式直接拒絕；`permissions.allow` 規則不能預先核准它。所以發版時最多會有 兩 次寫檔的確認（commit 訊息、release notes）。在 linked worktree 裡，git 目錄是主 repo 的 `.git/worktrees/<名稱>`，在工作目錄之外：設定擋了工作目錄以外的寫入（`permissions.blockWritesOutsideWorkingDirectories`）時，Write 每個模式都會被拒，提示按不了允許。Write 被拒絕時：**停下來告訴使用者**，請他在提示按允許；dontAsk 模式要改用會詢問的模式（default 或 acceptEdits）重跑。**不要改回把文字貼進 bash 區塊**，那正是 #50 修掉的缺陷；**也不要為了寫檔改用 bypassPermissions**，它會連這個要推送、要發版的流程的所有確認一起關掉。

先準備放檔案的目錄：

```bash
# Step 1: DEPLOY_TMP — 放在 git 目錄底下：不會被 stage，worktree 也適用。先清掉上一次留下的檔案
DEPLOY_TMP="$(git rev-parse --absolute-git-dir)/harness-deploy" || { echo "✗ Step 1: 不在 git repo 裡"; exit 1; }
mkdir -p "$DEPLOY_TMP" || exit 1
rm -f "$DEPLOY_TMP/commit-message.txt" "$DEPLOY_TMP/release-notes.md"
echo "→ Step 1: 用 Write 工具把文字檔寫到 $DEPLOY_TMP"
```

用 Write 工具把 commit 訊息寫到上面印出的目錄，檔名 `commit-message.txt`。第一行必須是 `v{version}: {change-summary}`。再執行：

```bash
VERSION='{version}'   # Phase 0 Step 4 決定的版本；代入前核對只含 0-9 A-Z a-z . + -
case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) echo "✗ Step 1: VERSION 未代入或不合法"; exit 1 ;; esac
# commit 訊息從檔案讀，不經過 shell 解析（#50）
MSG_FILE="$(git rev-parse --absolute-git-dir)/harness-deploy/commit-message.txt"
[ -s "$MSG_FILE" ] || { echo "✗ Step 1: 找不到 commit 訊息檔（或是空的）：${MSG_FILE} — 先用 Write 工具寫好"; exit 1; }
IFS= read -r SUBJECT < "$MSG_FILE"
case "$SUBJECT" in
  *'{'change-summary'}'*) echo "✗ Step 1: commit 訊息裡的摘要還沒代入"; exit 1 ;;
  "v$VERSION: "?*) ;;
  *) echo "✗ Step 1: commit 訊息的第一行要是「v$VERSION: 摘要」— 檔案可能是上一次留下的，或版本還沒代入"; exit 1 ;;
esac
# Phase 3 Step 1: stage Phase 1 改過的檔案——CHANGELOG、README，以及 Step 1.5 會讀的版本來源（封閉列舉，
# 與 Phase 1 Step 1 同一份），只限已追蹤且有修改的；untracked 的只收 CHANGELOG.md（Phase 1 Step 2 可能新建它）。
# 原本就存在、與這次無關的 untracked package.json 之類不會被收進來。不存在的路徑不會報錯
# （#42 verify 第 2–4 輪：原本只 stage Version.swift 與 CHANGELOG.md，其他來源的改動沒進 commit）。
# :(glob)：pathspec 的 * 預設會跨過 /，Sources/A/B/Version.swift 不是版本來源（#42 verify 第 8 輪）
{ git -c core.quotePath=false ls-files -m -- CHANGELOG.md README.md ':(glob)Sources/*/Version.swift' ':(glob)Sources/*/Server.swift' \
      mcpb/manifest.json package.json pyproject.toml .claude-plugin/plugin.json plugin.json
  git -c core.quotePath=false ls-files -o --exclude-standard -- CHANGELOG.md; } \
  | while IFS= read -r f; do git add -- "$f"; done

# 檢查 staging 內容，確認沒混進無關檔案
git diff --cached --stat

# --cleanup=whitespace：commit.cleanup 設成 strip 的人，訊息裡 # 開頭的行會被刪掉；這裡固定成只整理空白
git commit --cleanup=whitespace -F "$MSG_FILE" && rm -f "$MSG_FILE"
```

如果 `git diff --cached --stat` 顯示了非預期的檔案，停下來檢查 — 可能是 working tree 本來就髒。

**推送前檢查，然後推送。** release commit 推出去就收不回。Step 1.5 會停下的情況裡，推送前就看得出來的先在這裡檢查（#51）：版本來源彼此不一致或讀不出、同名 tag 已在別的 commit、沒有 upstream、追蹤的不是預設 branch、remote 不在 github.com。版本與 tag 用 `release-tag.sh --dry-run` 查，它不建立任何東西。全部通過才推送，推到這個 branch 追蹤的 upstream（branch 名稱要與 upstream 的名稱相同；這次會推的 commit 會先印出來）。

```bash
VERSION='{version}'   # Phase 0 Step 4 決定的版本；代入前核對只含 0-9 A-Z a-z . + -
case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) echo "✗ Step 1 推送: VERSION 未代入或不合法"; exit 1 ;; esac
# Step 1 推送: 推送前檢查（#51）——Step 1.5 會停下的情況裡，推送前就看得出來的先在這裡擋；這時 release commit 還沒離開本機
HELPER="${CLAUDE_PLUGIN_ROOT}/scripts/release-tag.sh"   # 用不帶 :? 的寫法：skill 載入時會被代換成 plugin 路徑（#39）
[ -f "$HELPER" ] || { echo "✗ Step 1 推送: 找不到 ${HELPER}（plugin 路徑沒有代換，或 cache 不完整）— 停止，不推送"; exit 1; }
BRANCH=$(git branch --show-current)
REMOTE=$(git config "branch.$BRANCH.remote" 2>/dev/null)
case "$REMOTE" in ''|.) echo "✗ Step 1 推送: $BRANCH 沒有指向 remote 的 upstream — 停止，不推送。這個 branch 第一次推送時用 git push -u <remote> ${BRANCH}（那一次不經過這裡的檢查），再從 Step 1.5 繼續"; exit 1 ;; esac
git remote | grep -qxF -- "$REMOTE" || { echo "✗ Step 1 推送: $BRANCH 的 upstream 不是這個 repo 設定過的 remote 名稱 — 停止，不推送"; exit 1; }
UPSTREAM_BRANCH=$(git config "branch.$BRANCH.merge" 2>/dev/null); UPSTREAM_BRANCH=${UPSTREAM_BRANCH#refs/heads/}
DEFAULT=$(git ls-remote --symref "$REMOTE" HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$(2)); print $(2)}')
[ -n "$DEFAULT" ] || { echo "✗ Step 1 推送: 讀不到 $REMOTE 的預設 branch（連線、權限或 remote 設定的問題，不是 branch 追蹤錯了）— 停止，不推送；連得上之後重跑這一步"; exit 1; }
[ "$UPSTREAM_BRANCH" = "$DEFAULT" ] || { echo "✗ Step 1 推送: ${BRANCH} 追蹤的是 $REMOTE 的 ${UPSTREAM_BRANCH:-?}，不是預設 branch（${DEFAULT}）— 合併到預設 branch 後再發版；停止，不推送"; exit 1; }
# 推送的是 HEAD:refs/heads/<upstream branch>。branch 名稱與 upstream 不同時（例如從 origin/main 開出來的 feature branch），這個 branch 上還沒推的 commit 會一起進預設 branch；以前寫死 origin 與 main 的那一行只推本機的 main
[ "$BRANCH" = "$UPSTREAM_BRANCH" ] || { echo "✗ Step 1 推送: 本機 branch ${BRANCH} 追蹤的是 $REMOTE 的 ${UPSTREAM_BRANCH}，名稱不同：這樣推送會把 ${BRANCH} 上還沒推的 commit 全部推進 ${UPSTREAM_BRANCH} — 先把要發的 commit 合併到本機的 ${UPSTREAM_BRANCH} 再發版；停止，不推送"; exit 1; }
OWNER_REPO=$(git config --get "remote.$REMOTE.url" | sed -E 's#\.git$##; s#^(https?://([^/@]*@)?|ssh://([^/@]*@)?|[^/@:]+@)github\.com[:/]+##')
printf '%s\n' "$OWNER_REPO" | grep -qxE '[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' \
  || { echo "✗ Step 1 推送: 從 remote $REMOTE 的網址推不出 github.com 的 owner/repo（ssh host alias、GitHub Enterprise 不支援）— 停止，不推送"; exit 1; }
# --dry-run：讀 HEAD 這個 commit 的版本、查同名 tag、查 remote 連不連得上，不建立任何東西。這些查詢的結束碼與真的打 tag 時相同；
# 建 tag 本身會不會成功（簽章）、remote 或本機的 hook 會不會拒絕，它預測不了，那些要到 Step 1.5 才看得到
LINE=$(bash "$HELPER" --dir . --commit HEAD --name-style v --remote "$REMOTE" --expect "$VERSION" --dry-run); RC=$?
echo "$LINE"
if [ "$RC" != 0 ]; then
    case "$RC" in
      10) echo "✗ Step 1 推送: v$VERSION 已在別的 commit 上：這個版本發過，或上次發版推了 tag 之後中止，也可能是本機留著一個沒推出去的同名 tag（git tag -l v$VERSION 看）。前者要先升版號、重新走 Phase 1；後者確認那個 tag 該不該留（刪 tag 由你決定）。停止，不推送" ;;
      20) echo "✗ Step 1 推送: 版本檔與 $VERSION 不一致（見上方各來源的值）— 回 Phase 1 Step 1 改成同一個版本，補一個 commit，再重跑這一步；改到會編進 binary 的檔案（例如 Version.swift）時，Phase 2 要重新 build。停止，不推送" ;;
      21) echo "✗ Step 1 推送: 有版本檔讀不出值（見上方的原因；讀 pyproject.toml 需要 python3 3.11 以上，或 tomli）— 修好環境後重跑這一步，不需要新的 commit。停止，不推送" ;;
      30) echo "✗ Step 1 推送: 查不到 $REMOTE 上的 tag、建 tag 需要的 git 身分（user.name、user.email）沒設，或 push URL 指向別的 repo（見上方的原因）— 修好連線或設定後重跑這一步，不需要新的 commit。停止，不推送" ;;
      *)  echo "✗ Step 1 推送: release-tag --dry-run rc=${RC} — 停止，不推送" ;;
    esac
    exit 1
fi
# 這次會推的 commit：最後一個是 release commit；前面還有的，是這個 branch 上本來就沒推的
echo "→ Step 1 推送: 這次會推到 $REMOTE 的 ${UPSTREAM_BRANCH} 的 commit："
git log --oneline "$REMOTE/$UPSTREAM_BRANCH..HEAD" 2>/dev/null | head -n 20
# --no-follow-tags：push.followTags 開著時，推 branch 會連帶推出本機的 annotated tag；這一步只推 release commit
git push --no-follow-tags "$REMOTE" "HEAD:refs/heads/$UPSTREAM_BRANCH" || { echo "✗ Step 1 推送: 推送失敗（$REMOTE 上有別人的新 commit 時，先確認要發的是哪一個 commit）— 停止"; exit 1; }
echo "→ Step 1 推送: release commit 已推到 $REMOTE 的 ${UPSTREAM_BRANCH}；Step 1.5 接著打 tag"
```

### Step 1.5: 在 release commit 打版號 tag（#42）

**先打 tag，再建 release。** 以前是讓 release API 帶 `target_commitish="main"`，由 GitHub 在建 release 那一刻的 remote main 上自動建 tag——那不保證是剛推的 commit，也沒有比對版號。現在由 `scripts/release-tag.sh`（四個發版 skill 共用）在推送後的 HEAD 打 `v{version}`：

- 版本從 commit 的內容讀，找得到的版本來源都要等於這次要發的 `{version}`（`--expect`）。
- 樹裡沒有版本、版本是 build 時才算出來的 repo（例如 safari-browser 由 `git describe` 算），就直接用 `{version}`。
- `Version.swift` 裡沒有 `static let|var version|current` 宣告時（例如只在 `run()` 裡 print 版本），不算版本來源；有宣告但值不是字串常值時停下（rc 21）。
- 打完確認 tag 在 release 要建的那個 GitHub repo 上，並且名稱就是 `v{version}`。
- **只在 remote 的預設 branch 上發版**：看的是目前 branch 追蹤的 upstream branch，不是本機 branch 名。feature branch 上打的 `v{version}` 會指向還沒合併的 commit，而且 tag 不會移動（#42 verify 第 2 輪）。
- owner/repo 從 upstream remote 的網址推出，只認 `github.com` 的網址；ssh host alias、GitHub Enterprise 會停下（不印網址，網址可能帶憑證）。

tag 名稱固定是 `v{version}`：安裝指令從 `releases/latest/download` 與 `releases/download/v{version}` 下載。Step 1 推送前若要向使用者確認，同一個確認要列出這個 tag。

代入 `{version}` 前先核對它只含 `0-9 A-Z a-z . + -`：值裡有單引號會先跳出字串，fence 裡的檢查就擋不到了（`git describe` 的備援值尤其要看，#45）。

```bash
VERSION='{version}'   # Phase 0 Step 4 決定的版本
case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) echo "✗ Step 1.5: VERSION 未代入或不合法"; exit 1 ;; esac
HELPER="${CLAUDE_PLUGIN_ROOT}/scripts/release-tag.sh"   # 用不帶 :? 的寫法：skill 載入時會被代換成 plugin 路徑（#39）
[ -f "$HELPER" ] || { echo "✗ Step 1.5: 找不到 ${HELPER}（plugin 路徑沒有代換，或 cache 不完整）— 停止，不建 release"; exit 1; }
BRANCH=$(git branch --show-current)
REMOTE=$(git config "branch.$BRANCH.remote" 2>/dev/null)
case "$REMOTE" in ''|.) echo "✗ Step 1.5: $BRANCH 沒有指向 remote 的 upstream — 先 git push -u <remote> $BRANCH 再重跑這一步"; exit 1 ;; esac
git remote | grep -qxF -- "$REMOTE" || { echo "✗ Step 1.5: $BRANCH 的 upstream 不是這個 repo 設定過的 remote 名稱 — 停止，不建 release"; exit 1; }
[ "$(git rev-parse '@{u}')" = "$(git rev-parse HEAD)" ] || { echo "✗ Step 1.5: HEAD 與 upstream 不同（Step 1 沒推成功，或 fetch 之後 upstream 已經前進）— 停止，不建 release"; exit 1; }
UPSTREAM_BRANCH=$(git config "branch.$BRANCH.merge" 2>/dev/null); UPSTREAM_BRANCH=${UPSTREAM_BRANCH#refs/heads/}
DEFAULT=$(git ls-remote --symref "$REMOTE" HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$(2)); print $(2)}')
if [ -z "$DEFAULT" ] || [ "$UPSTREAM_BRANCH" != "$DEFAULT" ]; then
    echo "✗ Step 1.5: ${BRANCH} 追蹤的是 $REMOTE 的 ${UPSTREAM_BRANCH:-?}，不是預設 branch（${DEFAULT:-讀不到}）— 合併到預設 branch 後再發版；停止，不建 release"; exit 1
fi
# @{u} 是本機記錄的位置；remote 上那個 branch 實際指向哪裡要問 remote（#42 verify 第 7 輪）
LIVE=$(git ls-remote "$REMOTE" "refs/heads/$UPSTREAM_BRANCH" 2>/dev/null | awk -F'\t' -v r="refs/heads/$UPSTREAM_BRANCH" '$(2)==r{print $(1)}')
if [ -z "$LIVE" ] || [ "$LIVE" != "$(git rev-parse HEAD)" ]; then
    echo "✗ Step 1.5: $REMOTE 上的 ${UPSTREAM_BRANCH} 目前是 ${LIVE:-讀不到}，不是 HEAD：有人在 release commit 之後推了 commit，或 remote 被改寫。不要 pull 之後重跑這一步——這一步打在 HEAD，tag 會落在別人的 commit；先確認要發的是哪一個 commit。停止，不建 release"; exit 1
fi
OWNER_REPO=$(git config --get "remote.$REMOTE.url" | sed -E 's#\.git$##; s#^(https?://([^/@]*@)?|ssh://([^/@]*@)?|[^/@:]+@)github\.com[:/]+##')
printf '%s\n' "$OWNER_REPO" | grep -qxE '[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' \
  || { echo "✗ Step 1.5: 從 remote $REMOTE 的網址推不出 github.com 的 owner/repo（ssh host alias、GitHub Enterprise 不支援）— 停止，不建 release"; exit 1; }
LINE=$(bash "$HELPER" --dir . --commit HEAD --name-style v --remote "$REMOTE" --expect "$VERSION"); RC=$?
echo "$LINE"
TAG=$(printf '%s\n' "$LINE" | sed -n 's/^RELEASE_TAG: [a-z-]* name=\([^ ]*\) .*/\1/p')
if [ "$RC" != 0 ] || [ "$TAG" != "v$VERSION" ]; then
    case "$RC" in
      10) echo "✗ Step 1.5: v$VERSION 已在別的 commit 上：這個版本發過，或上次發版推了 tag 之後中止。前者要先升版號；後者確認那個 tag 該不該留（刪 remote 上的 tag 由你決定）" ;;
      20) echo "✗ Step 1.5: 版本檔與 $VERSION 不一致（見上方各來源的值）— 回 Phase 1 Step 1 改成同一個版本" ;;
      21) echo "✗ Step 1.5: 有版本檔讀不出值（見上方的原因；讀 pyproject.toml 需要 python3 3.11 以上，或 tomli）— 修好後重跑這一步" ;;
      30) echo "✗ Step 1.5: tag 沒推成（見上方的原因：push URL 指向別的 repo 時先改 remote 設定，其他情況照上方的重跑指令）" ;;
      *)  echo "✗ Step 1.5: release-tag rc=${RC}、tag=${TAG:-?}（預期 v${VERSION}）" ;;
    esac
    echo "  停止，不建 release：沒有 tag 就建 release，GitHub 會在預設 branch 上自動建一個。"; exit 1
fi
# GitHub 上的那個 tag 必須就是剛推到 $REMOTE 的那一個（同一個 tag 物件），不只是同名（#42 verify 第 3 輪）
GH_TAG_OBJ=$(gh api "repos/$OWNER_REPO/git/ref/tags/$TAG" --jq .object.sha 2>/dev/null)
PUSHED_TAG_OBJ=$(git ls-remote "$REMOTE" "refs/tags/$TAG" 2>/dev/null | cut -f1)
if [ -z "$GH_TAG_OBJ" ] || [ "$GH_TAG_OBJ" != "$PUSHED_TAG_OBJ" ]; then
    echo "✗ Step 1.5: $OWNER_REPO 上的 ${TAG} 與推到 $REMOTE 的不是同一個 tag（或找不到）— tag 推到的 remote 與 release 的 repo 不是同一個？停止，不建 release"; exit 1
fi
echo "→ Step 1.5: $TAG 已在 ${OWNER_REPO}；Step 2 在同一個 repo 用這個 tag 建 release"
```

**沒有走到最後那行就不進 Step 2。**

### Step 2: 建立 GitHub Release

先用 Write 工具把 release notes 寫到 Step 1 印出的目錄，檔名 `release-notes.md`（模板在本節最後）。區塊從檔案讀，**不要把文字貼進區塊**（#50）。

重做 release 時，`release-notes.md` 是上一次失敗時留下的：先確認內容還是這一次要發的。

```bash
VERSION='{version}'   # 與 Step 1.5 同一個版本；代入前核對只含 0-9 A-Z a-z . + -
case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) echo "✗ VERSION 未代入或不合法"; exit 1 ;; esac
# 與 Step 1.5 同一個 repo：從推送的 remote 推導，不讓 gh 自己選（#42 verify：fork 工作流兩者可能不同）
OWNER_REPO=$(git config --get "remote.$(git config "branch.$(git branch --show-current).remote").url" | sed -E 's#\.git$##; s#^(https?://([^/@]*@)?|ssh://([^/@]*@)?|[^/@:]+@)github\.com[:/]+##')
printf '%s\n' "$OWNER_REPO" | grep -qxE '[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' || { echo "✗ 推不出 owner/repo — 先跑完 Step 1.5"; exit 1; }
gh api "repos/$OWNER_REPO/git/ref/tags/v$VERSION" --jq .object.sha >/dev/null || { echo "✗ $OWNER_REPO 上沒有 v$VERSION — 先跑完 Step 1.5"; exit 1; }
# release notes 從檔案讀，不經過 shell 解析（#50）；檔案由 Write 工具寫在 Step 1 印出的目錄
NOTES_FILE="$(git rev-parse --absolute-git-dir)/harness-deploy/release-notes.md"
[ -s "$NOTES_FILE" ] || { echo "✗ 找不到 release notes 檔（或是空的）：${NOTES_FILE} — 先用 Write 工具寫好"; exit 1; }
MATCH=$(grep -oF -e '{''release-notes''}' -e '{''CHANGELOG 內容''}' -e '{''binary''}' -e '{''owner''}' -e '{''repo''}' "$NOTES_FILE" | head -n 1)
[ -z "$MATCH" ] || { echo "✗ release notes 裡還有沒代入的 placeholder：${MATCH}（模板的字樣；changelog 真的要寫這個字時，改寫成別的寫法）"; exit 1; }

# BINARY_NAME 是 Phase 0 的變數，每個 Bash 呼叫是新的 shell：沒有值就不要建 release（建了也上傳不了）
[ -n "$BINARY_NAME" ] || { echo "✗ BINARY_NAME 沒有值（Phase 0 的變數；要在這個區塊裡先設）：先不建 release，文字檔保留"; exit 1; }

# 建立 Release：tag_name 用 Step 1.5 已推上去的 tag；tag 已存在時 GitHub 直接用它，不另外指定 commit（#42）
RELEASE_ID=$(gh api repos/$OWNER_REPO/releases --method POST \
  -f tag_name="v$VERSION" \
  -f name="v$VERSION" \
  -F body=@"$NOTES_FILE" \
  -F draft=false \
  -F prerelease=false \
  --jq '.id')
case "$RELEASE_ID" in ''|*[!0-9]*) echo "✗ release 沒建成（RELEASE_ID=${RELEASE_ID:-空}）：文字檔保留。$OWNER_REPO 上 v$VERSION 若已經有 release，停下來告訴使用者，不要自己刪或改它"; exit 1 ;; esac
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
gh release view "v$VERSION" --repo "$OWNER_REPO" --json assets --jq '.assets[] | "\(.name) (\(.size) bytes)"'
# binary 在 release 上才刪文字檔（不留給下一次發版）。curl 沒有 --fail，HTTP 錯誤時它的結束碼仍是 0，所以要看 release 上實際有什麼
ASSETS=$(gh release view "v$VERSION" --repo "$OWNER_REPO" --json assets --jq '.assets[].name') || { echo "✗ 查不到 release 的 asset 清單：文字檔保留"; exit 1; }
printf '%s\n' "$ASSETS" | grep -qxF -- "$BINARY_NAME" || { echo "✗ release 上沒有 ${BINARY_NAME}：文字檔保留。release 已經建好，不要重跑整個區塊（會停在建立 release 那一步）；把這件事告訴使用者，由他決定怎麼補"; exit 1; }
rm -f "$NOTES_FILE"
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
- **Tag**: v{version}（Step 1.5 的 `RELEASE_TAG:` 那一行：tagged 或 exists、commit）
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
