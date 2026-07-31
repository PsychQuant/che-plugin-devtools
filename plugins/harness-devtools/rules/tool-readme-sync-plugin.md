# Plugin Component Surface ↔ README 同步紀律

Plugin 自身的「工具面」是它匯出的 skills / agents / commands / hooks。這個集合變動時，**必須**在同一個 commit 或同一個 release 週期內更新 README。

## 為什麼

Plugin README 是 marketplace 卡片的延伸。讀者（人 + LLM）靠 README 判斷：

| 問題 | README 要能回答 |
|------|--------------|
| 這 plugin 做什麼？ | Features / Overview |
| 裝了之後我能用哪些東西？ | Skills 清單 + Agents 清單 + Commands 清單 |
| 對應工作流怎麼跑？ | Usage / Examples |
| 和相關 plugin 怎麼區分？ | Comparison / When to use which |

Plugin 的 component 一改但 README 沒動：

- 新加的 skill 使用者不知道它存在 → 沒人叫 → 做白工
- 移除的 skill README 還寫著 → 使用者叫了但找不到 → 回報 bug
- Skills 之間職責分工改動（例如把功能從 A skill 搬到 B skill）→ 舊 README 的決策樹誤導

## 觸發條件

滿足任一即啟動：

1. **新增 skill / agent / command / hook**
2. **移除 / rename 上述任一**
3. **Skill 的 description 重大改寫**（因為 description 決定 LLM 何時叫它）
4. **Skill 之間職責重分配**（功能從 A 搬到 B，兩邊 README 都要動）
5. **Plugin keyword / description 在 plugin.json 改變**
6. **依賴的 binary 或外部 plugin 改變**（例如原本依賴 mcp-X，改成內建）

純 SKILL.md 內部步驟優化（2-step 改 3-step，不影響使用者感知）→ 不需動 README。

## 必要的 README 改動範圍

| 改動 | README 連動 |
|------|------------|
| 加 skill | Skills 表格 / Quick Reference / Usage Examples |
| 加 agent | Agents 表格 + When to use this agent |
| 加 command | Commands 表格 + 觸發語法 |
| Skill 之間職責重劃 | 「Skill 比較表」或 Decision tree |
| 依賴其他 plugin | Prerequisites / Related plugins |
| 重大重構（v1 → v2） | Migration section |

## Plugin 家族的「橫向同步」責任

`plugin-tools` / `mcp-tools` / `cli-tools` 這種**家族 plugin**有額外義務：
當其中一個 plugin 的 `*-deploy` skill 規則改了（例如 `mcp-deploy` 加了 Step 2.6 README check），
它的 sibling（`cli-deploy`、`plugin-deploy`）如果適用同樣的 pattern，**應該同步加**。

否則會出現「MCP 的 deploy 會檢查 README，CLI 的 deploy 不會」這種隱性不對稱，踩坑的是未來的自己。

## Deploy 前的自我檢查

`plugin-deploy` skill 跑完**前**做這個檢查：

```bash
# 實際有的 components
ACTUAL_SKILLS=$(ls plugins/$PLUGIN/skills/ 2>/dev/null | sort)
ACTUAL_AGENTS=$(ls plugins/$PLUGIN/agents/*.md 2>/dev/null | xargs -n1 basename | sort)
ACTUAL_COMMANDS=$(ls plugins/$PLUGIN/commands/*.md 2>/dev/null | xargs -n1 basename -s .md | sort)

# README 裡提到的 components
DOCUMENTED=$(grep -oE '`[a-z_-]+`' plugins/$PLUGIN/README.md | sort -u)

# 找出 README 沒提到的 actual component
for s in $ACTUAL_SKILLS; do
  grep -q "\`$s\`" plugins/$PLUGIN/README.md || echo "⚠️ Skill '$s' 不在 README"
done
```

## 當 README 落差已累積時的補救

1. **用 `ls skills/ agents/ commands/` 做 ground truth**，逐一檢查 README 是否列齊
2. **Skills 表格重建** — 每個 skill 的 description frontmatter 抓出來對照 README
3. **Agent 描述重建** — agent 描述是判斷「這個 agent 是否應該被叫」的關鍵，對照 README 確保對齊
4. **Version History 表格補齊** — 把中間遺漏的 minor 版本補上，寫明當時加了什麼

## GitHub Repo About Metadata（和 README 同等級的使用者第一印象）

**重要提醒**：多數 plugin 沒有自己的 repo（都住在 `psychquant-claude-plugins` 這個 monorepo 底下）。這個章節主要適用於：

1. **Marketplace repo 本身**（`psychquant-claude-plugins`）— 整個 marketplace 的 About
2. **含 binary 的 plugin 家族** — 例如 `che-word-mcp` plugin 對應的 `PsychQuant/che-word-mcp` repo
3. **從 monorepo 拆出去的獨立 plugin repo** — 極少數情況

對於住在 monorepo 裡的 plugin，plugin 自身沒有 repo metadata 可改；但 plugin 的存在**可能要反映到 marketplace repo 的 description**（例如 marketplace 裡裝的 plugin 從 15 個變 25 個，description 可能要更新）。

### Plugin 對應的 binary repo（最常見的情況）

當 plugin 包 MCP binary（`che-word-mcp-wrapper.sh` → `~/bin/CheWordMCP`）時，**binary repo 的 About metadata** 才是使用者主要會看到的。規則見 `mcp-tools/rules/tool-readme-sync.md` 的 GitHub Repo About Metadata 章節。

### Marketplace repo 的 About（如果你是 maintainer）

| 欄位 | 位置 | 應該同步的時機 |
|------|------|-------------|
| **Description** | `gh repo view PsychQuant/psychquant-claude-plugins --json description` | 加了新 plugin 類別（如第一個 OCR plugin、第一個 bioinformatics plugin）|
| **Topics** | 同上 | 隨 plugin 家族成長；例如首次加入 `rust-plugin` 類型就該加 `rust` topic |
| **Homepage URL** | 同上 | 通常指 marketplace 首頁或 docs 網站 |

範例 marketplace description 模板：

```
Curated Claude Code plugins marketplace with N plugins — MCP servers (Word / PPTX / Calendar / ...), dev tools (IDD / Spectra / TDD), CLI toolkits. Swift / TypeScript / Python. Optimized for {domain focus}.
```

### 為什麼這條對 plugin-tools 特別重要

`plugin-deploy` / `plugin-update` skill 跑完後通常會 push 到 marketplace repo。當 plugin 數量從 20 → 30 時，marketplace description 不會自己更新——必須有人記得。本 rule 就是那個「記得」的點。

### Deploy 前的 marketplace 審計

```bash
# 抓實際 plugin 數量
PLUGIN_COUNT=$(ls -d /Users/che/Developer/psychquant-claude-plugins/plugins/*/ | wc -l | tr -d ' ')

# marketplace repo description 是否反映
CURRENT_DESC=$(gh repo view PsychQuant/psychquant-claude-plugins --json description -q .description)
echo "$CURRENT_DESC" | grep -qE "[0-9]+ plugins" || echo "⚠️ Marketplace description 沒提到 plugin 總數"

# topics 數量
TOPIC_COUNT=$(gh repo view PsychQuant/psychquant-claude-plugins --json repositoryTopics -q '.repositoryTopics | length')
[ "$TOPIC_COUNT" -ge 5 ] || echo "⚠️ Marketplace topics 只有 $TOPIC_COUNT 個（建議 15-20）"
```

## 例外

- 純 rule 修改或 bug fix（SKILL.md 內部小改，沒加減 component）→ README / Description / Topics 皆不用動
- 未發佈到 marketplace 的 WIP plugin → README 可延後；但 push 前要補
- 住在 monorepo 裡的 plugin（沒獨立 repo）→ 不需要自己改 About metadata，但要注意 marketplace repo 是否被此 plugin 的加入改變了定位

## 和其他 skill 的關係

- `plugin-deploy` Step 2.6 做 component inventory 對照，不一致時 **BLOCK** 發布
- `plugin-upgrade` 建議加新 skill 時，會提醒「README Skills 表格要補 1 行」
- `plugin-create` scaffold 直接產出含 Skills / Agents / Commands 三區塊的 README 骨架

## TL;DR

**改了 `skills/` `agents/` `commands/` 任一個目錄，就改 README；README 沒改就不要 bump 版本、不要 push。**
