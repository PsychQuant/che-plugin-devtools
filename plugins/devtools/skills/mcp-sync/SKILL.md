---
name: mcp-sync
description: 同步 MCP Binary（.build → mcpb/server → ~/bin 一致性檢查和修復）
argument-hint: [--check-only]
allowed-tools: Read, Bash(swift:*), Bash(lipo:*), Bash(file:*), Bash(shasum:*), Bash(cp:*), Bash(rm:*), Bash(ls:*), Bash(chmod:*), Bash(mkdir:*), Bash(grep:*), Bash(cat:*), Bash(zip:*), Bash(unzip:*), Bash(codesign:*), Grep, Glob, AskUserQuestion
disable-model-invocation: true
---

# MCPB Sync - Binary 一致性同步

確保 MCP 專案的三個 binary 副本保持一致。

**只適用 Swift 專案**（Python/TS 使用 wrapper script，不需要 binary 同步）

## 同步方向（Source of Truth）

```
.build/arm64 + .build/x86_64
        │ (lipo -create + codesign)
        ▼
  mcpb/server/{Binary}  [universal, signed]
        │ (cp + codesign)
        ▼
    ~/bin/{Binary}  [universal, signed]
```

## 參數

- `$1` = `--check-only`（可選）— 只檢查不同步

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="detect_project", description="Phase 0: 確認 MCP 專案 + 取 binary 名 + 偵測三位置 binary")
TaskCreate(name="consistency_check", description="Phase 1: hash + 架構比對 + 輸出一致性報告")
TaskCreate(name="execute_sync", description="Phase 2: 從 source of truth 同步到其他位置")
TaskCreate(name="repackage_mcpb", description="Phase 2.5: 刪舊 .mcpb + 重新打包 + 驗證")
TaskCreate(name="post_sync_verify", description="Phase 3: 最終驗證")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 偵測專案

### Step 1: 確認在 MCP 專案目錄

```bash
pwd
ls -la Package.swift mcpb/manifest.json 2>/dev/null
```

**必須存在**：
- `Package.swift`（Swift 專案）
- `mcpb/manifest.json`

如果不是 Swift 專案（沒有 Package.swift），輸出：
> ⏭️ 非 Swift 專案，不需要 binary 同步。Python/TS 使用 wrapper script。

並結束。

### Step 2: 取得 Binary 名稱

```bash
BINARY_NAME=$(grep -A5 'executableTarget' Package.swift | grep 'name:' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
echo "Binary: $BINARY_NAME"
```

### Step 3: 偵測三個位置的 binary

```bash
# 位置 1: .build/release (可能有多個架構)
ls -la .build/arm64-apple-macosx/release/$BINARY_NAME 2>/dev/null
ls -la .build/x86_64-apple-macosx/release/$BINARY_NAME 2>/dev/null
ls -la .build/release/$BINARY_NAME 2>/dev/null

# 位置 2: mcpb/server
ls -la mcpb/server/$BINARY_NAME 2>/dev/null

# 位置 3: ~/bin
ls -la ~/bin/$BINARY_NAME 2>/dev/null
```

記錄哪些位置存在 binary。

---

## Phase 1: 一致性檢查

### Step 1: 取得各位置的 hash 和架構

對每個存在的 binary 執行：

```bash
# mcpb/server
shasum -a 256 mcpb/server/$BINARY_NAME 2>/dev/null
file mcpb/server/$BINARY_NAME 2>/dev/null
lipo -info mcpb/server/$BINARY_NAME 2>/dev/null

# ~/bin
shasum -a 256 ~/bin/$BINARY_NAME 2>/dev/null
file ~/bin/$BINARY_NAME 2>/dev/null
lipo -info ~/bin/$BINARY_NAME 2>/dev/null
```

### Step 2: Architecture-aware 比對

**情況 A — mcpb/server 和 ~/bin 都是 universal**：
- 直接比對 hash → 相同 = 一致

**情況 B — mcpb/server 是 universal，~/bin 是 single-arch (arm64)**：
- 從 mcpb/server 提取 arm64 slice 比對：

```bash
TMPFILE="/tmp/_mcpb_sync_arm64_$$"
lipo -thin arm64 mcpb/server/$BINARY_NAME -output "$TMPFILE"
shasum -a 256 "$TMPFILE" ~/bin/$BINARY_NAME
rm -f "$TMPFILE"
```

**情況 C — 其中一個不存在**：
- 標記為「不一致：缺少」

### Step 3: 比對 .build 和 mcpb/server

如果 .build/arm64 和 .build/x86_64 都存在：

```bash
# 合併後與 mcpb/server 比對
TMPFILE="/tmp/_mcpb_sync_universal_$$"
lipo -create \
    .build/arm64-apple-macosx/release/$BINARY_NAME \
    .build/x86_64-apple-macosx/release/$BINARY_NAME \
    -output "$TMPFILE"
shasum -a 256 "$TMPFILE" mcpb/server/$BINARY_NAME
rm -f "$TMPFILE"
```

如果只有一個架構（如只有 arm64）：
- 從 mcpb/server 提取該架構的 slice 比對

### Step 4: 輸出一致性報告

```markdown
## Binary 一致性檢查

Binary: {BINARY_NAME}
專案: {project-name}

| 位置 | 存在 | 架構 | Hash (SHA-256 前 12 碼) | 狀態 |
|------|------|------|------------------------|------|
| .build/arm64 | ✅/❌ | arm64 | abc123... | - |
| .build/x86_64 | ✅/❌ | x86_64 | def456... | - |
| mcpb/server | ✅/❌ | universal/arm64 | ghi789... | ✅/⚠️ |
| ~/bin | ✅/❌ | universal/arm64 | ghi789.../xxx... | ✅/❌ |

### 比對結果
- .build → mcpb/server: ✅ 一致 / ❌ 不一致 / ⚠️ .build 較新
- mcpb/server → ~/bin: ✅ 一致 / ❌ 不一致
```

如果 `$1` 是 `--check-only`，到此結束。

---

## Phase 2: 執行同步

如果有任何不一致，使用 AskUserQuestion 詢問同步方式：

**選項**：

1. **從 .build 重建**（推薦，如果 .build 存在）
   - 用 .build 的兩個架構 lipo 合併到 mcpb/server
   - 再複製到 ~/bin

2. **只複製 mcpb/server → ~/bin**
   - mcpb/server 有正確的 universal binary
   - 只需同步到 ~/bin

3. **完整重編譯**
   - `swift build -c release --arch arm64`
   - `swift build -c release --arch x86_64`
   - lipo 合併到 mcpb/server
   - 複製到 ~/bin

4. **取消**

### 選項 1: 從 .build 重建

```bash
# 合併 universal binary
lipo -create \
    .build/arm64-apple-macosx/release/$BINARY_NAME \
    .build/x86_64-apple-macosx/release/$BINARY_NAME \
    -output mcpb/server/$BINARY_NAME

# 重新簽名（lipo 會破壞原始 code signature）
codesign --force --sign - mcpb/server/$BINARY_NAME

# 複製到 ~/bin
cp mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
codesign --force --sign - ~/bin/$BINARY_NAME
```

### 選項 2: mcpb/server → ~/bin

```bash
cp mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
codesign --force --sign - ~/bin/$BINARY_NAME
```

### 選項 3: 完整重編譯

```bash
# 清理
rm -rf .build 2>/dev/null || true

# 編譯兩個架構
swift build -c release --arch arm64
swift build -c release --arch x86_64

# 合併
lipo -create \
    .build/arm64-apple-macosx/release/$BINARY_NAME \
    .build/x86_64-apple-macosx/release/$BINARY_NAME \
    -output mcpb/server/$BINARY_NAME

# 重新簽名（lipo 會破壞原始 code signature）
codesign --force --sign - mcpb/server/$BINARY_NAME

# 複製到 ~/bin
cp mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
codesign --force --sign - ~/bin/$BINARY_NAME
```

> **重要**：`lipo -create` 和 `cp` 都會破壞 macOS code signature。
> 未簽名的 binary 會被 macOS runtime enforcement 以 SIGKILL (exit 137) 終止。
> 每次 lipo/cp 後必須執行 `codesign --force --sign -` 重新 ad-hoc 簽名。

---

## Phase 2.5: 重新打包 .mcpb

mcpb/server 的 binary 已更新，必須重新打包 `.mcpb` 以保持一致。

### Step 1: 刪除舊的 .mcpb

```bash
rm -f mcpb/*.mcpb 2>/dev/null || true
```

### Step 2: 重新打包

```bash
PROJECT_NAME=$(cat mcpb/manifest.json | grep '"name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | tr -d ' ')
cd mcpb && zip -r ${PROJECT_NAME}.mcpb . -x ".*" -x "*.mcpb" && cd ..
```

### Step 3: 驗證套件

```bash
ls -lh mcpb/*.mcpb
unzip -l mcpb/*.mcpb | head -10
```

---

## Phase 3: Post-sync 驗證

### Step 1: Hash 驗證

```bash
echo "=== Post-sync Verification ==="
shasum -a 256 mcpb/server/$BINARY_NAME ~/bin/$BINARY_NAME
```

兩者 hash 必須完全一致。

### Step 2: 架構驗證

```bash
echo "=== mcpb/server ==="
file mcpb/server/$BINARY_NAME
lipo -info mcpb/server/$BINARY_NAME

echo "=== ~/bin ==="
file ~/bin/$BINARY_NAME
lipo -info ~/bin/$BINARY_NAME
```

### Step 3: 清理暫存檔

```bash
rm -f /tmp/_mcpb_sync_* 2>/dev/null
```

---

## Phase 4: 完成報告

```markdown
# MCPB Sync 完成

## 專案資訊
- 專案: {project-name}
- Binary: {BINARY_NAME}

## 同步結果

| 位置 | 架構 | Hash (前 12 碼) | 狀態 |
|------|------|-----------------|------|
| mcpb/server/{Binary} | universal (arm64 + x86_64) | abc123... | ✅ |
| ~/bin/{Binary} | universal (arm64 + x86_64) | abc123... | ✅ |

## MCPB 套件
- 已重新打包: mcpb/{project-name}.mcpb

## Binary Consistency: ✅ 全部一致
```

---

## 快速參考

### 常見情況

| 情況 | 建議操作 |
|------|----------|
| 剛 `swift build` 但沒 deploy | 選項 1（從 .build 重建） |
| deploy 後 ~/bin 不一致 | 選項 2（mcpb → ~/bin） |
| 不確定 .build 是否最新 | 選項 3（完整重編譯） |
| 只想確認狀態 | `--check-only` |

### MCP Server 對應表

| MCP Server | Binary 名稱 |
|------------|------------|
| che-things-mcp | CheThingsMCP |
| che-ical-mcp | CheICalMCP |
| che-apple-mail-mcp | CheAppleMailMCP |
| che-word-mcp | CheWordMCP |
| che-duckdb-mcp | CheDuckDBMCP |
| che-blender-mcp | CheBlenderMCP |
| che-logic-pro-mcp | CheLogicProMCP |
| che-claude-desktop-mcp | CheClaudeDesktopMCP |
