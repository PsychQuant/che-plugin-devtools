---
name: plugin-deploy
description: |
  發布 plugin 到自己的 marketplace（pre-flight check + version bump + commit + push + sync）。
  完整的發布流程，確保 plugin 品質和 marketplace 同步。
  當用戶提到「發布 plugin」「deploy plugin」「上架」「release plugin」時使用。
argument-hint: "[plugin-name]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(claude:*)
  - AskUserQuestion
---

# Plugin Deploy — 發布到自己的 Marketplace

完整的 plugin 發布流程：品質檢查 → 版本號 → marketplace 同步 → commit → push → reload。

## Execution Steps

### Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 stage-level todo list：

```
TaskCreate(name="identify_plugin", description="Step 1: 從 $ARGUMENTS 找 plugin 目錄")
TaskCreate(name="preflight_checks", description="Step 2: 跑必要 + 建議項目檢查")
TaskCreate(name="mcp_binary_check", description="Step 2.5: 若是 MCP plugin，驗證 binary 在 GitHub Release 裡（不在則 BLOCK）")
TaskCreate(name="readme_freshness_gate", description="Step 2.6: README 是否跟上 plugin.json 版本 / 新工具；minor/major bump stale → BLOCK")
TaskCreate(name="present_checklist", description="Step 3: 顯示結果，讓使用者決定繼續或修問題")
TaskCreate(name="fix_issues", description="Step 4: 若使用者選修問題，處理 README/LICENSE/hooks 等")
TaskCreate(name="version_bump", description="Step 5: patch/minor/major bump plugin.json + marketplace.json")
TaskCreate(name="update_marketplace_json", description="Step 6: 同步 marketplace.json 確認 version / description")
TaskCreate(name="commit_and_push", description="Step 7: git add + commit + push")
TaskCreate(name="sync_and_reload", description="Step 8: claude plugin marketplace update + plugin update")
TaskCreate(name="verify", description="Step 9: claude plugin list 驗證版本")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

**為什麼強制**：plugin-deploy 有 10 個步驟，其中兩個是容易被跳過的關卡——Step 2.5（MCP binary 沒發布會讓新使用者下載失敗）和 Step 2.6（README 沒同步會讓使用者看到舊文件 + 新版本號的矛盾訊息）。沒 task list 容易靜默略過。

### Step 1: Identify Plugin

從 `$ARGUMENTS` 取得 plugin name，找到 plugin 目錄：

```bash
MARKETPLACE_ROOT="找到 marketplace repo 根目錄"
PLUGIN_DIR="$MARKETPLACE_ROOT/plugins/$PLUGIN_NAME"
```

如果找不到，問使用者。

### Step 2: Pre-flight Checklist

檢查 plugin 是否準備好發布：

| 項目 | 檢查方式 | 必要？ |
|------|---------|--------|
| plugin.json 存在 | 讀取 `.claude-plugin/plugin.json` | 必要 |
| name 是 kebab-case | 正則檢查 | 必要 |
| description 有填 | 長度 > 0 | 必要 |
| version 有填 | semver 格式 | 必要 |
| 至少一個 skill 或 command | 掃描 `skills/` 和 `commands/` | 必要 |
| 每個 SKILL.md 有 description | 讀取 frontmatter | 必要 |
| README.md 存在 | 檔案存在 | 建議 |
| **README.md 與新版本同步** | 見 Step 2.6 | **minor / major bump 必要**；patch 建議 |
| CLAUDE.md 存在 | 檔案存在 | 建議 |
| 無硬編碼絕對路徑 | grep `/Users/` 等 | 建議 |
| hooks 用 ${CLAUDE_PLUGIN_ROOT} | grep hooks 中的路徑 | 如有 hooks |
| **MCP binary 已發布到 release** | 見 Step 2.5 | **MCP plugin 必要** |

### Step 2.5: MCP Binary Check（MCP plugin 必跑）

如果 plugin 包含 MCP server wrapper（透過 `.mcp.json` + `bin/*-wrapper.sh`），**必須**驗證 wrapper 所引用的 binary 已發布到 GitHub Release，否則使用者裝新版 plugin 也拿不到對應的 binary。

**歷史脈絡**：plugin version bump 只更新 wrapper + marketplace.json，不會自動 trigger MCP binary 的 rebuild + release。若此步沒做好，使用者端會出現「plugin 顯示 vX.Y.Z，但跑的是舊 binary」的詭異狀態。

```bash
# 1. 偵測是否為 MCP plugin
MCP_JSON="$PLUGIN_DIR/.mcp.json"
if [ ! -f "$MCP_JSON" ]; then
    echo "Not an MCP plugin — skip Step 2.5"
    IS_MCP_PLUGIN=false
else
    IS_MCP_PLUGIN=true
fi

# 2. 若是 MCP plugin，掃 bin/ 下的 wrapper 抓 BINARY_NAME + GITHUB_REPO
if [ "$IS_MCP_PLUGIN" = "true" ]; then
    MCP_STALE=false
    for wrapper in "$PLUGIN_DIR/bin/"*wrapper.sh; do
        [ -f "$wrapper" ] || continue
        BINARY_NAME=$(grep '^BINARY_NAME=' "$wrapper" | head -1 | cut -d'"' -f2)
        GITHUB_REPO=$(grep '^GITHUB_REPO=' "$wrapper" | head -1 | cut -d'"' -f2)
        [ -z "$BINARY_NAME" ] && continue
        [ -z "$GITHUB_REPO" ] && continue

        # 3. 查詢該 repo 的 latest release 是否含對應 binary asset
        HAS_BINARY=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
            | grep '"browser_download_url"' | grep -c "/$BINARY_NAME\"" || true)

        if [ "$HAS_BINARY" = "0" ]; then
            echo "❌ BLOCKER: $BINARY_NAME not found in latest release of $GITHUB_REPO"
            echo "   Wrapper will fail to auto-download. Run mcp-deploy first:"
            echo "   cd <MCP-source-repo> && /devtools:mcp-deploy"
            MCP_STALE=true
        else
            echo "✅ $BINARY_NAME present in $GITHUB_REPO latest release"
        fi
    done

    # 4. 如果有任何 binary 不在 release → BLOCK deploy
    if [ "$MCP_STALE" = "true" ]; then
        echo ""
        echo "Plugin deploy blocked — MCP binary release is out of sync."
        echo "Fix: run /devtools:mcp-deploy from the MCP source repo first."
        exit 1
    fi
fi
```

**用 AskUserQuestion 再確認 binary 是否為當前 source code 版本**：

```
question: "Release 有 $BINARY_NAME，但可能是舊版。source code 從那次 release 後有改動嗎？"
options:
  - "沒改動，release 是最新"
  - "有改動但先 deploy plugin，之後再發 binary"
  - "有改動，我先去跑 /devtools:mcp-deploy 更新 binary"
```

**為什麼是 BLOCKER 而非 warning**：
| 狀況 | 後果 |
|------|------|
| Release 沒 binary | 使用者裝新版 plugin → wrapper auto-download 失敗 → 整個 plugin 無法使用 |
| Release 有 binary 但過時 | 使用者裝新版 plugin → 跑舊 binary → 新功能宣告了但跑不出來 |

第一種是 hard failure（使用者完全 blocked），必須 block；第二種是 silent failure（使用者困惑但能跑），可以 warn。

### Step 2.6: README Freshness Gate（正式發布 = README 必須同步）

`plugin-update` 的 Phase 2.5 是 ASK；這裡是 **minor / major bump 的必過關卡**。原因：plugin-deploy 代表正式發布，使用者進 marketplace 裝 plugin 第一眼就是 README，stale README 代表「功能宣稱 v$NEW 但文件還停在舊版」，是公開場合的差評起點。

#### 2.6.1: 分類版本 bump 類型

從 `Step 5: Version Bump` 預期的新版本反推 bump 類型（patch / minor / major）。若尚未決定，可先跳到 Step 5 決定後回來。

| Bump 類型 | README 要求 |
|-----------|-----------|
| **major** (x+1.0.0) | **MUST** — README 必須更新到新版本（通常含 breaking changes 描述） |
| **minor** (x.y+1.0) | **MUST** — 新 skill / 新工具 / 新 command 幾乎必然需要改 README |
| **patch** (x.y.z+1) | **SHOULD** — bug fix 若會改變行為則需更新；純內部修補可略 |

#### 2.6.2: Staleness 偵測（同 plugin-update Phase 2.5 Step 1）

掃六個信號（v1.15.0 起；第 4 條詳見 `rules/tool-readme-sync.md`）：
1. README 沒出現新版本字串（套用 Suppression A：README 完全沒版本標記時跳過）
2. README mtime 早於 skills/hooks/plugin.json 最近修改（套用 Suppression A + B：wrapper-only / marketplace 同步 commits 不算）
3. CHANGELOG.md 最新 entry 版本在 README 中找不到
4. **Component inventory mismatch** — 實際 `skills/` `agents/` `commands/` 目錄內容與 README 列表不符
5. **Tool count drift** — README 標題寫的工具數（"Available Tools (N)"）跟 plugin.json description 宣稱的工具數對不上
6. **Version history gap** — git log 顯示 shipped 過的版本中，有 2+ 個沒出現在 README 的 Version History 表格

每個信號的 bash 偵測碼跟 `plugin-update/SKILL.md` Phase 2.5 Step 1 完全一致，避免兩處邏輯漂移。

#### 2.6.2b: Component inventory 檢查

```bash
PLUGIN_DIR="plugins/$PLUGIN_NAME"

# 實際有的
ACTUAL_SKILLS=$(ls "$PLUGIN_DIR/skills/" 2>/dev/null | sort)
ACTUAL_AGENTS=$(ls "$PLUGIN_DIR/agents/"*.md 2>/dev/null | xargs -n1 basename -s .md 2>/dev/null | sort)
ACTUAL_COMMANDS=$(ls "$PLUGIN_DIR/commands/"*.md 2>/dev/null | xargs -n1 basename -s .md 2>/dev/null | sort)

# README 有沒有提到
for s in $ACTUAL_SKILLS; do
    grep -q "\`$s\`\|/$s\b" "$PLUGIN_DIR/README.md" 2>/dev/null || echo "⚠️ skill '$s' 不在 README"
done
for a in $ACTUAL_AGENTS; do
    grep -q "\`$a\`\|$a\b" "$PLUGIN_DIR/README.md" 2>/dev/null || echo "⚠️ agent '$a' 不在 README"
done
for c in $ACTUAL_COMMANDS; do
    grep -q "/$c\b\|\`$c\`" "$PLUGIN_DIR/README.md" 2>/dev/null || echo "⚠️ command '$c' 不在 README"
done
```

有任何 ⚠️ 都視為 stale 訊號 4。

#### 2.6.2c: Marketplace repo About metadata 審計（WARN，不 BLOCK）

多數 plugin 住在 `psychquant-claude-plugins` monorepo 底下，plugin 自己沒有獨立 repo metadata。
但 plugin 的加入或大改可能影響 **marketplace repo** 的 About 是否還準確。

```bash
gh auth status >/dev/null 2>&1 || { echo "⚠️ gh 未登入，跳過 marketplace metadata audit"; exit 0; }

cd "$MARKETPLACE_ROOT"
MARKETPLACE_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -z "$MARKETPLACE_SLUG" ] && { echo "⚠️ 非 GitHub repo 或無權限"; exit 0; }

PLUGIN_COUNT=$(ls -d plugins/*/ 2>/dev/null | wc -l | tr -d ' ')
DESC=$(gh repo view --json description -q .description)
DESC_LEN=${#DESC}

echo "Marketplace: $MARKETPLACE_SLUG"
echo "Plugin count: $PLUGIN_COUNT"
echo "Description ($DESC_LEN chars): $DESC"

# 是否提到 plugin 總數（允許範圍模糊，不要一個個 pin 住）
echo "$DESC" | grep -qE "[0-9]+ plugins" || echo "💡 Marketplace description 沒提到 plugin 總數，加入 '$PLUGIN_COUNT plugins' 讓新訪客秒懂規模"

# Topics
TOPIC_COUNT=$(gh repo view --json repositoryTopics -q '.repositoryTopics | length')
[ "$TOPIC_COUNT" -lt 5 ] && echo "⚠️ Marketplace topics 太少（$TOPIC_COUNT < 5）"
[ "$TOPIC_COUNT" -lt 15 ] && echo "💡 建議 15-20 個 topics"
```

如果這次 deploy 新增了一個**新類型**的 plugin（例如首個 Rust-based plugin、首個 Zotero 整合），
強烈建議用 `gh repo edit --add-topic` 把對應 topic 加到 marketplace。

#### 2.6.2d: Plugin 對應的 binary repo metadata（若有）

當 plugin 是 MCP wrapper（`bin/*-wrapper.sh` 下載 binary）時，
binary 對應的獨立 repo（如 `PsychQuant/che-word-mcp`）才是使用者主要看到的 About。
這類 repo 的 metadata 屬於 `mcp-tools/rules/tool-readme-sync.md` 範疇——在 `mcp-deploy` Step 4.7 會處理。
這裡只需確認 plugin wrapper 版本和 binary repo 對齊。

#### 2.6.3: 行為決策

```
若 bump = major / minor 且 stale：
    AskUserQuestion: "正式 deploy v$NEW 前 README 必須同步。選擇處理方式："
    options:
      - "現在更新 README" — 我幫忙起草 → Edit → commit 後繼續 Step 3 Present Checklist
      - "改為 patch bump，README 暫不動" — 確認此變更不含對外 surface 變動
      - "中止 deploy" — 手動處理後再跑 plugin-deploy

若 bump = patch 且 stale：
    顯示 warning 但不 block，繼續 Step 3 Checklist
```

#### 2.6.4: 為什麼 plugin-deploy 比 plugin-update 嚴格

| Skill | README stale 時 |
|-------|---------------|
| `plugin-update`（日常）| 三選項，略過 OK（開發過程中 README 落後一版很常見）|
| `plugin-deploy`（發版）| minor/major bump BLOCK；patch warn（發版 = 對外承諾，文件必須 match）|

### Step 3: Present Checklist

```markdown
## Plugin Deploy Pre-flight: {plugin-name}

### 必要項目
- [x] plugin.json ✅
- [x] name: {name} ✅
- [x] description ✅
- [x] version: {version} ✅
- [x] skills: {count} 個 ✅

### 建議項目
- [x] README.md ✅
- [ ] LICENSE ❌
- [x] CLAUDE.md ✅

### 問題
{列出需要修正的項目}

要修正問題後繼續，還是直接發布？
```

### Step 4: Fix Issues (Optional)

如果有問題，幫使用者修正：
- 缺 README.md → 從 CLAUDE.md 和 skills 自動產生
- **README 已過時**（Step 2.6 標記 stale）→ 讀 CHANGELOG.md + `git log --oneline -n 10 -- plugins/{name}/` 當素材，提出 README diff → 使用者審閱 → Edit → commit
- 缺 LICENSE → 建立 MIT LICENSE
- 硬編碼路徑 → 提示修正

### Step 5: Version Bump

問使用者版本號要怎麼升：

```
目前版本：{current_version}

1. Patch（{x.y.z+1}）— bug fix、小修正
2. Minor（{x.y+1.0}）— 新功能、新 skill
3. Major（{x+1.0.0}）— 破壞性變更
4. 自訂版本號
```

更新兩個地方的版本號：
1. `plugins/{name}/.claude-plugin/plugin.json` 的 `version`
2. `.claude-plugin/marketplace.json` 中對應 plugin 的 `version`

### Step 6: Update marketplace.json

確認 marketplace.json 中的 plugin entry 資訊是最新的：
- version 已更新
- description 與 plugin.json 一致
- 如果是新 plugin，確認 entry 已存在

### Step 7: Commit & Push

```bash
cd "$MARKETPLACE_ROOT"
git add "plugins/{plugin-name}" ".claude-plugin/marketplace.json"
git commit -m "release: {plugin-name} v{new_version} — {簡述變更}"
git push origin main
```

### Step 8: Sync & Reload

```bash
# 同步 marketplace cache
claude plugin marketplace update {marketplace-name}

# 更新已安裝的 plugin
claude plugin update {plugin-name}
```

### Step 9: Verify

```bash
# 確認版本正確
claude plugin list | grep {plugin-name}
```

提示使用者：
```
{plugin-name} v{new_version} 已發布！

- marketplace.json ✅ 已更新
- git push ✅ 已推送
- plugin cache ✅ 已同步
- 安裝版本 ✅ 已更新

其他使用者可透過以下指令安裝/更新：
  /plugin marketplace update {marketplace-name}
  /plugin install {plugin-name}@{marketplace-name}
```

## Notes

- 這個 skill 發布到**自己的 marketplace**（如 PsychQuant），push 即生效，不需要審核
- 如果未來要提交到 Anthropic 官方 marketplace，目前只接受企業級合作夥伴
- 發布前建議先用 `claude --plugin-dir` 本地測試

## MCP plugin 的依賴

若此 plugin 含 `.mcp.json` + `bin/*-wrapper.sh`，屬於 **binary-based MCP plugin**：

- Wrapper 執行時會自動從 GitHub Release 下載 binary
- Plugin version bump **不等於** binary 會自動更新
- 必須先在 MCP source repo 跑 `/devtools:mcp-deploy` 發 binary release，才能跑 `plugin-deploy`

詳見 [rules/mcp-binary-distribution.md](../../rules/mcp-binary-distribution.md) 的「plugin-deploy ↔ mcp-deploy 依賴關係」。Step 2.5 會自動偵測並 block 不同步的情況。
