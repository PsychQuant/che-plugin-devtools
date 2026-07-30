---
name: cli-install
description: 從 GitHub Release 安裝 CLI 工具到 ~/bin/（下載 binary、設定權限、驗證）
argument-hint: <owner/repo> [version]
allowed-tools: Bash, Read, AskUserQuestion
---

# CLI Install — 從 GitHub Release 安裝

從 GitHub Release 下載 CLI binary 並安裝到 `~/bin/`。

## 參數

- `$1` = GitHub repo（如 `PsychQuant/GiftHub`）
- `$2` = 版本號（可選，預設 `latest`）

---

## Phase 0: 解析參數

如果沒有提供 repo，用 AskUserQuestion 詢問。

```bash
REPO="{owner/repo}"
VERSION="${2:-latest}"
```

---

## Phase 1: 取得 Release 資訊

### Latest 版本

```bash
RELEASE_INFO=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
TAG=$(echo "$RELEASE_INFO" | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
```

### 指定版本

```bash
RELEASE_INFO=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/v$VERSION")
```

### 列出 Assets

```bash
echo "$RELEASE_INFO" | grep '"name"' | head -10
```

找到 binary asset（排除 `.mcpb`、`.zip`、`.tar.gz`）。
如果有多個 binary，用 AskUserQuestion 讓使用者選。

---

## Phase 2: 下載與安裝

```bash
BINARY_NAME="{detected-binary-name}"
DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep "browser_download_url.*$BINARY_NAME" | grep -oE 'https://[^"]+')

mkdir -p ~/bin
curl -fsSL "$DOWNLOAD_URL" -o ~/bin/$BINARY_NAME
chmod +x ~/bin/$BINARY_NAME

# macOS: 清除 quarantine flag
xattr -cr ~/bin/$BINARY_NAME 2>/dev/null || true
```

---

## Phase 3: 驗證

```bash
file ~/bin/$BINARY_NAME
~/bin/$BINARY_NAME version 2>/dev/null || ~/bin/$BINARY_NAME --version 2>/dev/null
```

---

## 完成報告

```
已安裝 {binary-name} {version} 到 ~/bin/
來源: https://github.com/{owner}/{repo}/releases/tag/{tag}
```
