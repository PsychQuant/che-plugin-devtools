---
name: skill-create
description: |
  建立新的 Claude Code skill：先過命名準則，再呼叫官方 skill-creator 撰寫，最後跑 description 觸發測試並如實回報。
  依賴官方 plugin `skill-creator@claude-plugins-official`；沒裝或停用時直接停下並說明怎麼裝，不退回內建流程。
  當用戶提到「建立 skill」「新 skill」「create skill」「寫一個 skill」「幫 skill 取名」時使用。
  建立整個 plugin 用 plugin-create；本 skill 只管單一 skill。
argument-hint: "[skill-name]"
allowed-tools:
  - Bash(bash:*)
  - Bash(python3:*)
  - Bash(python:*)
  - Bash(ls:*)
  - Bash(git:*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
  - Skill
---

# Create Skill — 建立單一 skill

在官方 `skill-creator` 之上補三件事：取名時過命名準則、取名時說出改名的成本、寫完後跑 description 觸發測試。寫 skill 本身交給 `skill-creator`，這裡不複製它的內容。

## Execution Steps

### Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="preflight", description="Step 1: check-skill-creator.sh；非零就停，不退回內建流程")
TaskCreate(name="name_skill", description="Step 2: 過命名準則、顯示改名成本、使用者確認名字")
TaskCreate(name="locate_target", description="Step 3: 決定 skill 要放在哪個目錄")
TaskCreate(name="call_skill_creator", description="Step 4: Skill(skill-creator:skill-creator)，帶入已確認的名字與目錄")
TaskCreate(name="description_trigger_test", description="Step 5: 跑官方 Description Optimization，如實回報；跑不了就說跑不了")
TaskCreate(name="check_references", description="Step 6: 目標在 git repo 時跑 check-skill-references.sh")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

### Step 1: 確認官方 skill-creator 可用（缺了就停）

```bash
SC_PATH=$(bash "${CLAUDE_PLUGIN_ROOT:?}/scripts/check-skill-creator.sh") || exit $?
```

非零 exit code 時，把腳本印在 stderr 的那行指令（安裝或啟用）原樣轉告使用者，然後**停下**。不要複製一份 skill-creator 的流程湊合，也不要「先寫寫看」。這個 repo 沒有 plugin 依賴宣告機制，缺依賴時最糟的結果是流程安靜地走偏，所以寧可擋下。

成功時 `SC_PATH` 是官方 plugin 的 installPath，Step 5 會用到。腳本在 CLI 不可用而改用磁碟紀錄時，會在 stderr 說 enabled 狀態無法確認；看到這行就在最後的報告裡一併說明。

### Step 2: 取名

**動手前先讀 `docs/design-principles.md` 的「命名慣例」。** 判準只寫在那一處，這裡不複述，以免兩份文字日後各自改動而互相矛盾。

流程：

1. 若 `$ARGUMENTS` 已給名字，把它拿來過準則；沒給就先問使用者「你會怎麼說要做這件事」，用那句話的動詞加對象當名字的底
2. 提出名字時**同時附上準則要求的那句還原句**，讓使用者看得到判斷依據。不過準則時（名字是格式名、內部機制或實作分層），請使用者換說法，不要自己挑一個看起來比較好的
3. 取名前先給使用者看這一段，再請他確認名字：

   > 名字會同時出現在目錄名、frontmatter 的 `name:`、README、docs 與測試，而引用不像 import：改名漏掉一處時，skill 照樣載入，只是文件指向一個不存在的名字，沒有任何東西報錯。取名時多想一分鐘，比事後改名便宜。

4. 若目標 repo 有 `scripts/check-skill-references.sh`，提醒日後改名時用它找殘留的引用

名字有沒有撞到別的 skill 不在本 skill 的檢查範圍。

### Step 3: 決定目標目錄

未指定時用 AskUserQuestion 問：要放在哪個 plugin 底下（`plugins/{plugin}/skills/{name}/`），還是個人的 `.claude/skills/{name}/`。只建檔，不 commit、不發布；發布走 `/harness-devtools:plugin-update`。

### Step 4: 呼叫官方 skill-creator

```
Skill(skill="skill-creator:skill-creator",
      args="建立一個 skill，名字固定為 {name}（已過命名準則，不要另取名），放在 {target dir}。{使用者描述的用途}")
```

skill-creator 完成後，確認 `{target dir}/SKILL.md` 存在、frontmatter 的 `name:` 等於目錄名。不一致就停下回報，不要自己改成一致。

### Step 5: description 觸發測試

這一步**重用官方 skill-creator 的 Description Optimization**，不另寫一套。它必須在 skill-creator 自己的目錄下以模組方式執行（直接執行腳本會因為找不到 `scripts` 套件而失敗）：

```bash
cd "$SC_PATH/skills/skill-creator" && python3 -m scripts.run_loop \
  --eval-set <trigger-eval.json 的路徑> \
  --skill-path <新 skill 的目錄> \
  --model <目前這個 session 使用的 model ID> \
  --max-iterations 5 --verbose
```

eval 查詢集（20 句、should-trigger 與 should-not-trigger 各半，反例要用近似但不該觸發的句子）的產生方式見 skill-creator 的 SKILL.md「Description Optimization」一節。

**如實回報，不設通過門檻。**

- 跑完：報告最後一輪 train 與 held-out 的觸發率，以及它建議的 description 是否被採用
- 跑不了（沒有 `claude -p`、使用者不想花額度、中途失敗）：寫「觸發測試未執行」與原因，不要寫成通過
- 這個測試量的是「description 會不會讓 Claude 叫起這個 skill」，**不是**名字取得好不好。兩件事不要混為一談

### Step 6: 檢查引用

目標在 git repo 內、且該 repo 有 `scripts/check-skill-references.sh` 時：

```bash
bash "${CLAUDE_PLUGIN_ROOT:?}/scripts/check-skill-references.sh" --repo "$(git rev-parse --show-toplevel)"
```

有失效引用就列出來，不自動修。

## 最後報告

列出：名字與「我要＿＿」那句話、目標目錄、skill-creator 的 installPath 與 enabled 是否確認、觸發測試的結果（或未執行與原因）、引用檢查結果。
