# 2026-07-30 — marketplace 建立與工具鏈遷入

從 `psychquant-claude-plugins`（基準 `cfb8849`）與 `che-claude-config/che-local-plugins`
遷出 plugin 開發工具鏈，成立獨立 marketplace。

## 結果

| Repo | 變化 |
|---|---|
| `che-plugin-devtools` | 新建，2 plugins |
| `psychquant-claude-plugins` | 32 → 28 plugins |
| `che-local-plugins` | 8 → 7 plugins |

| Plugin | 版本 | 來源 |
|---|---|---|
| `devtools` | 1.0.0 | plugin-tools 1.18.0 + mcp-tools 1.16.0 + cli-tools 1.1.2 |
| `doc-guardian` | 2.0.0 | doc-tools 0.2.0 + doc-guardian 1.0.2 |

## 為什麼切成這兩個

邊界由實測 call graph 決定，不是主觀分類。

`plugin-tools` / `mcp-tools` / `cli-tools` 形成循環依賴（`plugin-tools` ↔ `mcp-tools` 雙向，
`mcp-deploy` 一支就被跨 plugin 引用 19 次），而 Claude Code **沒有 plugin 依賴宣告機制**
（掃過全部 32 個 `plugin.json`，零個有 `dependencies` 欄位）。只裝其中一個時，
`plugin-update` 的 dependency-aware orchestration 會在呼叫缺席 skill 時靜默斷裂且無警告。
「可選擇性安裝」在該 call graph 下是假選項——能選，但選了會壞。

`doc-tools` 是 0 跨呼叫，真正獨立，故不併入。

## 修掉的兩個 live bug

**double-fire** — `doc-tools` 的 `doc-update-guard.sh` 與 `doc-guardian` 1.0.2 的
`changelog-update.sh` 是同一檢查的兩份實作，`settings.json` 中兩個 plugin 皆 enabled，
每次 Stop 都跑兩遍。doc-tools 0.2.0 宣稱已解，但它移除的是 user-level hook，
plugin 版本仍在。本次只保留一支。

**bash 3.2 nameref** — `doc-update-config.sh` 的 `_merge_config()` 用 `local -n`
（bash 4.3+），macOS 是 `/bin/bash` 3.2.57。因 `set -u` 而無 `set -e`，報錯後繼續執行，
導致 `code_extensions` / `doc_files` 兩個設定寫了也不生效，且每次觸發往 stderr 噴錯。
改用空格分隔字串傳遞，全面 3.2 相容。

## 順帶修掉的既有缺陷

- 5 處硬編碼 marketplace 路徑 → `scripts/resolve-marketplace.sh`（單一來源 + 11 個單元測試）
- `che-local-plugins` 的 Dropbox 路徑早已不存在（實體在 `~/Developer/che-claude-config`）
- `plugin-create/SKILL.md` 三處把自己寫成 `/plugin-tools:create-plugin`，名稱順序顛倒、該指令不存在
- README 的 mcp-tools 段落列的 skill 名是舊的（`diagnose` / `new-mcp-app` 實際為 `mcp-diagnose` / `mcp-new-app`）
- 遺漏後補：`doc-guardian/.codex-plugin/plugin.json`（`b02564c`）

## 刻意保留

`rules/tool-readme-sync-{plugin,mcp,cli}.md` 三份 drift（md5 各異）改檔名並存、
內容逐位元不變，其中一處硬編碼路徑一併留著。合併需逐條判斷哪些差異是刻意的，
屬內容判斷而非搬家；保持位元不變才能用 `md5` 證明「rules 沒被動過」——
這是本次遷移唯一的客觀正確性證據。已開 issue #1 追蹤。

## 驗證

- `test-resolve-marketplace.sh` 11/11、`test-doc-update-config.sh` 20/20
- `claude plugin validate` 兩個 plugin 皆通過
- `validate-changelog.py` 三方同步 exit=0（dogfooding：doc-guardian 驗自己）
- 三份 rules md5 從來源 → repo → GitHub → cache 全程逐位元相同

## 後續

| Issue | 內容 |
|---|---|
| #1 | 統一三份 drift 的 tool-readme-sync（含遺留硬編碼）|
| #2 | 11 處引用不存在的 MCP 專案目錄，需先定組織原則 |
| #3 | `validate-changelog.py` 的 `--marketplace` 參數 UX |

完整設計：`psychquant-claude-plugins/docs/superpowers/specs/2026-07-30-che-plugin-devtools-migration-design.md`
