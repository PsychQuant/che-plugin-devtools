---
name: plugin-create
description: |
  建立新的 Claude Code Plugin，含完整目錄結構、marketplace.json 同步、CLAUDE.md 產生、GitHub Issue 追蹤。
  支援從零建立或從現有 .claude/skills/ 轉換。
  當用戶提到「建立 plugin」「新 plugin」「create plugin」「轉成 plugin」「skill 變 plugin」時使用。
argument-hint: "[plugin-name] or [convert skill-name]"
allowed-tools:
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(mkdir:*)
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(claude:*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# Create Plugin — 建立新 Plugin 完整流程

建立新的 Claude Code Plugin，包含目錄結構、manifest、CLAUDE.md、marketplace 同步、GitHub Issue 追蹤。

## 兩種模式

| 模式 | 觸發 | 說明 |
|------|------|------|
| **New** | `/devtools:plugin-create my-plugin` | 從零建立全新 plugin |
| **Convert** | `/devtools:plugin-create convert skill-name` | 從現有 `.claude/skills/` 轉換成 plugin |

## Execution Steps

### Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="parse_arguments", description="解析 $ARGUMENTS 決定 New/Convert mode")
TaskCreate(name="gather_info", description="AskUserQuestion 蒐集 plugin name / description / category / skills")
TaskCreate(name="locate_marketplace", description="找到 plugin marketplace repo（psychquant 或 local）")
TaskCreate(name="create_directory_structure", description="mkdir plugins/{name}/{.claude-plugin,skills,...}")
TaskCreate(name="create_plugin_json", description="寫 .claude-plugin/plugin.json")
TaskCreate(name="create_or_convert_skills", description="New: 建空 skills / Convert: 從 .claude/skills 轉換")
TaskCreate(name="generate_claude_md", description="寫 plugin CLAUDE.md 列出所有組件")
TaskCreate(name="sync_marketplace_json", description="加入 marketplace.json 的 plugins 陣列")
TaskCreate(name="commit_push", description="git add + commit + push marketplace repo")
TaskCreate(name="install_plugin", description="claude plugin install {name}@marketplace")
TaskCreate(name="create_github_issue", description="（可選）建追蹤 issue 紀錄這個 plugin 的 roadmap")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

### Step 0.5: Parse Arguments

```
$ARGUMENTS 格式：
- "my-plugin" → New mode
- "convert codex-review" → Convert mode（從 .claude/skills/codex-review 轉換）
- "convert codex-review issue" → Convert mode（合併多個 skill 成一個 plugin）
```

### Step 1: Gather Info (AskUserQuestion)

問以下問題（缺的才問）：

1. **Plugin name**（kebab-case）
2. **Description**（一句話描述）
3. **Category**（development / productivity / documentation / other）
4. **Target repo**（預設 `PsychQuant/psychquant-claude-plugins`）
5. **Components**：要包含哪些？（skills / commands / agents / hooks / MCP）

### Step 2: Locate Plugin Marketplace Repo

```bash
# 找到 marketplace repo 的本地路徑
# 已知 marketplace 的路徑一律由 scripts/resolve-marketplace.sh 解析，不要寫死
MARKETPLACE_ROOT=$(git -C "$PLUGIN_SOURCE" rev-parse --show-toplevel 2>/dev/null)
```

如果找不到，問使用者 marketplace repo 的路徑。

### Step 3: Create Directory Structure

```bash
PLUGIN_DIR="$MARKETPLACE_ROOT/plugins/{plugin-name}"

mkdir -p "$PLUGIN_DIR/.claude-plugin"
mkdir -p "$PLUGIN_DIR/skills"   # if skills selected
mkdir -p "$PLUGIN_DIR/commands" # if commands selected
mkdir -p "$PLUGIN_DIR/agents"   # if agents selected
mkdir -p "$PLUGIN_DIR/hooks"    # if hooks selected
```

### Step 4: Create plugin.json

```json
{
  "name": "{plugin-name}",
  "description": "{description}",
  "version": "1.0.0",
  "author": {
    "name": "Che Cheng"
  }
}
```

### Step 5: Convert or Create Skills

#### Convert Mode

對每個要轉換的 skill：

1. 讀取 `.claude/skills/{skill-name}/SKILL.md`
2. 複製到 `$PLUGIN_DIR/skills/{skill-name}/SKILL.md`
3. 更新 SKILL.md 的 description（加上 plugin context）
4. 如果有 `references/` 子目錄，一併複製

#### New Mode

為每個 skill 建立骨架 SKILL.md：

```markdown
---
name: {skill-name}
description: |
  {skill description}
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - AskUserQuestion
---

# {Skill Title}

## Purpose

{TODO: describe what this skill does}

## Execution Steps

### Step 1: {TODO}

{TODO}
```

### Step 6: Generate CLAUDE.md

自動在 plugin 根目錄產生 CLAUDE.md：

```markdown
# {plugin-name} — CLAUDE.md

## Purpose

{description}

## Skills

| Skill | 用途 |
|-------|------|
| `/devtools:{skill-1}` | {skill-1 description} |
| `/devtools:{skill-2}` | {skill-2 description} |

## Development

- Plugin structure: see [official plugin-dev](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev)
- Update after changes: `/devtools:plugin-update {plugin-name}`
- Health check: `/devtools:plugin-health`
```

### Step 7: Update marketplace.json

讀取現有 `$MARKETPLACE_ROOT/.claude-plugin/marketplace.json`，在 `plugins` 陣列末尾新增：

```json
{
  "name": "{plugin-name}",
  "version": "1.0.0",
  "description": "{description}",
  "author": {
    "name": "Che Cheng"
  },
  "source": "./plugins/{plugin-name}",
  "category": "{category}"
}
```

**注意**：不要覆蓋整個檔案，用 Edit tool 在最後一個 plugin entry 後面插入。

### Step 8: Commit & Push

```bash
cd "$MARKETPLACE_ROOT"
git add "plugins/{plugin-name}" ".claude-plugin/marketplace.json"
git commit -m "feat: Add {plugin-name} plugin — {description}"
git push origin main
```

### Step 9: Create GitHub Issue

```bash
gh issue create \
  --repo {target-repo} \
  --title "[PLUGIN] {plugin-name} — {description}" \
  --body "## New Plugin

Plugin \`{plugin-name}\` created.

### Components
- Skills: {list of skills}
- Commands: {list or 'none'}
- Agents: {list or 'none'}
- Hooks: {list or 'none'}

### Status
- [x] Directory structure created
- [x] plugin.json manifest
- [x] CLAUDE.md generated
- [x] marketplace.json updated
- [x] Committed and pushed
- [ ] Skills content (TODO: fill in SKILL.md bodies)
- [ ] Testing with \`claude --plugin-dir\`
- [ ] Plugin update: \`/devtools:plugin-update {plugin-name}\`

### Convert Source
{if convert mode: list source .claude/skills/ paths}
{if new mode: 'Created from scratch'}
"
```

### Step 10: Sync & Reload

```bash
# Sync marketplace
claude plugin marketplace update psychquant-claude-plugins

# Update installed plugins
claude plugin update {plugin-name}
```

提示使用者：
```
Plugin 已建立！接下來：
1. 填寫 skills/ 裡的 SKILL.md 內容
2. 用 `claude --plugin-dir ./plugins/{plugin-name}` 本地測試
3. 測試完成後執行 `/devtools:plugin-update {plugin-name}` 同步
```

## Convert Mode 特別注意

### 從 local skill 轉換時

1. **不要刪除** `.claude/skills/` 裡的原始檔案 — 讓使用者自己決定何時移除
2. **Skill 名稱會改變**：`/codex-review` → `/issue-driven-dev:codex-review`（加 namespace）
3. **allowed-tools 可能需要調整**：local skill 可能用了 project-specific 路徑
4. **References 目錄**：如果 skill 有 `references/` 子目錄，整個複製

### 合併多個 skill 到一個 plugin

```
/devtools:plugin-create convert codex-review issue
```

這會把 `.claude/skills/codex-review` 和 `.claude/skills/issue` 合併到同一個 plugin。
Plugin 名稱由 Step 1 詢問使用者。

## 參考

- 官方 plugin 開發指南：https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- Plugin 結構規範：https://code.claude.com/docs/en/plugins.md
- Plugin 技術參考：https://code.claude.com/docs/en/plugins-reference.md
