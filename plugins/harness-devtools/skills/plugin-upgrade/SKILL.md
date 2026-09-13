---
name: plugin-upgrade
description: |
  分析現有 plugin 的結構和能力，找出缺少的組件、過時的格式、
  可以從相關專案匯入的 rules/skills/agents，然後自動補上。
  當用戶想要「改善 plugin」、「升級 plugin」、「plugin 缺什麼」、
  「把 X 的設定加進 plugin」、「plugin upgrade」時使用。
argument-hint: "<plugin-name> [--source /path/to/related/project]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# Plugin Upgrade — 分析與增強現有 Plugin

掃描現有 plugin 的結構，對比最佳實踐和相關專案，找出缺少的組件並自動補上。

## 與其他 skill 的區別

| Skill | 做什麼 | 什麼時候用 |
|-------|--------|-----------|
| `plugin-create` | 從零建立新 plugin | 全新的 plugin |
| `plugin-upgrade` | **改善現有 plugin 的能力** | plugin 功能不足、想加東西 |
| `plugin-update` | 同步版本號 + push + reload | 改完 code 後的機械步驟 |
| `plugin-health` | 檢查載入錯誤 | plugin 壞了 |
| `plugin-deploy` | 品質檢查 + 版本升級 + 發布 | 要正式發布 |

## Execution Steps

### Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="parse_arguments", description="Step 0: 解析 plugin-name 和 --source（若有）")
TaskCreate(name="locate_plugin", description="Step 1: 找到 marketplace 下的 plugin 目錄")
TaskCreate(name="scan_structure", description="Step 2: 掃描 skills/agents/rules/hooks/commands/CLAUDE.md")
TaskCreate(name="check_hook_format", description="Step 3: 驗證 hooks 格式（plugin.json 不該含 hooks）")
TaskCreate(name="scan_related_projects", description="Step 4: 掃 --source 的 .claude/ 目錄找可匯入資源")
TaskCreate(name="present_report", description="Step 5: 顯示 upgrade report，列出問題和可匯入清單")
TaskCreate(name="execute_fixes", description="Step 6: 使用者選擇修復範圍（全部/🔴/逐一/只看報告）")
TaskCreate(name="fix_hook_format", description="Step 7: 轉換 plugin.json hooks → hooks/hooks.json（若需要）")
TaskCreate(name="import_rules", description="Step 8: 從 source 匯入 rules")
TaskCreate(name="import_skills", description="Step 9: 從 source 匯入相關 skills（使用者選）")
TaskCreate(name="update_claude_md", description="Step 10: 重新生成 CLAUDE.md 反映所有組件")
TaskCreate(name="version_bump", description="Step 11: 根據變更幅度 bump 版本")
TaskCreate(name="deploy", description="Step 12: 呼叫 plugin-update（git commit/push + marketplace update）")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

### Step 0.5: Parse Arguments

從 `<args>` 取得：
- `plugin-name`：要升級的 plugin
- `--source /path`（可選）：相關專案路徑，從中匯入 rules/skills

如果沒指定 `--source`，嘗試從 plugin 的 CLAUDE.md 或 agent 描述推斷相關專案。

### Step 1: Locate Plugin

```bash
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
MARKETPLACE_ROOT="$(resolve_marketplace_root psychquant-claude-plugins)"   # 或改成目標 plugin 所在的 marketplace
# 目錄由 manifest 的 plugins[].source 解析（#18）；plugins/<name> 硬編對 ./plugin 佈局與巢狀 marketplace 都指到不存在的目錄
PLUGIN_DIR=$(resolve_plugin_dir "$MARKETPLACE_ROOT" '{plugin-name}') || { echo "✗ '{plugin-name}' 不在 $MARKETPLACE_ROOT 的 manifest 裡（resolve_plugin_dir rc $?）" >&2; exit 1; }

# 確認存在
ls "$PLUGIN_DIR/.claude-plugin/plugin.json"
```

### Step 2: Scan Current Structure

掃描 plugin 現有的組件：

```bash
echo "=== Skills ==="
ls "$PLUGIN_DIR/skills/" 2>/dev/null || echo "(none)"

echo "=== Agents ==="
ls "$PLUGIN_DIR/agents/" 2>/dev/null || echo "(none)"

echo "=== Rules ==="
ls "$PLUGIN_DIR/rules/" 2>/dev/null || echo "(none)"

echo "=== Hooks ==="
ls "$PLUGIN_DIR/hooks/" 2>/dev/null || echo "(none)"

echo "=== Commands ==="
ls "$PLUGIN_DIR/commands/" 2>/dev/null || echo "(none)"

echo "=== CLAUDE.md ==="
[ -f "$PLUGIN_DIR/CLAUDE.md" ] && echo "exists" || echo "(missing)"

echo "=== README.md ==="
[ -f "$PLUGIN_DIR/README.md" ] && echo "exists" || echo "(missing)"
```

### Step 3: Check Hook Format

Plugin hooks 的正確格式是 `hooks/hooks.json`，不是 `plugin.json` 裡的 `hooks` 欄位。

```bash
# 檢查 plugin.json 是否誤含 hooks
python3 -c "
import json
with open('$PLUGIN_DIR/.claude-plugin/plugin.json') as f:
    d = json.load(f)
if 'hooks' in d:
    print('ERROR: hooks should be in hooks/hooks.json, not plugin.json')
else:
    print('OK: plugin.json clean')
"

# 檢查 hooks.json 格式
if [ -f "$PLUGIN_DIR/hooks/hooks.json" ]; then
    python3 -c "
import json
with open('$PLUGIN_DIR/hooks/hooks.json') as f:
    d = json.load(f)
# 正確格式：hooks.{EventType}[].matcher + hooks[].type + hooks[].command
for event_type, matchers in d.get('hooks', {}).items():
    for m in matchers:
        if 'matcher' not in m:
            print(f'WARNING: {event_type} entry missing matcher')
        if 'hooks' not in m:
            print(f'WARNING: {event_type} entry missing hooks array')
        else:
            for h in m['hooks']:
                if 'type' not in h or 'command' not in h:
                    print(f'WARNING: hook entry missing type or command')
print('Hook format check done')
"
fi
```

### Step 4: Scan Related Projects

如果有 `--source` 或能推斷出相關專案，掃描它的 `.claude/` 目錄：

```bash
SOURCE_DIR="$SOURCE_PATH/.claude"

echo "=== Source Rules ==="
ls "$SOURCE_DIR/rules/" 2>/dev/null

echo "=== Source Skills ==="
ls "$SOURCE_DIR/skills/" 2>/dev/null

echo "=== Source Settings ==="
cat "$SOURCE_DIR/settings.json" 2>/dev/null
```

比對 plugin 缺少什麼。

### Step 5: Present Upgrade Report

```markdown
## Plugin Upgrade Report: {plugin-name}

### 現有組件
| 類型 | 數量 | 項目 |
|------|------|------|
| Skills | 2 | grind, status |
| Agents | 1 | lean-prover |
| Rules | 0 | (none) |
| Hooks | 1 | PostToolUse |

### 發現的問題
| # | 問題 | 嚴重度 | 自動修復？ |
|---|------|--------|-----------|
| 1 | hooks 在 plugin.json 而非 hooks.json | 🔴 會導致安裝失敗 | ✅ |
| 2 | 缺少 rules/（相關專案有 2 個） | 🟡 影響證明品質 | ✅ |
| 3 | 缺少 codex-prove-assist skill | 🟡 缺少 Codex 整合 | ✅ |
| 4 | CLAUDE.md 未列出所有組件 | 🟢 文件不完整 | ✅ |

### 可從相關專案匯入
| 來源 | 檔案 | 用途 |
|------|------|------|
| {source}/.claude/rules/mathlib-api.md | → rules/ | Mathlib API 速查 |
| {source}/.claude/rules/lean-imports.md | → rules/ | 引用紀律 |
| {source}/.claude/skills/codex-prove-assist/ | → skills/ | Codex 整合 |

要自動修復所有問題嗎？
```

### Step 6: Execute Fixes (AskUserQuestion)

問用戶：
1. 修復所有問題（推薦）
2. 只修 🔴 嚴重問題
3. 逐一確認
4. 只看報告，不修

### Step 7: Fix Hook Format

如果 `plugin.json` 含 `hooks`：

1. 讀取 `plugin.json` 的 hooks 欄位
2. 轉換成 `hooks/hooks.json` 格式
3. 從 `plugin.json` 移除 hooks 欄位
4. 寫入 `hooks/hooks.json`

正確的 `hooks/hooks.json` 格式：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "your-command-here"
          }
        ]
      }
    ]
  }
}
```

### Step 8: Import Rules from Source

```bash
mkdir -p "$PLUGIN_DIR/rules"

for rule_file in "$SOURCE_DIR/rules/"*.md; do
    rule_name=$(basename "$rule_file")
    if [ ! -f "$PLUGIN_DIR/rules/$rule_name" ]; then
        cp "$rule_file" "$PLUGIN_DIR/rules/"
        echo "Imported: $rule_name"
    else
        echo "Already exists: $rule_name"
    fi
done
```

### Step 9: Import Skills from Source

只匯入與 plugin 功能相關的 skills（不是全部）。
用 AskUserQuestion 讓用戶選擇要匯入哪些。

```bash
mkdir -p "$PLUGIN_DIR/skills"

for skill_dir in "$SOURCE_DIR/skills/"*/; do
    skill_name=$(basename "$skill_dir")
    # 跳過 spectra 系列（那是 Spectra 框架的，不是 plugin 的）
    if [[ "$skill_name" == spectra-* ]]; then
        continue
    fi
    if [ ! -d "$PLUGIN_DIR/skills/$skill_name" ]; then
        echo "Available: $skill_name"
    fi
done
```

### Step 10: Update CLAUDE.md

重新生成 CLAUDE.md，列出所有組件：

- 所有 skills（含新匯入的）
- 所有 agents
- 所有 rules（含新匯入的）
- 所有 hooks
- 使用範例（含 ralph-loop 整合）

### Step 11: Version Bump

根據變更幅度建議版本號：
- 只修 hooks 格式 → patch（x.y.z+1）
- 加了 rules/skills → minor（x.y+1.0）
- 改了 agent 或 CLAUDE.md 架構 → minor

更新 `plugin.json` 和 `marketplace.json` 的版本號。

### Step 12: Deploy（呼叫 plugin-update）

自動執行 plugin-update 的流程：
1. `git add` + `git commit`
2. `git push`
3. `claude plugin marketplace update`
4. `claude plugin install`（或 `update`）

提醒用戶重啟 Claude Code。

## 升級策略

### Rules 匯入規則

| 來源 | 匯入條件 |
|------|---------|
| 相關專案的 `.claude/rules/` | 與 plugin 功能直接相關 |
| 其他 plugin 的 `rules/` | 有共用價值（如通用的 coding style） |
| 全局 rules（`~/.claude/rules/`） | 不匯入（那是全局的，不需要在 plugin 裡重複） |

### Skills 匯入規則

| 來源 skill | 匯入條件 |
|-----------|---------|
| 與 plugin 核心功能相關 | ✅ 匯入 |
| Spectra 系列（spectra-*） | ❌ 跳過（框架 skill，不是功能 skill） |
| 已存在的同名 skill | ❌ 跳過（避免覆蓋） |

### Agent 匯入規則

通常不從外部匯入 agent——agent 應該是 plugin 自己設計的。
但如果相關專案有一個 agent 明確標註「可共用」，可以建議匯入。
