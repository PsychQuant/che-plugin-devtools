---
name: skill-audit
description: 稽核並重寫本 repo 的 skill description 與 SKILL.md 篇幅。當你要檢查「哪些 skill 的 description 太短導致無法被自動觸發」、「哪些 SKILL.md 過長該拆 references/」、或要逐一重寫 skill 的觸發語時使用。也在新增 skill 後、發 release 前、或想知道 skill 品質現況時觸發。內建本 repo 的合格範本（plugin-* 與 doc-guardian 群組）與 skill-description-budget.md 的判準，附可機械複驗的稽核腳本。維護本 marketplace 用的工廠設備，不對外分發。
---

# skill-audit

稽核本 repo 的 skill 品質，並提供重寫時的標準與流程。

## 這支 skill 為什麼存在

`skill-creator`（已安裝的 plugin）會寫 skill，但它不知道**本 repo 的標準**：`skill-description-budget.md` 的判準、哪些既有 skill 是合格範本、目前有多少不合格。這支 skill 補的是那個缺口 —— 它薄，不重造 skill-creator 的輪子。

它是**工廠設備**，不是產品：只在維護這個 marketplace 時用，不隨 `harness-devtools` / `doc-guardian` 分發給使用者。放在 `.claude/skills/` 正是為此（判準見 repo 根 `CLAUDE.md`）。

## 先跑稽核

```bash
bash .claude/skills/skill-audit/scripts/audit-descriptions.sh
```

掃 `plugins/*/skills/*` 與 `.claude/skills/*`，輸出每個 skill 的 description 字元數、SKILL.md 行數、判定。exit code：`0` 全過 / `1` 有 findings / `2` 路徑錯。

機械消費用 `--format tsv`；只看單一目錄用 `--skills-root <dir>`。

改完 skill 後**重跑一次**確認判定翻轉 —— 這是這支 skill 唯一的客觀驗收。

## 核心事實：description 是唯一的觸發面

`plugins/harness-devtools/rules/skill-description-budget.md` 寫的關鍵推論：

> **description 是唯一的觸發面**。SKILL.md body 是**觸發之後**才載入的；描述沒進 listing = 模型看不到 = 只能靠名字觸發。

所以 29 字元的 description 不是「簡潔」，是**沒有觸發語**。使用者必須先知道 skill 叫什麼才用得到它 —— 等於自動觸發能力歸零，但不會被任何錯誤訊息提示。

這個失效模式跟該 rule 記載的血淚案例**方向相反**：那次是 description 太長（1,860 字）撐爆 listing budget 被砍成 name-only。兩端都會壞，中間那段才是可用區。

## 三個門檻

| 門檻 | 值 | 依據 |
|---|---:|---|
| `DESC_FLOOR` | 100 | 低於此無法容納任何觸發語 |
| `DESC_CAP` | 1536 | Claude Code per-entry truncation，超過尾巴被切 |
| `BODY_CEILING` | 500 | body 觸發後整份載入，超過應拆 `references/` |

**floor 是「不可用」的終點，不是「好」的起點。** 目標落在 **150–700** 這個帶 —— 本 repo 兩個健康群組就在這裡（`plugin-*` 中位數 166、`doc-guardian` 449）。

## 合格範本（不用外求，repo 內就有）

### 最完整的形態 — `doc-guardian` 群組

```yaml
description: 驗證 plugin 的 CHANGELOG.md 是否符合 Keep a Changelog 1.1.0 規範，並檢查三處同步（CHANGELOG.md latest entry ↔ plugin.json description ↔ marketplace.json description）。
Exit codes: 0 pass / 1 missing CHANGELOG / 2 KAC violation / 3 sync drift / 4 IO error。CI 友善。
Use when: 發 release 前檢查格式對不對；audit 一個 marketplace 的 CHANGELOG 健康度；改完 description 後驗 sync 沒漏。
防止的失敗：plugin.json 跟 CHANGELOG 版本不同步（marketplace 顯示舊版）；用了非 KAC section name；忘記寫日期。
```

四段結構：**做什麼** → **可觀察的輸出** → **Use when（觸發情境）** → **防止的失敗**。最後一段是最容易被略過、卻最有價值的 —— 它告訴模型「不用這支會出什麼事」，那正是判斷該不該觸發的依據。

### 較精簡但仍合格 — `plugin-*` 群組

```yaml
description: 檢查所有已安裝 plugin 的健康狀態（載入錯誤、版本不同步、hook 格式、腳本權限、MCP binary 缺失）。當用戶提到「plugin 有問題」、「plugin 載不出來」、「檢查 plugin 狀態」、「plugin failed to load」、「plugin 診斷」時使用。
```

兩段：**做什麼（含具體檢查項）** + **使用者會怎麼說**。列出真實語句比抽象描述有效 —— 模型比對的是使用者的實際措辭。

## YAML 格式鐵律：多行 description 一律用 block scalar

**這是本 skill 最容易犯、且失敗最安靜的一條。**

多行 description **必須**寫成 block scalar（`description: |` + 每行 2 空格縮排）：

```yaml
# ✓ 正確 —— block scalar
description: |
  做什麼的說明。
  Use when: 觸發情境。
  防止的失敗：後果。
```

```yaml
# ✗ 錯誤 —— 頂格續行，整份 frontmatter 解析失敗
description: 做什麼的說明。
Use when: 觸發情境。
防止的失敗：後果。
```

**為什麼錯的那個特別危險**：`Use when: text` 頂格其實是**合法** YAML（key 可含空格），單獨看不會炸。真正打爆 parser 的是下一行 `防止的失敗：` —— 全形冒號「：」不是 YAML 的分隔符，那行變成前一個 value 的續行，接著再遇到 `argument-hint:` 就報 `could not find expected ':' while scanning a simple key`。

也就是說：**failure 需要兩個條件疊加**（頂格半形 `key:` ＋ 全形冒號續行），而我們的 description 慣例恰好兩個都會用到。

**稽核腳本會抓**（`yaml` 欄位 = `invalid`，verdict 覆寫為 `yaml-invalid`，exit 1）。但別依賴它當唯一防線 —— 一開始就寫 block scalar。

## manual-only skill 不需要觸發語

`disable-model-invocation: true` 的 skill **永遠不會被模型自動觸發**，只能使用者打 `/<plugin>:<skill>`。對這類 skill：

- 寫 `Use when:` 觸發語 **對觸發毫無作用**
- description 的唯一功能是「讓人看懂它做什麼」
- 仍需過 100 字元 floor（說清楚做什麼本來就需要這個篇幅），但不必為了塞觸發詞而膨脹

稽核報表的 `invocation` 欄位會標出來（`manual` / `auto`）。本 repo 目前 `cli-deploy` 是 manual-only。

## 重寫流程

逐一處理，不批次亂改：

1. **跑稽核**拿到 undersized 清單，從最短的開始
2. **讀該 skill 的 SKILL.md body** —— 觸發語要從它實際會做的事提煉，不能憑名字猜
3. **看 `invocation` 欄位**：`manual` 則跳過觸發語，只求說清楚做什麼
4. **寫四段**：做什麼 / 可觀察輸出 / Use when / 防止的失敗。精簡群組可省第二、四段，但 auto-invocation 的 skill **Use when 不可省**
5. **用 block scalar**（見上方鐵律）
6. **檢查長度**落在 150–700
7. **重跑稽核**確認該列翻成 `ok` **且 `yaml` 欄位是 `valid`**
8. **bump 版本**：改的是 `plugins/<name>/` 底下的 skill → `plugin.json` 與 `marketplace.json` 版本必須同步 bump，否則 `claude plugin update` 判定 already-latest 而跳過（改 `.claude/skills/` 則不需要，project skills 有 live change detection）

## 觸發語怎麼寫才有效

| 寫法 | 效果 |
|---|---|
| 「用於 plugin 管理」 | ✗ 抽象，模型無從比對 |
| 「當用戶提到『plugin 載不出來』『plugin 診斷』時使用」 | ✓ 真實措辭，可直接比對 |
| 「處理文件相關工作」 | ✗ 範圍大到什麼都像、什麼都不像 |
| 「發 release 前檢查格式；audit marketplace 的 CHANGELOG 健康度」 | ✓ 具體情境 |

同時涵蓋**中文與英文**的觸發詞 —— 本 repo 的使用者兩種都會用。

## 拆 references/ 的時機

`BODY_CEILING=500` 量的是 **`prose_lines`（扣掉 code fence 的行數）**，不是原始行數。判準是**內容性質**：

- **留在 SKILL.md**：判準、流程、必讀紀律 —— 每次觸發都需要
- **移到 references/**：長表格、完整範例、歷史脈絡、邊界案例目錄 —— 需要時才讀

在 SKILL.md 用一行指出參照檔的內容與時機，模型才知道何時該去讀。

### 為什麼量 prose 而不是原始行數

**踩過的坑**：第一版用原始行數，5 個 skill 被標為需要拆分。實際看內容後全部撤銷：

| skill | 原始行數 | prose | fence 內容是什麼 |
|---|---:|---:|---|
| `plugin-update` | 980 | 448 | bash 操作步驟 |
| `mcp-deploy` | 914 | 437 | CHANGELOG / README / Release notes 樣板 |
| `mcp-publish` | 689 | 382 | server.json 範本 |
| `mcp-upgrade` | 510 | 306 | 分析用指令 |
| `mcp-new-app` | 672 | **191** | Package.swift / main.swift / Version.swift 範本 |

`mcp-new-app` 是極端案例：672 行裡 481 行是專案樣板 —— **那正是它要交付的產物**。把產物搬進 `references/` 不會讓 skill 變好，只會讓它每次執行都多讀一個檔案。

**所以：看到大檔案先問「這些行是說明還是產物」。** 說明超標才拆；產物超標是這支 skill 本來的樣子。稽核報表的 `body_lines` 與 `prose_lines` 並列就是為了讓這個區別一眼可見。

## 已知的 scope

稽核腳本涵蓋 `plugins/*/skills/*` 與 `.claude/skills/*`。後者包含 `spectra-*` —— 那些是 Spectra 專案的 skill，重寫前先確認是否會被上游更新覆蓋。

## Rules

- `plugins/harness-devtools/rules/skill-description-budget.md` —— listing budget 機制、`skillListingBudgetFraction` 設定、診斷 name-only 的方法
