---
name: cli-upgrade
description: |
  掃描 ~/bin/ 的 CLI binary、比對各自 GitHub Release 的最新版，有新版就備份舊版（.bak）後下載升級並驗證。可指定單一工具或全部掃描。
  Use when: 想知道手上的 CLI 有沒有新版；某工具行為怪怪的、想先排除「其實是舊版」；「升級 gfh」「CLI 有更新嗎」「check for updates」。
  防止的失敗：一直用舊版而不自知（CLI 不像 plugin 會主動提示更新）；手動覆蓋 binary 後發現新版有問題，卻沒有舊版可回退。
argument-hint: [binary-name]
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
---

# CLI Upgrade — 升級已安裝的 CLI 工具

檢查 `~/bin/` 中的 CLI 工具是否有 GitHub Release 新版本，並升級。

## 參數

- `$1` = Binary 名稱（可選，不指定則掃描全部已知的 CLI）

---

## Phase 0: 識別已安裝的 CLI 工具

### 已知的 CLI 工具對照表

自動偵測：掃描 `~/bin/` 中的 binary，嘗試執行 `{binary} version` 取得版本號，並對應到 GitHub repo。

| Binary | GitHub Repo | 偵測方式 |
|--------|-------------|---------|
| gfh | PsychQuant/GiftHub | `gfh version` |

**動態偵測**：對 `~/bin/` 中每個可執行檔：

1. 嘗試 `{binary} version 2>/dev/null` 或 `{binary} --version 2>/dev/null`
2. 如果有版本輸出，用 `gh api` 搜尋對應的 repo（by binary name）

如果指定了 `$1`，只檢查那一個。

---

## Phase 1: 檢查更新

對每個已知的 CLI 工具：

```bash
LOCAL_VERSION=$($BINARY version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
LATEST_VERSION=$(curl -fsSL --max-time 5 "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
```

### 比較版本

- 相同 → `✓ {binary} v{version} — up to date`
- 不同 → `⬆️ {binary} v{local} → v{latest} available`
- 無法取得 → `? {binary} — cannot check (no repo mapping)`

---

## Phase 2: 升級

如果有更新可用，用 AskUserQuestion 確認：

> 以下工具有新版本：
> - gfh v0.1.0 → v0.2.0
>
> 要全部升級嗎？

確認後：

```bash
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep "browser_download_url.*$BINARY_NAME" | grep -oE 'https://[^"]+')

# 備份舊版
cp ~/bin/$BINARY_NAME ~/bin/$BINARY_NAME.bak

# 下載新版
curl -fsSL "$DOWNLOAD_URL" -o ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME
xattr -cr ~/bin/$BINARY_NAME 2>/dev/null || true

# 驗證
NEW_VERSION=$(~/bin/$BINARY_NAME version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "✓ $BINARY_NAME upgraded to v$NEW_VERSION"

# 清理備份
rm ~/bin/$BINARY_NAME.bak
```

---

## Phase 3: 報告

```
# CLI Upgrade Report

| Binary | Before | After | Status |
|--------|--------|-------|--------|
| gfh    | v0.1.0 | v0.2.0 | ✓ upgraded |
| other  | v1.0.0 | v1.0.0 | — up to date |
```
