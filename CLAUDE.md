<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra-*` skills when:

- A discussion needs structure before coding → `/spectra-discuss`
- User wants to plan, propose, or design a change → `/spectra-propose`
- Tasks are ready to implement → `/spectra-apply`
- There's an in-progress change to continue → `/spectra-ingest`
- User asks about specs or how something works → `/spectra-ask`
- Implementation is done → `/spectra-archive`
- Commit only files related to a specific change → `/spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra-apply` and `/spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

---

# Skill 放置邊界：工廠設備 vs 產品

新增 skill 前先問一句：**這是別人裝了 plugin 就想要的東西，還是只有維護這個 marketplace 的人才需要的東西？**

| | `.claude/skills/`（project） | `plugins/<name>/skills/`（產品） |
|---|---|---|
| 定位 | **工廠設備** — 做這個 repo 時用的工具 | **產品** — 使用者裝 plugin 就是要它 |
| 生效範圍 | 只有這個 repo | 所有啟用該 plugin 的環境 |
| 改完生效 | live change detection，**不用重啟、不用 bump 版本** | bump `plugin.json` + `marketplace.json` → `claude plugin update` → 重啟 |
| 佔 skill listing budget | 只在這個 repo 的 session | **每個裝了的環境都佔** |
| 呼叫 | `/skill-audit` | `/devtools:mcp-deploy` |

## 判準

把工廠設備放進產品包裝盒，**每個使用者都要為它付 listing budget，而他們永遠用不到**。

這在本 repo 特別敏感：`plugins/devtools/rules/skill-description-budget.md` 記載的血淚案例，正是 listing budget 溢出導致 4 個 skill 全被砍成 name-only。往 `devtools` 塞非必要 skill 是往同一個坑走。

反過來，把產品放進 `.claude/skills/` 則使用者根本拿不到 —— project skills 不隨 marketplace 分發。

## 兩個範例

**`spectra-*`（12 個）** — 開發本 repo 時的 SDD 工作流工具。使用者裝 `devtools` 不需要它們，所以它們住 `.claude/skills/`，不進任何 plugin。

**`skill-audit`** — 稽核本 repo 的 skill description 品質。它內建的是**本 repo 的**標準與範本，對別人的 repo 沒有意義。同樣住 `.claude/skills/`。

兩者的共同形態（新增 project skill 時比照）：

- 實體目錄 + `SKILL.md`，**不是 symlink**（symlink 進 git 對 clone 的人失效）
- **commit 進 git** —— 未來的自己在另一台機器、以及任何貢獻者，clone 下來就有完整的工廠設備
- **不放** `.claude-plugin/plugin.json` —— 加了它會變成 `<name>@skills-dir` plugin，那是另一回事

## 邊界案例

**「這個工具別人也用得到」** —— 那就問第二個問題：**它需要知道本 repo 的內部細節嗎？** `skill-audit` 內建 `plugin-*` / `doc-guardian` 的合格範本與本 repo 的門檻依據，換個 repo 就要重寫 —— 那是 project skill。若真的通用（不引用任何本 repo 特有事實），才考慮升格成 plugin skill 對外分發。

**已經有現成的 plugin 能做** —— 先確認缺口在哪。`skill-creator` 已是安裝好的 plugin，通用的「創建/改善 skill」能力本來就有；`skill-audit` 存在的理由不是重造它，是補上「本 repo 的標準」這個它不可能知道的部分。**不要為了把工具「收進來」而複製既有 plugin** —— 那只買到版本凍結，卻要承擔同步維護。
