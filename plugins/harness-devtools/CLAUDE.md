# harness-devtools — CLAUDE.md

## Purpose

Claude Code 開發工具鏈：plugin / MCP server / Swift CLI 的完整發布管道。三個領域共用同一套發布觀念，差別只在產物型態。

## 這個 plugin 的邊界

**是**：把「我寫好的工具」變成「別人裝得到的東西」——建立骨架、版本管理、build、sign、Release、marketplace 同步、安裝驗證、診斷。

**不是**：寫工具本身的內容。Swift 語言問題找 `apple-xcode-skills`，文件紀律找 `doc-guardian`。

## Marketplace 路徑解析（重要）

**永遠不要在 skill 裡硬編碼 marketplace 路徑。** 用 `scripts/resolve-marketplace.sh`：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-marketplace.sh"

MARKETPLACE_ROOT=$(resolve_marketplace_root che-plugin-devtools)

# 或反查：給 plugin 名，找它在哪個 marketplace——三欄（#18），第三欄是 manifest
# plugins[].source 解析出的 plugin 目錄；之後用 $PLUGIN_DIR，不要組 $MP_ROOT/plugins/<name>。
# **先查 rc 再拆欄位**，而且每個 bash block 都要重做一次（shell 變數不跨 Bash 呼叫存活）。
IFS='|' read -r MP_NAME MP_ROOT PLUGIN_DIR <<< "$(find_plugin_marketplace harness-devtools)"
[ -d "${PLUGIN_DIR:-}" ] || exit 1

# 只要 plugin 目錄。rc：0 印目錄 / 1 未列且沒 plugins/<name> / 2 source 不可用（空、非字串、
# 絕對、..、引號、|、控制字元、目錄不存在、symlink 逃出 root、目錄不被判定為該 plugin）/
# 3 無可用 python3 / 4 manifest 讀不動 / 5 非本地 source（git-subdir 物件、URL）/ 6 名稱不合法。
# 1–5 都先探 plugins/<name>，物化即命中——「不知道」不能變成「沒有」。
resolve_plugin_dir "$MP_ROOT" harness-devtools
plugin_source_of "$MP_ROOT" harness-devtools          # source 值（已去控制字元、截斷 200；rc 1 = manifest 未列，不做 legacy 探測；印它用 printf）
marketplace_plugin_names "$MP_ROOT"                   # manifest 宣告 ∪ plugins/ 子目錄，去重
git diff --name-only HEAD~3 | plugin_names_for_paths "$MP_ROOT"   # 這些路徑屬於哪些 plugin（不猜佈局）
marketplace_index                                     # name<TAB>root，一次走完所有 marketplace（名稱已過 [A-Za-z0-9._-]）
plugin_manifest_path "$PLUGIN_DIR"                    # .claude-plugin/plugin.json 或根目錄 plugin.json；沒有 → rc 1（讀 version 一律用它）
plugin_holders harness-devtools [marketplace]         # 每個持有該 plugin 的 checkout（name|root|dir），同實體目錄只算一個

# skill 裡的每個 bash block 都是獨立的 Bash 呼叫：Step 0.1 用 write_plugin_ctx 把驗證過的
# name|root|plugin_dir 寫進 context 檔（plugin_ctx_path：私有 state 目錄、mktemp+mv、純資料），
# 之後每個 block 只代入 plugin 名（核對 [A-Za-z0-9._-]，不以 . 或 - 開頭）、load_plugin_ctx
# 逐行 parse（不 source）、拒絕 symlink / 非本人檔案、重驗後 cd "$MP_ROOT"（失敗不設任何變數；
# 成功另給 PLUGIN_MANIFEST）；Phase 5 結束 remove_plugin_ctx。root / plugin 目錄不經 agent 的手；
# 唯一會被貼回的第三方值是 marketplace 名，它在索引層就只保留 [A-Za-z0-9._-]。
# 持有判準一套（含 "." 佈局）：目錄帶 manifest（.claude-plugin/plugin.json 或根目錄 plugin.json）就必須
# 解析得動且 name 等於請求名（JSON 壞掉 / 無 name 一律不算）；沒有 manifest 時目錄名要等於請求名且有
# plugin 形狀——所以 manifest 宣告 "." 不能冒認任意名稱，只有真的以該名為名的 repo 才會被承認。
# 有 entry 但 source 不可用是確定的錯誤（rc 2），不退回 plugins/<name>；legacy 探測只救 rc 1/3/4/5；
# 兩者都做實體包含檢查。load_plugin_ctx 以 marketplace_index（不套 tie-break，與 find_plugin_marketplace
# 同一份）重驗 root，並拒絕超過 6 小時的 context。

# 同名多候選時看得到 shadowing（一行一個 root，precedence 序）
marketplace_candidates che-local-plugins              # 巢狀同名的子層是外層的 subtree，外層勝（與 find_plugin_marketplace / plugin_holders 同一規則）
```

**為什麼**：harness-devtools 住在 `che-plugin-devtools`，但它管理的 plugin 分布在 `psychquant-claude-plugins`(28)、`sinica-claude-plugins`(2)、`che-local-plugins`(8) 等多個 marketplace。工具住哪裡與工具管哪裡是兩回事。v1.0.0 之前有 5 處把 `psychquant-claude-plugins` 寫死，是單一 marketplace 假設的殘留。

**新增 marketplace 不必改任何程式碼**（#20）。resolver 掃搜尋根底下的
`*/.claude-plugin/marketplace.json`，讀各檔**自報的 `name`**——不是目錄名，兩者
13/33 不同（`bestasr` 住在 `bestASR-project/bestASR`）。在此之前是兩份必須手動
同步的硬編清單，各只有 4 筆，漏掉本機 33 個裡的 29 個。

## Binary-backed plugin 的 metadata 解析（#22）

**不要在 skill 裡用字面假設猜 binary metadata**（欄位叫 `binary_version`、wrapper 叫 `bin/*-wrapper.sh`、
變數叫 `GITHUB_REPO=`、entry 一定有 `version`）。che-keychain 0.3.0 五個 phase 全部靜默失效就是這樣來的。
用 `scripts/plugin-binary-meta.sh`（與 resolver 並列、不互相 source；bash 3.2、zsh-safe、查詢零 stderr）：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/plugin-binary-meta.sh"

plugin_binary_version "$PLUGIN_MANIFEST"        # 明確 manifest pin：binary_version → binaryVersion → 空；rc 0（值或空）/ 3 值不合法 / 4 讀不動
                                                #   **detection-only**（與 _key 一起給 plugin_is_binary_backed 用）：phase 消費的 pin 來自 plugin_binary_pin——
                                                #   讀的是 wrapper 點名的那個 key，不做跨拼法 alias（wrapper 自己也讀不到另一種拼法；#22 第 1 點，verify R4 定案）
plugin_binary_version_key "$PLUGIN_MANIFEST"    # 明確 pin 的 key；rc 1 沒有 / 2 兩個都有（印 binary_version）
plugin_binary_wrappers "$PLUGIN_DIR" "$PLUGIN_MANIFEST"   # **逐 wrapper**：每個真的會下載 release 的檔案一列
                                                #   dir|file|asset|install|repo|pin|pinsrc（dir ∈ bin|hooks；空欄 = 該檔沒宣告；檔名不合法印 ?）
                                                #   pin 由**該 wrapper 自己**決定，三種來源封閉列舉：**只認封閉列舉的形狀，其餘一律 rc 4**（R12：區塊以 shell 關鍵字堆疊判斷、不看縮排；manifest 讀取只認語料整條 `grep -o[E] … "$M" | head -1 | cut/sed` 管線，`$M` 每次賦值都以 `/.claude-plugin/plugin.json` 結尾或是未賦值的 `PLUGIN_JSON`；版本位置任何認不出的東西都是 rc 4；**unattended 不 bump**，讀錯的後果只到 attended 問句）（R5–R9 用規則模擬 shell 控制流程，每輪都被舉出新反例；R10 改成辨識；R11 把旁路也收進同一規則）。
                                                #   pin **變數**：檔內有 `DESIRED_VERSION=` 賦值就是它；否則是 release 網址**版本位置**（`/releases/download/v$X/`）用的那個
                                                #   變數（macdoc 的 `WANT`）——版本位置是字面版本或不只一個變數 → rc 4；都沒有 → no-pin（下載 latest）。對該變數：
                                                #   (1) DESIRED_VERSION 恰一個值賦值——x.y.z 字面（pinsrc=wrapper:<file>）或 manifest 讀取（`"key"…:` 形，pinsrc=<key>）；
                                                #   (2) 可先 `DESIRED_VERSION=""`，之後的值賦值**每一個**都要有明確的「空才補」守門：同行 `[ -n "$DESIRED_VERSION" ] ||`
                                                #       / `[ -z … ] &&`、上一行 `if [[ -z "$DESIRED_VERSION" ]]; then`，或與 `if grep -q '"KEY"…'` 同縮排的 `else`
                                                #       （只在 KEY **不存在**時走；KEY 存在但空 → rc 4，che-pdf 此時拒絕下載）——取第一個有值的；
                                                #   **每個**值（含第一個）同一行前面不得有東西，且所在區塊必須是頂層、函式本體、`if [[ -f "$X" ]]`、包著讀 KEY 的 `if grep -q KEY`、
                                                #   -z 守門或上述 `else`——`if uname` / `case` / `[ -n "$X" ] &&` 裡的值都 rc 4；無守門的第二個值（兩次無條件讀取、`if uname` 覆寫、同行 `$(…) || "1.0.0"`）、opaque 值（`$(…)` 無 key、`${2:-}`、
                                                #   `"$X"`）、非 x.y.z 字面（latest、v1.2.3）、值之後又 `=""` → rc 4。縮排沒有意義；echo / grep 提到不算賦值；
                                                #   反斜線續行先接起來；值以 shell word 邊界截取（尾隨註解裡的 `"version":` 不算）。讀取器是內嵌的 `python3 -I`；
                                                #   (3) 都沒有 → pin 空、pinsrc=none。**沒有** manifest 層的全域回退——本機 26 支 wrapper / hook：4 支字面、8 支讀 version、
                                                #   6 支讀 binaryVersion/binary_version 再 version（含 macdoc 家族三支）、1 支 hook 只讀 binary_version 並自己下載（macdoc）、
                                                #   1 支不讀，其餘 hook 是 check script；R1 不回退、R2 回退 version 都對其中一半是錯的
                                                #   「grep 哪個 key」看**非註解行**上 `"<key>"` 後任意字元到 `:`（macdoc 家族寫 `'"binary_version"[[:space:]]*:'`）
                                                #   asset 欄只認宣告的 RELEASE_ASSET= / ASSET_NAME= / BINARY_NAME=（不從 install 名猜）；檔名不合法連 pinsrc 都印 wrapper:?
plugin_binary_pin "$PLUGIN_DIR" "$PLUGIN_MANIFEST"   # plugin 層的 pin = **會下載的列**（有 bin/ 時是 bin/，沒有時是 hooks/——macdoc 那種 hook 自己下載的佈局）的 pin：
                                                #   印 value|pinsrc[,pinsrc…]（全部來源，che-telegram-mcp 兩支 wrapper → 兩個；bump 要每個都改）；rc 0 一致 /
                                                #   1 沒有任何 wrapper 有 pin（no-pin，Case B 會問）/ 2 各 wrapper 不一致 / 4 任一會下載的 wrapper 的 pin 讀不出（點名的 key 沒值 / 字面被動態覆寫 / 移動 ref）——此時**只印 `|src[,src…]` 不印值**（partial 狀態不得漏出看起來合理的預設）
plugin_is_binary_backed "$PLUGIN_DIR" "$PLUGIN_MANIFEST"   # rc 0 + 命中清單 "mcp.json bin:<f> hook:<f> pin:<key>" / rc 1 空 / rc 4 沒命中但有探測點答不出（"unknown:mcp.json" / "unknown:manifest"）——不是「沒有」
                                                #   判準：.mcp.json（`mcpServers` 或真實 plugin 用的扁平格式裡，有 server 的 `command` 指向 plugin 內——`${CLAUDE_PLUGIN_ROOT}/…`、`./…`、`bin/…`；`{}`、遠端 `url`、`npx` / `uvx` 不算；不是合法 JSON → rc 4）∨ bin/ 任何一般檔案含 release URL ∨ hooks/ 任何檔案含同 pattern ∨ manifest pin
                                                #   URL 形狀**逐字**是 idd-close has_binary_wrapper 的那一條（含 gh api …/releases）；不掃 skills/ 散文
plugin_binary_repo "$PLUGIN_DIR"                # owner/repo，只看**會下載 release 的 wrapper 檔**（輔助檔的 REPO= 不算），且有 bin/ wrapper 時**只看 bin/**——
                                                #   hooks/ 的 check script 指向舊 fork（che-things-mcp / che-zotero-mcp）不能決定 Case E 追哪個 remote 的 tag；
                                                #   hook-only 佈局才看 hooks/。**逐個下載點**：每一行 release 下載（`_PBM_RELEASE_RE`）的 repo 位置——`api.github.com/repos/X/…/releases`、
                                                #   `github.com/X/releases/(download|tags|latest)`（host 錨定，notgithub.com 不算）、`gh api repos/X/…/releases`、`--repo X` /
                                                #   `--repo=X` / `-R X`——X 是字面 o/r，或檔內**每次**賦值都是字面 o/r 的變數（任何變數名；有任何一次是動態值 → `?`）；`$OWNER/$NAME` 等其他形式記為 `?`。非下載行
                                                #   （issues 連結、文件連結）不算。合併：rc 0 恰一個已知 repo / 1 沒有下載點 / 2 多個，或已知 repo 旁還有 `?`（印第一個）/ 4 只有 `?`（判不出，不是「沒有」）；
                                                #   列的 repo 欄只在該檔恰一個已知 repo 時才填
plugin_binary_name "$PLUGIN_DIR"                # 第一個**宣告**的 ASSET 名：RELEASE_ASSET= → ASSET_NAME= → BINARY_NAME=（後者只在非註解行用它下載時算：
                                                #   releases/download/…/$BINARY_NAME、--pattern、browser_download_url；只當 install 目標的不算）；不從 install 名猜；rc 1 沒有
plugin_install_names "$PLUGIN_DIR"              # 所有 INSTALL 名（INSTALL_NAME= → BINARY_NAME= → $HOME/bin/<name>），一行一個——sidecar 用這個 key；
                                                #   一支 wrapper 抽不到名字 → 它不在這裡（消費端用 plugin_binary_wrappers 的空欄計「未解析」，不得報 all N）
plugin_installed_binary_version "$PLUGIN_DIR" [name]   # <bin dir>/.<name>.version；rc 1 沒有 sidecar（wrapper 沒在本機寫過——從未觸發，或它不寫這個檔）/ 2 抽不到名字 / 3 內容不是版本
plugin_bin_dir                                  # sidecar 目錄（~/bin；測試座標三條件成立時 PLUGIN_BIN_DIR，見下）——消費端印路徑用這個，不碰底線函式
marketplace_entry_version "$MP_ROOT" "$PLUGIN_NAME"   # rc 0（值；entry 缺 version 時印**空**）/ 1 沒有 entry / 3 值不合法 / 4 讀不動——不 KeyError
latest_release_version owner/repo               # gh release view … tagName，去 v；rc 1 失敗
release_assets owner/repo [x.y.z]               # 該 release（無版本 = latest）的 asset 名，一行一個；**先查 tag v<x.y.z> 再查裸值**（pin 存裸值、真實 tag 全是 v 前綴——
                                                #   裸值直查讓 Signal 1 對每支有 pin 的 wrapper 永遠「未核對」，#22 verify R3）；不合 allowlist 的名字印 ?；rc 1 失敗
version_gt 0.3.0 0.2.0                          # rc 0 大於 / 1 否 / 2 不可比（非 x.y.z；BSD sort 沒有 -V，所以用 awk）
```

**規則**：答不出來回 distinct rc、印空——**不印看起來合理的預設值**。消費端把 rc 1 / 2 / 4 印成 UNKNOWN，
不把「查不到」當「沒有」。`plugin-update` Phase 0.3（Step 1 / Step 2 (a)(b)(d)(e)、Case E bump fence）、
Phase 1.5 Step 2 / 3、Phase 2 Step 4、Phase 5 Step 1.5 全部只消費這裡的輸出（Phase 2 Step 1 列全表用 inline python `.get('version')`，helper 只查單一 entry——那段不是 binary metadata）。`PBM_GH` / `PLUGIN_BIN_DIR` 是**測試座標**
（stub gh、sidecar 目錄），只在 `PBM_TEST=1` **且** `PBM_TEST_ROOT` 是系統 temp 樹（/tmp、/var/folders、$TMPDIR）下的真實目錄（`/`、`$HOME` 不算；`$TMPDIR` 先解析、解析不到或為 `/` 即關）**且** 實體 `$PWD` 在其下時生效——這是縮小座標、不是 sandbox（PATH 本來就能換 gh）（production fence `cd "$MP_ROOT"`，正常放置的 marketplace 不在 temp 樹下；checkout 在 /tmp 的不受此保護），且 `PBM_GH` 只接受絕對路徑的可執行檔。測試：`scripts/test-plugin-binary-meta.sh`
（214 斷言：R12——關鍵字區塊堆疊（`if false` 頂格賦值、外層 `if uname` 包內層 `if -f`）rc 4、manifest 讀取只認語料整條管線且讀的是 plugin.json 變數、版本位置認不出 / 網址拆兩行 / `gh release download <tag>` rc 4、`gh release download "v$VER"` 讀 VER、`DESIRED_VERSION` 沒用在版本位置 rc 4、`mcpServers` 非物件 rc 4、symlink wrapper rc 4；R11——非 DESIRED_VERSION 的 pin 變數同受封閉形狀、第一個值在 `if uname` / `&&` / `case` 裡 rc 4、repo 變數後續動態覆寫或條件重賦值 rc 2、`$OWNER/$NAME` 下載點、只有未知下載點 rc 4、網址字面版本 rc 4、`VERSION=` / `PIN=` 在版本位置即 pin、bin 旁帶 pin 的 hook rc 4、遠端 url / npx 的 .mcp.json 不算、讀取器失敗為判不出、JSON 讀取 `python3 -I`；封閉形狀——函式內縮排的兩個無條件賦值、同行 `$(…) || 字面`、`if uname` 覆寫、兩次無守門讀取皆 rc 4；語料形狀 mail（續行 + if -z 守門）與 pdf（if grep -q / else，KEY 存在但空 → rc 4）可讀；尾隨註解的 key 形不算；變數主 repo + 字面備援 repo rc 2；issues 連結不選 repo；`-R` / `--repo=`；變數 URL 的 host 錨定；扁平 `.mcp.json` 命中、`{}` 不命中；echo/grep 提到 DESIRED_VERSION= 不算賦值；單檔雙 repo rc 2；帶引號的 gh --repo / gh api；非 *REPO 名的變數在 repo 位置；release URL host 錨定；壞 .mcp.json / manifest → is_binary_backed rc 4、partial 讀取只印來源不印值、manifest 讀取後動態覆寫 rc 4、TMPDIR 解析失敗即關座標、行內覆寫 rc 4、jq 讀 key rc 4、`latest` 非 pin、`PBM_TEST_ROOT=/` / `$HOME` 不開座標、逐檔 repo 合併、沒被用的 *_REPO= 不算、字面 pin 須為最後一個賦值、seam 三條件、asset 名的 `.` 不是萬用字元、註解行的 release URL / $HOME/bin/<name> 不算、只當 install 目標的 BINARY_NAME 不是 asset、兩種 key、四種 pin 來源、macdoc 家族的 grep 寫法、hook-only 有 pin、wrapper 不一致、共用 pin 的兩個來源、點名 key 無值 rc 4、
無副檔名 wrapper、bin+hooks 混合、hooks 的 REPO= 不蓋 bin、文件連結 vs 賦值、註解行的 URL 不算下載、非 wrapper 的 REPO=、`${X}` 賦值、縮排 / export、
`gh api` 形、多 binary、asset ≠ install 名、RELEASE_ASSET=、缺 version 的 entry、`.mcp.json` `{}`、sidecar 三態、不安全檔名（含帶字面 pin 的）、
v 前綴 tag 與裸 tag 回退、stub gh 與 PBM_TEST 守門）。

## MCP 專案路徑解析（同理）

**永遠不要在 skill 裡硬編碼 MCP 專案路徑。** 用 `scripts/resolve-mcp-project.sh`：

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-mcp-project.sh"

cd "$(require_mcp_project "$1")" || exit 1   # 找不到會列出可用專案並回非零
PROJ=$(resolve_mcp_project che-ical-mcp)      # 純查詢，找不到回非零、無輸出
list_mcp_projects                             # 所有已知專案
```

專案分佈在三個 umbrella，`MCP_ROOTS_SPEC` 定義搜尋順序與收錄規則：

| Root | Mode | 意義 |
|---|---|---|
| `~/Developer/che-mcps` | `any` | 主 umbrella，任何帶 package metadata 的子目錄都算（含共用 library）|
| `~/Developer/che-msg` | `any` | telegram 家族自己的 umbrella |
| `~/Developer` | `mcp-suffix` | 一般目錄，**只收 `*-mcp`** —— 否則 `macdoc` / `rush` 等 22 個無關 Swift package 會被誤收 |

**為什麼**：v2.0.1 之前有 11 處硬編碼 `~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/`，那個路徑**已經不存在**。裸 `cd <deadpath>/$1`（不帶 `2>/dev/null &&`）失敗後 shell 繼續往下跑，skill 就對呼叫者當時的 cwd 做檢查並回報 —— 錯的專案，沒有任何錯誤訊息。

收錄判準是「有任一語言的 package metadata」而非只認 `Package.swift`：`iss-compute-mcp` 是 Python（只有 `requirements.txt`），Swift-only 的判準會靜默漏掉它。

新增 umbrella 時只改 `MCP_ROOTS_SPEC` 一處。

## 三個領域的 skill 命名

| 前綴 | 產物 | 典型鏈路 |
|---|---|---|
| `plugin-*` | Claude Code plugin | create → upgrade → deploy → update → health/debug |
| `mcp-*` | MCP server | new-app → sign-pipeline → deploy → publish → test/diagnose |
| `cli-*` | Swift CLI | new-app → deploy → install → upgrade |

前綴天然不衝突（已驗證 24 個 skill 零重名），合併後可直接並置。

## 跨 skill 呼叫

`plugin-update` 是 dependency-aware orchestrator：偵測到 binary-backed plugin 時會呼叫 `mcp-deploy` 或 `cli-upgrade`。合併成單一 plugin 後這些呼叫**保證解析得到**——這正是合併的主要理由（見 README「為什麼是一個 plugin 而不是三個」）。

skill 之間互相引用時用 `/harness-devtools:<skill-name>`，不要用舊的 `/plugin-tools:` / `/mcp-tools:` / `/cli-tools:` 前綴。

## Plugin 標準結構（快速參考）

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json          ← 唯一必要檔案
├── skills/                  ← SKILL.md files
├── agents/                  ← agent definitions
├── hooks/                   ← hooks.json
├── rules/                   ← 領域規則
├── .mcp.json                ← MCP servers
└── README.md                ← 分享前建議加
```

> `skills/`、`hooks/`、`agents/` 在 plugin root，**不在** `.claude-plugin/` 裡面。

## 版本同步紀律

改任何 plugin 都必須同步兩處，否則 `claude plugin update` 會說 already at latest 而跳過：

1. `plugins/<name>/.claude-plugin/plugin.json` 的 `version`
2. `.claude-plugin/marketplace.json` 對應 entry 的 `version`

CHANGELOG.md 遵循 Keep a Changelog 1.1.0，由 `/doc-guardian:changelog-validate` 驗證三方同步（CHANGELOG ↔ plugin.json ↔ marketplace.json）。

## 參考資源

- Anthropic 官方 plugin-dev：https://github.com/anthropics/claude-plugins-official/tree/main/plugins/plugin-dev
- 官方 skills（教學型）：`/plugin-dev:plugin-structure`、`/plugin-dev:skill-development`
- 本 plugin（執行型）：直接建好、同步好、開好 issue
