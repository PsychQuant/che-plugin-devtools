# Skill Description Length & the Listing Budget

寫或改任何 skill 的 frontmatter `description` 時,**先想「它會不會被 skill listing 砍掉」**。description 太長,或裝了太多 skill 導致 listing 溢出 budget,Claude Code 會把描述砍成 **name-only**——skill 只剩名字、觸發完全靠名字猜,精心寫的觸發語根本沒被讀到。

## 機制(官方 skills 文檔,`code.claude.com/docs/en/skills` + settings schema)

Claude Code 在每回合把一份 **skill listing(name + description)** 載進 context,好讓模型知道有哪些 skill 可觸發。兩道關卡會砍掉描述:

| 關卡 | 預設 | 設定 | 行為 |
|------|------|------|------|
| **Per-entry 上限** | 1,536 字元 | `skillListingMaxDescChars` | 單一 skill 的 `description`(＋ `when_to_use`)合計超過就 **truncate**,尾巴被切掉 |
| **Listing 總 budget** | context window 的 **1%**(字元) | `skillListingBudgetFraction` | 全部 skill 的描述加起來超過 budget 時,**從「最少被 invoke 的 skill」開始整段 drop 成 name-only**,最常用的保留全文 |

**關鍵推論**:
- **description 是唯一的觸發面**。SKILL.md body 是**觸發之後**才載入的;描述沒進 listing = 模型看不到 = 只能靠名字觸發。
- **新 skill 有 cold-start 死結**:剛裝、沒人 invoke 過 → 屬於「最少用到」→ budget 溢出時第一個被 drop → 無描述無法觸發 → 一直沒被 invoke → 永遠墊底。裝了很多 skill 的環境(數十個 plugin)特別容易踩到。

## 規則

1. **description 精簡、前置觸發語。** 目標遠低於 1,536 上限(**≤ ~500 字元**是好習慣),第一句就講「做什麼 + 什麼時候用 / 觸發詞」。完整細節、步驟、範例一律留在 **body**,不要塞進 description。
2. **別為了 pushy 而灌長。** 「描述越詳細越容易觸發」在 many-skills 環境是**反效果**——寫太長反而整段被 budget 砍掉、變 name-only。pushy 的觸發語要短而準,不是多。
3. **裝了很多 skill 就提高 budget。** 在 `~/.claude/settings.json` 設 `skillListingBudgetFraction`(如 `0.02`=2%、`0.03`=3%),或用 `SLASH_COMMAND_TOOL_CHAR_BUDGET` 固定字元數。代價是每回合 listing 多吃 context(大 context window 可負擔)。
4. **要騰 budget 給重要 skill**,把低優先 skill 在 `skillOverrides` 設 `"name-only"`(主動放棄它們的描述,把額度讓給別的)。
5. 改完 description 要生效需**重啟**(listing 在 session 啟動時建);plugin 版本也要 bump 才會被 `plugin update` 拉進 cache。

## 怎麼診斷「描述沒 surface」

症狀:某 skill 明明有寫 description,卻不正常觸發。驗法:

- 開一個**全新 subagent**,叫它報「你的 available-skills 清單裡 `<skill>` 的描述開頭」。回 **NAME-ONLY** = 描述被 drop。用一個常用 skill(描述一定在)當**對照組**同場比對,確認不是「subagent 一律拿不到描述」。
- 回 NAME-ONLY 時,**不是格式 bug**(YAML 照樣 parse)。查兩件事:(a) 這個 description 是不是超過 1,536;(b) 裝的 skill 總量是不是讓 listing 溢出 budget。對症下藥:縮短描述 ＋/或 提高 budget。
- **不要**往「reinstall / 改 block-scalar 格式 / 反覆重寫描述內容」鑽——描述沒進 listing 時,改內容毫無效果(踩過:把 clarity-audit 描述從 668 一路加到 1860 字,反而更容易被砍)。

## 血淚來源

math-tools 的 4 個 skill 全被砍成 name-only(clarity-audit 描述 1,860 字、又超 1,536 cap),`clarity-audit` 觸發率一路只有 1/4;查了 reinstall、YAML 格式、描述字斟句酌都沒用,最後對照官方文檔才發現是 listing budget（該環境 ~90 plugin、預設 1% 嚴重溢出）。修法:4 個描述砍到 ≤ ~670 字前置觸發語 ＋ `skillListingBudgetFraction` 提到 0.02。

## 跟其他 rule 的關係

- `tool-readme-sync.md`:README 對外文件的同步;本 rule 管的是 **description 這個「給模型觸發用」的內部面**,兩者不同讀者。
- plugin-create / plugin-upgrade 產 skill 時、plugin-deploy / plugin-update review 時,都套用本 rule 檢查每個 skill 的 description 長度。
