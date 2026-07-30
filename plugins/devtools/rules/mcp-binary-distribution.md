# MCP Binary Distribution via GitHub Releases

當 MCP Server 是編譯型 binary（Swift、Rust、Go…），**必須**走 GitHub Release + wrapper 自動下載，讓 plugin 版本升級 = binary 自動更新。

## 為什麼

| 現象 | 後果 |
|------|------|
| Binary 手動編譯 + 手動 copy | 修了 bug，使用者不會收到 |
| Plugin 版本 bump 只更新 wrapper，binary 保持舊版 | 新功能宣稱了但跑不出來 |
| Wrapper 只找本地 binary，不會 fallback 下載 | 使用者 clone repo + `swift build` 才能用 |

IDD 的 `#3 → #4 → close` 跑完後，bug 已修、版本已 bump、文件已更新——但使用者端的 binary 還是舊版。這層斷裂是**自動化鏈的最後一哩**。

## 三個必備元件

### 1. GitHub Actions — 發 release 時自動編譯 binary

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: macos-14  # 或對應平台
    steps:
      - uses: actions/checkout@v4
      - name: Build release binary
        run: swift build -c release --product MyMCPBinary
      - name: Upload to release
        uses: softprops/action-gh-release@v2
        with:
          files: .build/release/MyMCPBinary
```

**觸發條件**：push `v*` tag（例如 `git tag v0.5.0 && git push --tags`）。

### 2. GitHub Release — binary 當 asset

Binary 必須是 release asset 而非 git-committed（太大、會撐爆 repo）。命名用 **純檔名**（`CheTelegramAllMCP`），不要加版本字尾——wrapper 下載後就是這個名字。

```bash
# 手動發 release（CI 尚未設好時）
gh release create v0.4.1 \
  --repo owner/repo \
  --title "v0.4.1 — get_chat_history fixes" \
  --notes "See CHANGELOG.md" \
  .build/release/MyMCPBinary
```

### 3. Wrapper 自動下載邏輯

參考 `che-telegram-bot-mcp-wrapper.sh`（實戰範本）：

```bash
#!/bin/bash
BINARY_NAME="MyMCPBinary"
GITHUB_REPO="owner/repo"
INSTALL_DIR="$HOME/bin"

# Step 1: 找 binary（多個可能路徑）
BINARY=""
for loc in "$INSTALL_DIR/$BINARY_NAME" "/usr/local/bin/$BINARY_NAME" \
           "$HOME/Developer/repo/.build/release/$BINARY_NAME"; do
    [[ -x "$loc" ]] && BINARY="$loc" && break
done

# Step 2: 找不到 → 從 GitHub Release 下載
if [[ -z "$BINARY" ]]; then
    echo "$BINARY_NAME not found. Downloading from GitHub..." >&2
    mkdir -p "$INSTALL_DIR"
    URL=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
        | grep '"browser_download_url"' | grep "$BINARY_NAME" | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/')
    if [[ -n "$URL" ]]; then
        curl -sL "$URL" -o "$INSTALL_DIR/$BINARY_NAME" \
            && chmod +x "$INSTALL_DIR/$BINARY_NAME" \
            || { echo "ERROR: Download failed." >&2; exit 1; }
        BINARY="$INSTALL_DIR/$BINARY_NAME"
    else
        # Fallback：教使用者從 source 編譯
        echo "No release found. Build from source:" >&2
        echo "  git clone https://github.com/$GITHUB_REPO.git" >&2
        echo "  cd repo && swift build -c release" >&2
        exit 1
    fi
fi

exec "$BINARY" "$@"
```

## 陷阱與對策

### 1. 同名新舊 binary 混淆

Wrapper 的「找本地 binary」邏輯若命中 `$HOME/Developer/.../release/` 的舊 build，會跑到舊版。

**對策**：

| 做法 | 適用情境 |
|------|---------|
| `$HOME/bin/$BINARY_NAME` 放最優先 | 一般使用者（下載的 release）|
| Binary 支援 `--version` | 可以讓 wrapper 比對版本決定是否重新下載 |
| 明確告知使用者 clear cache | `rm ~/bin/$BINARY_NAME` 強制重下載 |

### 2. 大型 binary（含 framework）

像 TDLib（~100 MB）這種 binary，release asset 可行（GitHub 限制 2 GB），但下載慢。

**對策**：
- 考慮分 framework 和 binary（framework 另外壓 `.tar.gz`）
- CI build + `strip` 減小 binary 大小
- 加 checksum 驗證（release notes 附 `shasum -a 256`）

### 3. 平台差異

MCP binary 常是 macOS only（Swift + AppleScript）或 cross-platform。

**對策**：

| 情境 | 做法 |
|------|------|
| macOS only | Asset 名稱不加平台，wrapper 檢查 `uname -s` |
| Multi-platform | 上傳多個 asset（`-macos-arm64`、`-linux-x64`），wrapper 依 `uname` 選 |
| 單一平台但多架構 | `lipo -create` 做 universal binary，一個 asset 就夠 |

### 4. Code signing / notarization

macOS binary 未簽章會被 Gatekeeper 擋。

**對策**：
- 簡單方案：wrapper 下載後自動 `xattr -dr com.apple.quarantine`
- 正規方案：CI 用 Apple Developer certificate 簽章 + notarize（需付費帳號）

## 何時不適用

| 情境 | 為何跳過這個 rule |
|------|------------------|
| Python / Node MCP（純 script） | 沒有 binary，plugin 直接帶 source |
| Binary < 5 MB 且 platform-specific | 直接 commit 到 plugin repo 也 OK |
| 內部使用、單一使用者 | 手動 rebuild 可接受 |

## 檢查清單

發布 binary-based MCP 前，確認：

- [ ] GitHub Actions 在 tag push 時 build binary
- [ ] Release workflow 上傳 binary 當 asset
- [ ] Wrapper 有「找不到本地 → 下載 release」fallback
- [ ] Wrapper 把 `~/bin/` 放最高優先搜尋路徑
- [ ] README 有說明 `--version` 和手動更新方式
- [ ] Binary release 附 checksum（`.sha256` 或 release notes 裡）

## plugin-deploy ↔ mcp-deploy 依賴關係

Binary-based MCP 的 deploy 有兩個 repo 要同步：

```
MCP source repo (e.g. che-msg)              Plugin marketplace repo
        │                                       │
        ├─ Source code                          ├─ bin/wrapper.sh (引用 binary)
        └─ mcp-deploy                           └─ plugin-deploy
              │                                       │
              ├─ Build binary                        ├─ Bump plugin.json version
              ├─ Create GitHub Release              ├─ Update marketplace.json
              └─ Phase 4: bump plugin (opt-in) ──► └─ 使用者裝了就拿到新 binary
                      ↑
                      └── 如果跳過 Phase 4，plugin-deploy 必須 block
```

### 正確順序

| 場景 | 順序 |
|------|------|
| **只改 MCP code（修 bug、加 tool）** | `mcp-deploy` → Phase 4 opt-in → plugin 自動 bump |
| **只改 plugin shell（wrapper、skill、agent）** | `plugin-deploy` 即可，binary 不需動 |
| **同時改兩邊** | 先 `mcp-deploy` 發 release，再 `plugin-deploy` |

### Deploy skill 的 cross-check

`plugin-tools:plugin-deploy` 的 **Step 2.5 MCP Binary Check** 會：

1. 偵測 plugin 是否含 `.mcp.json`
2. 掃 `bin/*-wrapper.sh` 抓 `BINARY_NAME` + `GITHUB_REPO`
3. 查該 repo 的 latest release 有沒有對應 asset
4. **沒有 → 直接 block，要求先跑 `/devtools:mcp-deploy`**
5. **有 → AskUserQuestion 確認是最新 source code 的版本**

為什麼是 block 而非 warn：

| 狀況 | 後果 |
|------|------|
| Release 沒 binary | 使用者裝新 plugin → wrapper auto-download 失敗 → plugin 完全壞掉 |
| Release 有但過時 | 使用者跑舊 binary → 新功能用不到（silent failure）|

第一種是使用者立刻發現的 hard failure，必須 block；第二種只能靠 trust + AskUserQuestion。

## 擴展: 非 MCP 的 CLI-dependent plugin

同樣的 dependency graph 也適用於不是 MCP 但依賴 CLI binary 的 plugin（例：[gifthub](../../gifthub) → `~/bin/gfh`）。

### 訊號判斷

| 訊號 | 意義 |
|------|------|
| `.mcp.json` 存在 | MCP plugin（走 mcp-tools 流程）|
| `hooks/session-start.sh` curl `api.github.com/releases` | CLI-dependent plugin（走 cli-tools 流程）|
| Skill 引用 `~/bin/$BINARY` 但無 `.mcp.json` | CLI-dependent plugin |

### 三邊 ↔ 整合

```
MCP source repo               Plugin marketplace            CLI binary repo
   (che-msg)                  (psychquant-plugins)           (GiftHub)
      │                              │                           │
      ├─ mcp-deploy                  ├─ plugin-deploy            ├─ cli-deploy
      │  (build+release              │  (Step 2.5 checks MCP)    │  (release binary)
      │   + Phase 4 bump plugin)     │                           │
      │                              ├─ plugin-update            └─ cli-install / cli-upgrade
      └────── binary ready ─────────►│  (Phase 1.5 checks both   ◄─── binary ready
                                     │   MCP and CLI, warn only)
```

### plugin-update Phase 1.5 的行為

| 依賴類型 | 檢查 | 發現不同步 |
|---------|------|-----------|
| MCP | wrapper 引用的 binary 在 GitHub Release 裡 | **AskUserQuestion** → 選「順便更新」時自動呼叫 `/devtools:mcp-deploy` |
| CLI | `~/bin/$BINARY version` vs latest release tag | **AskUserQuestion** → 選「順便更新」時自動呼叫 `/devtools:cli-upgrade $BINARY` |
| 無（純 skill/rule） | 跳過 | — |

### 為什麼 plugin-update 是 ask-then-auto-sync、plugin-deploy 是 block

| Skill | 觸發頻率 | 行為 | 理由 |
|-------|---------|------|------|
| `plugin-deploy` | 偶爾（發版時）| **BLOCK** | Release 沒 binary = 新使用者裝 plugin 就壞，必須擋 |
| `plugin-update` | 頻繁（日常同步）| **ASK + AUTO-SYNC** | 日常同步時多數情境是想一次更新完整鏈，但要尊重「只改 shell 不動 binary」的選擇 |

Plugin-update 被定位為 **dependency-aware orchestrator**——偵測到底層 binary 也該更新時，主動觸發整條 chain，而不只是提醒。但保留使用者控制權：AskUserQuestion 三個選項（順便更新 / 只更新 shell / 中止）。
