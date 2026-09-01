# che-plugin-devtools

Claude Code plugin 開發工具鏈的獨立 marketplace。

## 安裝

```bash
claude plugin marketplace add PsychQuant/che-plugin-devtools
claude plugin install harness-devtools@che-plugin-devtools
claude plugin install doc-guardian@che-plugin-devtools
```

## Plugins

| Plugin | 版本 | 做什麼 |
|---|---|---|
| [`harness-devtools`](plugins/harness-devtools) | 2.1.0 | plugin / MCP server / Swift CLI 的完整發布管道（24 skills）|
| [`doc-guardian`](plugins/doc-guardian) | 2.0.2 | 文件紀律守門：CHANGELOG / README / CLAUDE.md / wiki 不准落後於 code（4 skills + 3 hooks）|

兩者互補：**harness-devtools 管「怎麼把東西發布出去」，doc-guardian 管「發布時文件要對」。**

## 為什麼是獨立 marketplace

原本這些工具住在 `psychquant-claude-plugins`，混在 30 個私人 MCP（Apple Mail、Telegram、Zotero、Things…）之間。想推薦「plugin 開發工具組」給別人時無從下手，而改一個 plugin 就要動一份 32 筆 entry 的 `marketplace.json`。

另外有個自我指涉問題：`plugin-tools` 管理的正是它自己所在的 marketplace——改它要用它來發布它自己。拆出來就切斷了這個迴圈。

## 為什麼 harness-devtools 是一個 plugin 而不是三個

前身 `plugin-tools` / `mcp-tools` / `cli-tools` 形成循環依賴（`plugin-tools` ↔ `mcp-tools` 雙向，`mcp-deploy` 被跨 plugin 引用 19 次），而 Claude Code **沒有 plugin 依賴宣告機制**。只裝其中一個，`plugin-update` 的 dependency-aware orchestration 會在呼叫缺席的 skill 時靜默斷裂。

「可選擇性安裝」在那個 call graph 下是假選項——能選，但選了會壞。所以合併成單一不可分割單元。`doc-guardian` 則是 0 跨呼叫，真正獨立，故保持分開。

完整設計討論見 [遷移設計文件](https://github.com/PsychQuant/psychquant-claude-plugins/blob/main/docs/superpowers/specs/2026-07-30-che-plugin-devtools-migration-design.md)。

## 開發

```bash
# 單元測試
bash    plugins/harness-devtools/scripts/test-resolve-marketplace.sh     # 28
bash    plugins/harness-devtools/scripts/test-check-skill-references.sh  # 15
bash    plugins/harness-devtools/scripts/test-resolve-mcp-project.sh     # 31
bash    plugins/doc-guardian/scripts/test-doc-update-config.sh           # 20
python3 plugins/doc-guardian/scripts/test-validate-changelog.py          # 11

# 引用完整性（文件裡的 /plugin:skill 是否都真的存在）
bash plugins/harness-devtools/scripts/check-skill-references.sh

# 結構驗證
claude plugin validate plugins/harness-devtools
claude plugin validate plugins/doc-guardian

# CHANGELOG 三方同步（dogfooding：用 doc-guardian 驗自己）
python3 plugins/doc-guardian/scripts/validate-changelog.py plugins/harness-devtools \
  --marketplace .
```

`--marketplace` 收 marketplace 根目錄或 `marketplace.json` 本身皆可。**省略它就只做兩方檢查**（CHANGELOG ↔ plugin.json），報告會標明 `2-way` 與 `marketplace.json NOT checked` —— 而 marketplace 版本落後正是最常漏掉的那一項。

改任何 plugin 都要同步 `plugins/<name>/.claude-plugin/plugin.json` 與 `.claude-plugin/marketplace.json` 的版本，否則 `claude plugin update` 會判定 already at latest 而跳過。

## History

遷移自 `psychquant-claude-plugins`（基準 commit `cfb8849`）。前身版本：`plugin-tools` 1.18.0、`mcp-tools` 1.16.0、`cli-tools` 1.1.2、`doc-tools` 0.2.0，以及 `che-local-plugins` 的 `doc-guardian` 1.0.2。
