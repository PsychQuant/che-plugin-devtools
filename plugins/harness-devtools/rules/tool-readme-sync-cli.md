# CLI Command Surface ↔ README 同步紀律

當 CLI 工具的 subcommand / flag / 參數語義變動時，**必須**在同一個 commit（或同一個 release 週期內）更新 README。

## 為什麼

CLI 的 README 通常包含三種資訊，都容易過時：

| 區塊 | 容易過時原因 |
|------|------------|
| Usage / Subcommand 列表 | 新增子命令、或把舊命令 deprecate 了 |
| Flag / 參數說明 | flag 改名、預設值翻轉、required → optional |
| 範例命令（複製貼上用的） | 語法變動後範例直接失效 |

使用者習慣複製範例當入門。範例失效 → 使用者第一次跑就報錯 → 信心損失。

## 觸發條件

1. **新增子命令** — 新的 `mytool xxx` 出現
2. **移除 / deprecate 子命令** — BREAKING，CHANGELOG 也要寫
3. **重命名子命令** — 舊名別名是否保留？README 要說清楚
4. **新增 / 移除 flag** — 每個 flag 都是 public contract
5. **Flag 預設值翻轉** — 例如 `--format` 從 `json` 翻成 `text`（隱性 BREAKING）
6. **位置參數順序 / 數量改變** — 影響所有 shell 呼叫
7. **外部依賴改變** — 如需要 `playwright` CLI、`ffmpeg` 等

純實作重構（internal function 改名、效能優化但 flag 不變）不需改 README。

## 必要的 README 改動範圍

| 改動 | README 連動 |
|------|------------|
| 加 subcommand | Usage 表格 + Examples section |
| 改 flag | Flag 說明表 + 所有用到該 flag 的範例 |
| 預設值翻轉 | 在「Migration / Breaking Changes」註記，避免使用者踩坑 |
| 新增依賴（playwright 等） | Prerequisites / Installation 區塊 |
| 新增輸出格式（`--to pdf`） | Format matrix 或「Supported Formats」表 |

## 範例 Walk-through（參考 macdoc）

macdoc CLI 有 `convert --to <fmt>` 這個 single entry point，對應一張 16-row format matrix。每新增一條轉換路由：

```swift
// MacDoc+Convert.swift 的 switch
case ("tex", .docx): try convertTexToDocx(inputURL)   // ← 新加的
```

同一個 PR 必須：

1. 更新 `convert-entry-point.md` 規則的 16 → 17 條路由列表
2. 更新 README 的 Format matrix 加上 `tex → docx` 那行
3. 更新 `textutil-compat.md` 的對照表（如果新 format 有 textutil 對應）
4. CHANGELOG 加 entry

**檢查方式**：grep README 中的 format 清單對照 `switch` 實作，應該一一對應。

## Deploy 前的自我檢查

`cli-deploy` skill 跑完**前**做這個檢查：

```bash
# 抓 CLI 實際支援的 subcommand 清單
ACTUAL=$(./mytool --help 2>&1 | grep -oE '^  [a-z-]+' | sort -u)

# 抓 README 裡文件化的 subcommand
DOCUMENTED=$(grep -oE 'mytool [a-z-]+' README.md | awk '{print $2}' | sort -u)

# diff
diff <(echo "$ACTUAL") <(echo "$DOCUMENTED") || echo "⚠️ README 與 --help 不一致"
```

Flag 層級：

```bash
./mytool subcmd --help 2>&1 | grep -oE '^  --[a-z-]+' | while read flag; do
  grep -q "\`$flag\`" README.md || echo "⚠️ Flag $flag 未在 README 出現"
done
```

## 當 README 已累積落差時的補救

1. **跑 `--help` 做 ground truth dump**，逐一 diff README
2. 檢查 Examples section 的每一條命令，實際執行看看是否還能跑
3. 若 repo 有 E2E test，檢查 test 裡的指令與 README 是否一致（通常 test 才是最新）
4. 雙語 README 記得同步

## GitHub Repo About Metadata（和 README 同等級的使用者第一印象）

README 是 repo 內部文件；**GitHub repo 首頁右側的 About 面板** 是外部的「名片」。Search engine、Topics 瀏覽頁、marketplace 聚合器都讀這塊，不讀 README。

CLI surface 變動時，這三項也要檢查：

| 欄位 | 位置 | CLI 特有的同步時機 |
|------|------|-----------------|
| **Description**（~350 字短介紹）| `gh repo view --json description` | 新增 subcommand、新增主要 flag、新增支援格式 / 平台 |
| **Topics**（最多 20 個標籤）| `gh repo view --json repositoryTopics` | 加了新功能領域（例如原本 PDF 轉檔 → 加了 OCR 能力） |
| **Homepage URL** | `gh repo view --json homepageUrl` | 通常指 `releases` 頁；改過 binary 發布位置時才動 |

### Description 的三層結構模板

```
[What] {CLI tool for X} —
[Differentiator] {native Swift, no Python/Node, single binary} —
[Features] {Subcmd A, Subcmd B, Subcmd C} —
[Use case] {Optimized for Y workflow}
```

範例（假設 macdoc CLI）：

> macOS-native document conversion CLI — Swift-only, no Pandoc. 16 conversion routes (Word, HTML, Markdown, PDF, TeX, SRT, BibLaTeX). Textutil-compatible syntax, streaming converters, OCR pipeline with MLX + Ollama backends. Optimized for academic and thesis document workflows.

### 建議 Topics 數量

- **目標：15-20 個**（GitHub 上限 20）
- 少於 5 個 = search visibility 等於零
- `null` / 空陣列 = 完全沒出現在 `topic:xxx` 搜尋頁

### 必備 Topic 類別（CLI 特化）

| 類別 | Topic 範例 |
|------|----------|
| 語言 | `swift`, `rust`, `go` |
| 類型 | `cli`, `command-line`, `command-line-tool`, `terminal` |
| 平台 | `macos`, `linux`, `cross-platform`, `native` |
| 發布 | `single-binary`, `homebrew`, `github-releases` |
| 功能域 | 依 CLI 主要處理對象命名（`pdf`, `markdown`, `ocr`, `video`…） |
| 用途 | `automation`, `developer-tools`, `productivity` |
| 生態相容 | `textutil`, `pandoc-alternative`, `jq-like` 等（方便比較搜尋） |

### `gh repo edit` 參考指令

```bash
# 一次更新 description + homepage
gh repo edit {OWNER}/{REPO} \
  --description "..." \
  --homepage "https://github.com/{OWNER}/{REPO}/releases"

# 加 topics
gh repo edit {OWNER}/{REPO} \
  --add-topic cli \
  --add-topic command-line-tool \
  --add-topic swift \
  --add-topic macos

# 查核目前狀態
gh repo view {OWNER}/{REPO} --json description,homepageUrl,repositoryTopics
```

### Deploy 前的審計

```bash
# description 是否反映目前主要能力
CURRENT_DESC=$(gh repo view --json description -q .description)
MAJOR_SUBCMDS=$(./$BINARY --help | awk '/SUBCOMMANDS/{f=1;next} f&&/^  [a-z]/{print $1}' | head -5 | xargs)
for s in $MAJOR_SUBCMDS; do
    echo "$CURRENT_DESC" | grep -qi "$s" || echo "⚠️ Description 未提到主要 subcommand: $s"
done

# topics 數量
TOPIC_COUNT=$(gh repo view --json repositoryTopics -q '.repositoryTopics | length')
[ "$TOPIC_COUNT" -ge 5 ] || echo "⚠️ Topics 只有 $TOPIC_COUNT 個（建議 15-20）"
```

## 例外

- 純 bug fix（flag / subcommand / 預設值都沒動）→ CHANGELOG 即可，README / Description / Topics 皆不用
- 未上架 release 的 development build → 都可以延後；但 tag 前必須齊

## 和其他 skill 的關係

- `cli-deploy` Step 2.6 檢查 README/--help 一致性，不一致時 **BLOCK** 發布
- `cli-upgrade` 建議加新 flag 時，會提醒「README `Flags` 表格要加 1 行」
- `cli-new-app` scaffold 直接產出含 Usage + Examples + Flags 三區塊的 README 骨架

## TL;DR

**改了 `--help` 輸出，就改 README；`--help` 和 README 不一致就不要發 release。**
