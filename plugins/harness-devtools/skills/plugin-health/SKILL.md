---
name: plugin-health
description: 檢查所有已安裝 plugin 的健康狀態（載入錯誤、版本不同步、hook 格式、腳本權限、MCP binary 缺失）。當用戶提到「plugin 有問題」、「plugin 載不出來」、「檢查 plugin 狀態」、「plugin failed to load」、「plugin 診斷」時使用。
allowed-tools:
  - Bash(claude:*)
  - Bash(ls:*)
  - Bash(file:*)
  - Bash(chmod:*)
  - Bash(python3:*)
  - Bash(jq:*)
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# Plugin Health Check

檢查所有已安裝 plugin 的健康狀態並修復常見問題。

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 stage-level todo list：

```
TaskCreate(name="list_plugins_and_status", description="Phase 1: claude plugin list + claude plugin marketplace list")
TaskCreate(name="check_hook_format", description="Phase 2 Check 1: 掃 hooks.json 格式錯誤")
TaskCreate(name="check_script_permissions", description="Phase 2 Check 2: .sh 檔是否 executable")
TaskCreate(name="check_plugin_json", description="Phase 2 Check 3: plugin.json 必要欄位")
TaskCreate(name="check_mcp_binaries", description="Phase 2 Check 4: MCP wrapper 引用的 binary 是否存在 + universal")
TaskCreate(name="check_directory_structure", description="Phase 2 Check 5: .claude-plugin 等目錄結構")
TaskCreate(name="check_version_sync", description="Phase 3: marketplace.json vs installed 版本同步")
TaskCreate(name="report_summary", description="Phase 4: 彙整所有 issue，排優先級，列修復步驟")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

**為什麼強制**：plugin-health 跑很多獨立檢查，沒 task list 容易少做（特別是 MCP binary check 和 version sync），這些 silent failure 最傷。

---

## Phase 1: 取得全局狀態

### Step 1: 列出所有 plugin 和狀態

```bash
claude plugin list 2>&1
```

從輸出中分類：
- **✔ enabled** — 正常
- **✘ failed to load** — 有問題，記錄 Error 訊息
- **disabled** — 用戶停用（不算問題）

### Step 2: 列出所有 marketplace

```bash
claude plugin marketplace list 2>&1
```

---

## Phase 2: 逐一診斷問題 Plugin

對每個 `failed to load` 的 plugin 執行以下檢查。

### Check 1: Hook 格式

最常見的錯誤。hooks.json 的正確格式：

```json
{
  "hooks": {
    "EventName": [
      {
        "matcher": "ToolPattern",
        "hooks": [
          { "type": "command", "command": "script.sh" }
        ]
      }
    ]
  }
}
```

**常見錯誤**：
- 缺少外層 `hooks` key → 整個 JSON 直接是 event map
- `SessionStart` 直接放 hook object 而非 `{ matcher, hooks: [...] }` 陣列
- 缺少 `hooks` 陣列（直接把 `type`/`command` 放在 matcher 層級）

找到 plugin 的 hooks.json 並檢查格式：

```bash
# 找到 plugin cache 路徑
ls ~/.claude/plugins/cache/{marketplace_name}/{plugin_name}/*/hooks/hooks.json 2>/dev/null

# 或從源碼檢查
cat {source_path}/hooks/hooks.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'hooks' not in d:
    print('ERROR: Missing top-level \"hooks\" key')
    sys.exit(1)
for event, entries in d['hooks'].items():
    if not isinstance(entries, list):
        print(f'ERROR: {event} should be an array, got {type(entries).__name__}')
        continue
    for i, entry in enumerate(entries):
        if 'hooks' not in entry:
            print(f'ERROR: {event}[{i}] missing \"hooks\" array')
        elif not isinstance(entry['hooks'], list):
            print(f'ERROR: {event}[{i}].hooks should be an array')
        else:
            print(f'OK: {event}[{i}] — {len(entry[\"hooks\"])} hook(s)')
"
```

### Check 2: 腳本權限

Hook 和 wrapper 腳本必須有 executable 權限：

```bash
# 找所有 .sh 檔案
find {plugin_source_path} -name "*.sh" -not -perm +111 2>/dev/null
```

如果有未設定 +x 的腳本：
```bash
chmod +x {script_path}
```

### Check 3: plugin.json 格式

```bash
claude plugin validate {plugin_source_path} 2>&1
```

常見問題：
- JSON 語法錯誤（多餘逗號、缺少引號）
- 缺少 `name` 欄位
- 目錄結構錯誤（commands/skills/hooks 放在 .claude-plugin/ 裡面而非 plugin root）

### Check 4: MCP Server Binary

如果 plugin 有 `.mcp.json`，檢查 binary 是否存在：

```bash
cat {plugin_source_path}/.mcp.json | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
for name, cfg in d.items():
    cmd = cfg.get('command', '')
    # 替換 CLAUDE_PLUGIN_ROOT
    cmd = cmd.replace('\${CLAUDE_PLUGIN_ROOT}', '{plugin_source_path}')
    if cmd.startswith('/') or cmd.startswith('./'):
        if os.path.isfile(cmd) and os.access(cmd, os.X_OK):
            print(f'OK: {name} → {cmd}')
        else:
            print(f'MISSING: {name} → {cmd}')
    else:
        # 外部命令，用 which 檢查
        import shutil
        if shutil.which(cmd):
            print(f'OK: {name} → {cmd} (in PATH)')
        else:
            print(f'MISSING: {name} → {cmd} (not in PATH)')
"
```

### Check 5: 目錄結構

確認 commands/、skills/、hooks/、agents/ 在 plugin root，不在 .claude-plugin/ 裡：

```bash
# 錯誤位置
ls {plugin_source_path}/.claude-plugin/commands/ 2>/dev/null && echo "ERROR: commands/ inside .claude-plugin/"
ls {plugin_source_path}/.claude-plugin/skills/ 2>/dev/null && echo "ERROR: skills/ inside .claude-plugin/"
ls {plugin_source_path}/.claude-plugin/hooks/ 2>/dev/null && echo "ERROR: hooks/ inside .claude-plugin/"
```

---

## Phase 3: 版本同步檢查

對已知 marketplace repo 檢查版本是否同步。

### psychquant-claude-plugins

```bash
source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"
cd "$(resolve_marketplace_root psychquant-claude-plugins)"
python3 -c "
import json, os

# 讀 marketplace.json
with open('.claude-plugin/marketplace.json') as f:
    mp = json.load(f)

mp_versions = {p['name']: p['version'] for p in mp['plugins']}

# 讀每個 plugin 的 plugin.json
for plugin_dir in sorted(os.listdir('plugins')):
    pj_path = f'plugins/{plugin_dir}/.claude-plugin/plugin.json'
    if not os.path.exists(pj_path):
        continue
    with open(pj_path) as f:
        pj = json.load(f)
    pj_ver = pj.get('version', '(none)')
    mp_ver = mp_versions.get(plugin_dir, '(not in marketplace)')
    if mp_ver == '(not in marketplace)':
        print(f'⚠️  {plugin_dir}: v{pj_ver} — not in marketplace.json')
    elif pj_ver != mp_ver:
        print(f'⚠️  {plugin_dir}: plugin.json={pj_ver} marketplace.json={mp_ver}')
    else:
        print(f'✓  {plugin_dir}: v{pj_ver}')
"
```

---

## Phase 4: 報告與修復

### 輸出格式

```markdown
# Plugin Health Report

## 載入狀態
| Plugin | Status | Error |
|--------|--------|-------|
| ... | ✔/✘ | ... |

## 問題與修復

### 1. {plugin_name}: {error_summary}
- **原因**: ...
- **修復**: ...

### 2. ...

## 版本同步
| Plugin | plugin.json | marketplace.json | 狀態 |
|--------|-------------|------------------|------|
| ... | ... | ... | ✓/⚠️ |

## 建議動作
1. ...
2. ...
```

### 自動修復

如果問題可以自動修復（如 chmod +x、hooks.json 格式調整），徵求用戶同意後執行。

修復後重新驗證：
```bash
claude plugin validate {plugin_source_path} 2>&1
```

---

## 常見修復指南

### Hook Schema 錯誤

`"expected array, received undefined"` at `hooks.SessionStart.0.hooks`：

**原因**：SessionStart entry 缺少 `hooks` 陣列包裝。

**修復前**：
```json
{ "hooks": { "SessionStart": [{ "type": "command", "command": "script.sh" }] } }
```

**修復後**：
```json
{ "hooks": { "SessionStart": [{ "hooks": [{ "type": "command", "command": "script.sh" }] }] } }
```

### Plugin Not Found in Marketplace

`Plugin X not found in marketplace Y`：

**原因**：marketplace 已移除此 plugin，或 marketplace 名稱變更。

**修復**：
```bash
# 先移除壞的安裝
claude plugin uninstall {plugin_name}
# 如果需要重新安裝，從正確的 marketplace
claude plugin install {plugin_name}@{correct_marketplace}
```

### Binary Not Found

MCP server binary 找不到：

**修復**：重新 build 或下載 binary，確認路徑正確。
