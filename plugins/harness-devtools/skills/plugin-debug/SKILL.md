---
name: plugin-debug
description: 深度除錯單一 plugin 的問題（hook 行為異常、PostToolUse 副作用、chflags/權限衝突、cache 版本不一致）。當用戶提到「plugin 行為怪怪的」、「hook 沒生效」、「hook 副作用」、「plugin debug」、「為什麼 archived 被鎖」時使用。
argument-hint: <plugin-name>
allowed-tools:
  - Bash(claude:*)
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(find:*)
  - Bash(chflags:*)
  - Bash(diff:*)
  - Bash(python3:*)
  - Bash(jq:*)
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# Plugin Debug — 深度除錯

針對單一 plugin 的行為異常進行深度調查。與 `plugin-health`（全局快速檢查）互補。

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 stage-level todo list：

```
TaskCreate(name="identify_plugin", description="Phase 1: 確定要 debug 的 plugin + 找所有相關路徑（source / installed / cache）")
TaskCreate(name="check_version_consistency", description="Phase 2: 比對 source vs cache / diff 源碼差異 / 找舊版殘留")
TaskCreate(name="analyze_hooks", description="Phase 3: 列出所有 hook events + 分析副作用（特別是 chflags/xattr）")
TaskCreate(name="trace_runtime_behavior", description="Phase 4: 重現問題 + trace script 執行 + 檢查 exit code")
TaskCreate(name="identify_root_cause", description="Phase 5: 歸納根因（版本錯亂 / hook 誤觸 / 權限 / 格式）")
TaskCreate(name="propose_fix", description="Phase 6: 列出修復步驟，建議用 plugin-update 或手動處理")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

**為什麼強制**：debug 是探索性流程，很容易跳步驟「直接看 hook」忽略版本問題。Task list 強迫走完每個 phase，避免誤判根因。

---

## Phase 1: 鎖定目標

### Step 1: 確定 Plugin

如果用戶指定了 plugin 名稱，直接使用。否則詢問。

### Step 2: 找到所有相關路徑

```bash
# 源碼路徑（marketplace repo）
PLUGIN_NAME="{plugin_name}"

source "${CLAUDE_PLUGIN_ROOT:?}/scripts/resolve-marketplace.sh"

# 自動找出這個 plugin 屬於哪個 marketplace（不要假設是 psychquant）
IFS="|" read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$(find_plugin_marketplace "$PLUGIN_NAME")"
# 找不到就停：空的 SRC 會讓下面的 diff -r 印「No skills to diff」——把「讀不到源碼」講成「沒差異」，
# 對一個 debug 工具是最壞的假陰性（#18 R1）。其餘硬編路徑見 #23。
[ -n "${PLUGIN_DIR:-}" ] && [ -d "$PLUGIN_DIR" ] || { echo "✗ plugin '$PLUGIN_NAME' 不在任何已註冊的 marketplace（find_plugin_marketplace 無命中）" >&2; exit 1; }
SRC="$PLUGIN_DIR"   # manifest plugins[].source 解析結果（#18）；別再組 plugins/<name>

# cache 路徑（可能有多個版本）
ls -la ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/ 2>/dev/null

# che-local-plugins（舊文件寫的 Dropbox 路徑已不存在，實體在 ~/Developer）
SRC_LOCAL="$(resolve_marketplace_root che-local-plugins)/plugins/$PLUGIN_NAME"
ls "$SRC_LOCAL" 2>/dev/null
```

---

## Phase 2: 版本一致性

### Step 1: 比對源碼 vs Cache

```bash
# 源碼版本
cat "$SRC/.claude-plugin/plugin.json" | jq -r '.version'

# Cache 裡有哪些版本
ls ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/

# 當前啟用的版本
claude plugin list 2>&1 | grep -A3 "$PLUGIN_NAME"
```

### Step 2: Diff 源碼 vs Cache

最常見的 bug：源碼改了但 cache 沒更新。

```bash
# 找到 cache 裡最新版本的路徑
CACHE_VER=$(ls ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/ | sort -V | tail -1)
CACHE="$HOME/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/$CACHE_VER"

# Diff hooks
diff "$SRC/hooks/hooks.json" "$CACHE/hooks/hooks.json" 2>/dev/null || echo "No hooks to diff"

# Diff skills
diff -r "$SRC/skills/" "$CACHE/skills/" 2>/dev/null || echo "No skills to diff"

# Diff commands
diff -r "$SRC/commands/" "$CACHE/commands/" 2>/dev/null || echo "No commands to diff"
```

如果有差異 → 告知用戶需要 `/plugin-update` 同步。

### Step 3: 檢查舊版本殘留

```bash
# 列出所有 cached 版本
ls ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/

# 如果有多個版本，檢查是否舊版的 hook 仍在運作
for ver in $(ls ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/); do
  echo "=== v$ver ==="
  cat ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/$ver/hooks/hooks.json 2>/dev/null | jq -r '.hooks | keys[]' 2>/dev/null || echo "(no hooks)"
done
```

**已知問題**：舊版本 cache 不會自動清除，舊版的 hooks 可能仍在生效。

---

## Phase 3: Hook 行為分析

### Step 1: 列出所有 Hook Events

```bash
cat "$CACHE/hooks/hooks.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for event, entries in d.get('hooks', {}).items():
    for i, entry in enumerate(entries):
        matcher = entry.get('matcher', '(all)')
        hooks = entry.get('hooks', [])
        for j, h in enumerate(hooks):
            cmd = h.get('command', '(no command)')
            # 截斷過長的命令
            if len(cmd) > 120:
                cmd = cmd[:120] + '...'
            print(f'{event}[{i}].hooks[{j}] matcher={matcher}')
            print(f'  command: {cmd}')
"
```

### Step 2: 分析副作用

對每個 PostToolUse hook，分析可能的副作用：

| 模式 | 風險 | 說明 |
|------|------|------|
| `chflags -R uchg "$dir"` | **高** | 鎖定目錄本身，導致無法新增檔案 |
| `chflags uchg` (files only) | 低 | 只鎖檔案，目錄仍可寫入 |
| `find . -name 'archived'` | 中 | 可能匹配到非預期的路徑 |
| `chmod -R` | 中 | 可能改變不該改的權限 |

### Step 3: 模擬 Hook 執行

在安全環境中測試 hook 的實際行為：

```bash
# 建立測試目錄
TESTDIR=$(mktemp -d)
mkdir -p "$TESTDIR/archived"
touch "$TESTDIR/archived/old_file.txt"

# 模擬 PostToolUse hook 命令（從 hooks.json 提取）
cd "$TESTDIR"
# {貼上 hook 命令}

# 檢查結果
ls -lO "$TESTDIR/archived"      # 目錄本身的 flags
ls -lO "$TESTDIR/archived/"     # 檔案的 flags

# 測試能否新增檔案
touch "$TESTDIR/archived/new_file.txt" 2>&1

# 清理
chflags -R nouchg "$TESTDIR" 2>/dev/null
rm -rf "$TESTDIR"
```

---

## Phase 4: 檔案系統影響

### Step 1: 檢查 chflags 狀態

```bash
# 找到專案中所有 archived 目錄
find . -maxdepth 5 -type d -name 'archived' 2>/dev/null | while read dir; do
  echo "=== $dir ==="
  # 目錄本身
  ls -lOd "$dir"
  # 裡面的檔案
  ls -lO "$dir/" 2>/dev/null | head -10
done
```

### Step 2: 診斷 Operation not permitted

如果用戶遇到 `Operation not permitted`：

```bash
# 1. 檢查是否是 uchg flag
ls -lOd "{problem_path}"

# 2. 如果有 uchg，解鎖
chflags nouchg "{problem_path}"

# 3. 如果是 Dropbox 同步目錄，檢查 xattr
xattr -l "{problem_path}" | head -5
```

---

## Phase 5: 修復建議

根據發現的問題，提出修復方案：

### 問題：目錄被 uchg 鎖定無法寫入

**原因**：PostToolUse hook 用 `chflags -R uchg` 鎖了目錄本身。

**修復**：改為只鎖檔案，目錄保持可寫：
```bash
# 修復前
chflags -R uchg "$dir"

# 修復後
find "$dir" -type f -exec chflags uchg {} + 2>/dev/null
chflags nouchg "$dir" 2>/dev/null
```

### 問題：舊版 cache 的 hook 仍在生效

**修復**：
```bash
# 移除舊版 cache
rm -rf ~/.claude/plugins/cache/psychquant-claude-plugins/$PLUGIN_NAME/{old_version}

# 重新安裝
claude plugin update $PLUGIN_NAME@psychquant-claude-plugins
```

### 問題：源碼已修但 cache 沒同步

**修復**：執行 `/plugin-update {plugin_name}`

---

## 輸出格式

```markdown
# Plugin Debug Report: {plugin_name}

## 版本狀態
| 位置 | 版本 | 備註 |
|------|------|------|
| 源碼 | v{x} | {path} |
| Cache | v{y} | {有幾個版本} |
| 啟用中 | v{z} | {status} |

## 發現的問題

### 1. {問題描述}
- **症狀**: {用戶看到什麼}
- **根因**: {技術原因}
- **影響範圍**: {哪些目錄/檔案受影響}
- **修復方案**: {具體步驟}

## 建議動作
1. {action}
2. {action}
```
