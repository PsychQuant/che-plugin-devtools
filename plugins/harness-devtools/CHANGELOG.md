# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Breaking for direct consumers**：`resolve-marketplace.sh` 的 `find_plugin_marketplace` 輸出從 `name|root` 擴為 `name|root|plugin_dir`；`IFS="|" read -r` 需接三欄（#18）。已知消費者 `plugin-update` Step 0.1 與 `plugin-debug`（僅直接消費回傳值的那一行；其餘 9 處硬編路徑見 #23）同步更新。
- `plugin-update`：Phase 0.3 / 1.5 / 2 / 2.5 / troubleshooting 共 17 處 `plugins/{name}` 硬編路徑改為 `$PLUGIN_DIR`；**每個 bash block 以同一段前導開頭**——只代入本次引數 `PLUGIN_NAME`（代入前核對 `[A-Za-z0-9._-]`），`load_plugin_ctx` 載回 Step 0.1 以 `write_plugin_ctx` 寫下的 `MP_NAME|MP_ROOT|PLUGIN_DIR`（`plugin_ctx_path`：`${XDG_STATE_HOME:-~/.local/state}/harness-devtools/`，mktemp+mv、純資料、逐行 parse 不 source、拒絕 symlink / 非本人檔案、既有目錄須為 700）並重驗（root 仍在 `marketplace_index` 該名稱的列裡——與 `find_plugin_marketplace` 同一份、不套 tie-break——、`resolve_plugin_dir` 結果一致、未超過 6 小時 TTL），再 `cd "$MP_ROOT"`；Phase 3 / 4 / 5 的 `claude plugin` 指令同樣走前導並用 `"$MP_NAME"` / `"$PLUGIN_NAME"`，Phase 5 結束 `remove_plugin_ctx`（shell 變數不跨 Bash 呼叫存活；同名多 checkout 時 Step 0.1 gate 過的那份 root 綁到後面每個 block，第三方 manifest 的值不經 agent 代入）；Step 0.1 的解析與 gate 併為同一個 fence；Phase 0.3 Step 1 的 wrapper 偵測改 `find … -exec grep -l`（R6 曾是 `grep -lq`，R8 因 zsh nomatch 改 find；原 pipeline 退出碼恆 0，人人 binary-backed——修正後「四個信號都抓不到的 plugin」第一次真的走到「跳過 Phase 0.3」那條分支，sync-intent 的 no-op 早退對它們暫時只剩 Phase 0.5 Case A；Step 1 / Step 2 新增第四個信號「manifest 有 `binary_version` / `binaryVersion` pin 即 binary-backed」，che-keychain（wrapper 叫 `bin/che-keychain`）因此不再被漏掉；其他 wrapper 命名的偵測在 #22，Phase 0.3 對所有 plugin 執行在 #19）；Step 2 在同一 fence 內重算結構信號並算出 Case A/B/C 印出數字（Step 4 只依它派發；`detect_binary_repo` 就地定義；`BINARY_UNRELEASED` 四態：數字 / unknown（無 clone、tag、main，或 binary-backed 但 plugin.json 無 `binary_version` / `binaryVersion`）/ 非 binary，unknown 分 no-pin / no-clone 兩個子態、走 Case B 不當 0，Case B 三個問句模板各自對應（no-pin 的建議是補 pin 而非 release）；plugin.json 讀不到 version 即 abort；Case A/B/C 以 exit 0 收尾，A 清掉 context、B 的 abort 選項亦先清、proceed 保留）；Step 0.1 與 Phase 1 Step 1 接受可選的 `MP_NAME`（使用者或 Phase 1 選定的 marketplace，與 `_valid_name` 同一條 allowlist），Step 0.1 以 `plugin_holders` 列舉持有者（有 `MP_NAME` 只走該名稱的列；解析到同一實體目錄的巢狀同名 marketplace 只算一個，che-local-plugins 不再被誤判為多份 checkout）、真的多份時以 cwd 消歧、cwd 不在任何一份就 abort 列出（不再 first-wins 靜默選一份）、指定的 marketplace 沒有該 plugin 時訊息指名「不在 '<MP_NAME>'」並在診斷迴圈標出它其實在哪個 marketplace；Phase 1 Step 1 的 cwd 推斷取最內層的 checkout；Step 0.1 對沒有 plugin manifest 的目錄 abort（沒有 version 可同步）；所有讀 plugin.json 的 fence（Phase 0.3 / 1.5 / 2 / 2.5）改讀 `load_plugin_ctx` 給的 `$PLUGIN_MANIFEST`（`.claude-plugin/plugin.json` 或根目錄 `plugin.json`——safari-browser / che-apple-dev / anything-downloader 佈局在 R5 被 resolver 承認、消費端卻仍讀寫死路徑），Phase 2.5 讀不到 version 即 abort（空字串會讓信號 1 的 `v\|` 匹配每一行、永遠「沒有 stale」）；Phase 1.5 Step 5 與批次更新的 fence 補前導 / 守門；Phase 2 Step 4 的版本在 fence 內讀；troubleshooting 的 block 改為自足（不依賴 context 檔）；沒帶 plugin 名的 invocation 在 Step 0.1 得到獨立訊息並先走 Phase 1 Step 1；Phase 0.5 Step 5 自算 `UPSTREAM`、target 即本次引數（不再延後到 Phase 1）；Phase 1 Step 1 對每個 marketplace root 各推斷一次；兩處 `grep '^plugins/'` 改為 `plugin_names_for_paths`；表格儲存格內的 `$PLUGIN_DIR` 改為 `<PLUGIN_DIR>` 敘述；git pathspec 一律用絕對 `$PLUGIN_DIR` 並帶 `--literal-pathspecs`；Step 0.1 未命中時走一次 `marketplace_index`，以 rc 0 / 2 / 3 / 4 / 5 指名真正原因，印出的每個值去控制字元並截斷（#18）。
- `plugin-debug`（三個帶前導的 block 都改：Phase 1 Step 1 解析、Step 1 版本查詢、Step 2 diff）：找不到源碼時 `SRC` 留空並回報 UNKNOWN（不再 `exit 1` 砍掉 cache 端診斷，也不再印「No skills to diff」）；diff 的 rc 三分（0 相同 / 1 差異 / ≥2 UNKNOWN），cache 目錄不存在先報 UNKNOWN；版本查詢區分「源碼未解析」與「plugin.json 讀不到」；hooks 仍只比較 `hooks.json`；用到 `$SRC` 的 block 各自解析（#18）。
- `plugin-update` Phase 0.5 Step 5：cross-plugin 檢查的 target 即本次引數（原本延後到 Phase 1 推斷）；輸出不再加 `plugins/` 前綴；root-sourced plugin 對任何 commit 都算被 touch（#18）。
- **Security**：context 檔為純資料、私有目錄、mktemp+mv、載入時拒絕 symlink 與非本人檔案（#18 verify R4）；`plugin-update` 內所有 `python3 -c` 改以 `sys.argv` 傳路徑——`$PLUGIN_DIR` 現在來自 manifest（第三方檔案），內嵌進原始碼時路徑含 `'` 即任意程式碼執行；`resolve_plugin_dir` 拒絕含引號 / 反斜線 / `$` / 反引號 / `|` / 控制字元 / `..` 的 source 與絕對路徑，目錄以實體路徑檢查仍在 root 內（symlink 逃逸 → rc 2），`_marketplace_index` 對名稱不在 `[A-Za-z0-9._-]` 的 marketplace 整個不列入（`resolve_marketplace_root` 等所有呼叫端一致；這類 manifest 本來就無法被安全地貼回或當路徑段使用）；`.` 佈局與其他目錄同一套持有判準（manifest 解析得動且 name 相符，或目錄名等於 plugin 名且有 plugin 形狀——宣告 `.` 不能冒認任意名稱）；marketplace 名在索引層就過 `[A-Za-z0-9._-]`（`list_marketplaces` / `marketplace_index` / `find_plugin_marketplace` / `plugin_holders` 印不出不合法的名稱，Phase 1 Step 1 印出、代入 Step 0.1 的值因此已 allowlisted）；`load_plugin_ctx` 失敗不設任何變數，`PLUGIN_CTX_TTL_SECONDS` 非數字退回 6 小時、未來時間戳拒絕；`_dir_mode` 先捕捉 BSD `stat` 輸出再驗證是八進位（GNU coreutils 的 `stat -f` 會把檔案系統資訊印到 stdout，舊寫法在 Linux 上讓 `write_plugin_ctx` 永遠 rc 2）；Phase 1.5 Step 2 的 `BINARY_NAME` / `GITHUB_REPO` 在抽出當下就過 allowlist，且以 `grep -F` 比對（`.` / `-` 是合法字元、不是 regex 萬用字元）（#18 verify R6）；`plugin-update` 的 fence **不再用 shell glob**（`bin/*-wrapper.sh` / `bin/*` 改 `find`）：Bash 工具跑在 zsh、`nomatch` 開著，glob 對不到（沒有 bin/ 的 gifthub、bin/ 裡沒有 wrapper 的 che-keychain）整個 fence 當場中止、`IS_BINARY_BACKED` / `Case X` 決定行印不出來——新增 `scripts/test-plugin-update-fences.sh` 在 bash 與 zsh 下各跑一次 Step 0.1 / Phase 0.3 Step 1、2 / Phase 1.5 Step 2 並拒絕任何 `no matches found`；Phase 0.3 Step 2 先探 `git rev-parse --is-inside-work-tree`（git 答不出來不得變成「30 天內沒改」再變成 Case A）；Step 0.1 多持有者以 cwd 消歧時取最內層 checkout（同 Phase 1 Step 1），abort 訊息依「跨 marketplace 各自上架」（建議代入 `MP_NAME`，別刪）與「同 marketplace 多份 clone」分流；Phase 0.5 Step 3 的 commit / push 動作改為專用 fence（帶前導，git 在 marketplace repo 內跑，不在對話裡現組）、Case A 亦 `remove_plugin_ctx`（#19 起 Case A 改為通過、不再清）；Phase 2.5 先判 README 是否存在（缺席明說、不讓六信號各自誤報），結尾印 ✅ fresh 或 stale 結論；`plugin_names_for_paths` 的前綴改經 `ENVIRON` 傳給 awk（`-v` 會展開反斜線），兩處 `git log/diff --name-only` 加 `-c diff.relative=false`；`clean()` 亦去反斜線（zsh 的 `echo` 會展開）；GNU-stat shim 測試改為可攜（不再假設 `/usr/bin/stat` 是 BSD）（#18 verify R7）；Phase 2.5 的四個 `for x in $VAR` 迴圈改 `while read`（zsh 未加引號的展開不分詞：信號 4 / 6 在真實環境從未觸發，而 R8 新加的 ✅ 把它們算成通過）、先探 git（非 git 時信號 2 / 6 記為無法判定、結論行分開講）、fence smoke test 納入 Phase 2.5（README 缺 component 必須 stale）、Phase 1.5 Step 3 與 plugin-debug 版本查詢；Phase 1.5 Step 3（CLI）比照 Step 2：hook 缺席 / 抽不到 repo 或 binary 名 / 取不到版本各印一行、值過 allowlist、結尾印 ✅ 或 ⚠️（repo 只認 `GITHUB_REPO=` / `REPO=` / `api.github.com/repos/`，不再抓檔案裡第一個 a/b 形字串）；Phase 2.5 Step 2 的 README commit + push 與 Phase 0.5 Case E 的 fetch + rebase / merge 各有專用 fence，Case B / D 的 push 描述指向 push fence；Phase 1 Step 1 先驗 HEAD 與 `HEAD~3`（不足就從 root commit 起算）並印出「N 個 commit 觸到 M 個 plugin」或明說沒對映到；Step 0.1 診斷迴圈印 source 值改用 printf（zsh 的 echo 會展開反斜線）；`write_plugin_ctx` 對目的地是目錄（或指向目錄的 symlink）回 rc 2，不再把暫存檔搬進去還報成功；Phase 1.5 Step 2 抽值用 `cut -s`；「abort 就清 context」的範圍改為封閉列舉（0.3 / 0.5 / 1.5 Step 4 / Phase 5），其餘中途停住由 TTL 兜底；troubleshooting block 印出它用的 root（#18 verify R8）；`find_plugin_marketplace` 改為 `plugin_holders` 的首列（巢狀同名 root 是 subtree、外層勝、與索引順序無關——先前 che-local-plugins 命中外層或內層取決於 `find` 的 readdir 順序），`plugin_holders` 對同名巢狀 root 先套 subtree 規則再以名稱 + 實體目錄去重；Phase 0.5 Step 5 明寫**在 push fence 之前**跑（push 後 `$UPSTREAM..HEAD` 為空）、把 `plugin_names_for_paths` 解析不到的名稱算成「未知」並走警告分支、結尾印結論行、納入 smoke test（fixture 加 bare remote）；Phase 2.5 逐信號記錄「未評估」（無版本標記 / 無 git mtime / 無 CHANGELOG / 無 tool count / 無 Version History / 名稱含非法字元），結論行只宣稱真的跑過的信號，component 名不經 xargs、拼進 ERE 前跳脫 `.`；commit message 改 quoted heredoc → `git commit -F`（訊息裡的單引號是常態，不放進單引號常值）；Phase 0.5 commit fence 的 `git add -A -- "$MP_ROOT"`（巢狀在外層 repo 的 marketplace 不得 stage 外層）；Phase 1.5 Step 3 的 repo 抽取認 `*_REPO="owner/repo"`（gifthub 是 `GFH_REPO=`）/ `api.github.com/repos/` / `github.com/` 字面、兩段須英數開頭（擋 `..`、`.git`）、binary 從 `/` 執行；Phase 1 Step 1 指定 `MP_NAME` 時走 `marketplace_candidates`；`PLUGIN_CTX_TTL_SECONDS` 超過 8 位數退回預設；本次「外層勝」造成的三處回歸就地修掉：`plugin-debug` 的 `SRC_LOCAL`、`plugin-upgrade` 的 `PLUGIN_DIR` 改 `resolve_plugin_dir`、`tool-readme-sync-plugin.md` 的 plugin 計數改 `marketplace_plugin_names`（其餘 `plugins/<name>` 硬編仍在 #23）；SKILL 開頭補「同名多持有者需站在目標 checkout 或帶 marketplace 名」（#18 verify R9）；plugin 名稱只接受 `[A-Za-z0-9._-]`（rc 6）；`plugin_source_of` 回傳前去控制字元並截斷（#18 verify R1/R2）。

### Added
- `scripts/plugin-binary-meta.sh`（#22）：binary-backed plugin metadata 的單一讀取點（與 `resolve-marketplace.sh` 並列、不互相 source；bash 3.2、zsh-safe、查詢零 stderr、答不出來回 distinct rc 並印空）：`plugin_binary_version`（`binary_version` → `binaryVersion` → 空，**不**回退 `version`；detection-only——各 phase 消費的 pin 來自 R3 的 `plugin_binary_pin`，讀的是 wrapper 點名的那個 key，不做跨拼法 alias：wrapper 自己也讀不到另一種拼法）、`plugin_binary_version_key`（寫回時保留檔案原 key）、`plugin_is_binary_backed`（`.mcp.json` ∨ `bin/` 下**任何一般檔案**含 release URL ∨ `hooks/` 下任何檔案含同 pattern（R3 起不限 `*.sh`）∨ manifest pin；URL 形狀與 idd-close `has_binary_wrapper` 同一條，不看檔名後綴、不看變數名；R4 起只看非註解行）、`plugin_binary_repo`（URL 字面或 `<任何>_REPO=` 賦值，多值 rc 2 印第一個；R2 起賦值 > URL 分級、R4 起有 bin/ wrapper 時只看 bin/、R5 起 URL 只認非註解行）、`plugin_binary_name`（R4/R5 起是**宣告的 asset 名**：`RELEASE_ASSET=` / `ASSET_NAME=` / 用於下載的 `BINARY_NAME=`，不從 install 名猜；install 名另由 `plugin_install_names` 給）、`plugin_installed_binary_version`（`~/bin/.<name>.version` sidecar；無 sidecar rc 1、抽不到名字 rc 2）、`marketplace_entry_version`（entry 缺 `version` 印空 rc 0、缺 entry rc 1，不 KeyError）、`latest_release_version`（`gh release view`，`PBM_GH` 可注入 stub）、`version_gt`（awk，BSD sort 沒有 `-V`）。`scripts/test-plugin-binary-meta.sh`（bash 3.2 + zsh source 零 stderr；R3 後 107 個斷言）。
- `plugin-update` Phase 0.3 新增信號 (e) **release ahead of pin** 與 **Case E**（#22 第 3 點）：latest release tag 比 wrapper 的 binary pin 新 → AskUserQuestion「bump pin 到 vX（只改 pin 所在的 key / 那一行）／連 plugin version 一起 bump／proceed without bumping／abort」；預設選項依 pin 來源——專用 key 或 wrapper 字面 → bump 是預設，pin 就是 `version` → 「不 bump」是預設（改 published version 不做預設）。bump 由專用 fence 做：**逐檔單行字面替換**（manifest 的 `"<key>": "<old>"` 或每支 wrapper 的 `DESIRED_VERSION="<old>"` 那一行，每個目標恰一命中才一起寫；不 `json.dump`、不重排）、寫入前先查目標 release 真的有每支 wrapper 宣告的 asset、寫入後用 helper 重讀確認、印 `git diff --stat` 與復原指令；attended 下回 Step 2 重跑（落到 Case C，由 Phase 0.5 問怎麼 commit）。判定順序 **E → C → B → A**：pin 落後時先問，否則 Case C 會帶著舊 pin 同步 shell（2026-09-12 che-keychain 0.3.0 的實況）。取不到 latest（gh 未登入 / 網路 / 無 release / 非 x.y.z）→ `release_ahead=unknown`，印一行、不阻擋、不進 Case E。**unattended**：pin 來源是專用 key / wrapper 字面 → **Case E-auto**，同一個 fence 以 `AUTO_PUSH='yes'` 在 asset 預檢全 ok、樹乾淨、與 upstream 分歧 0 0 時自動改 + commit + push（refspec + 事後驗證；否則印 `AUDIT: … refused` 照 shell case 走）；pin 來源是 `version` → 不改、印 AUDIT、照 shell case 走。這是 common-release-flow「release 完自動跑 plugin-update」鏈唯一需要的寫入，也是 Phase 0.5 封閉列舉的第 (0) 項。
- `plugin-update` Phase 5 新增 **Step 1.5 binary-backed 驗證**（#22 第 5 點）：逐會下載的 wrapper 列（bin/；hook-only 佈局是 hooks/）對照它寫的 sidecar `~/bin/.<install name>.version` 與**它自己的** pin，印 ✅ / `PENDING-FETCH <name>=vX<vY`（pin 比已安裝新——剛 bump 完的預期狀態，wrapper 下次啟動才抓）/ `MISMATCH <name>=vX≠vY`（已安裝比 pin 新或不可比）/ `UNVERIFIED — k/N verified; …`（無 sidecar / 抽不到 install 名 / 無 pin，任一即不印 all N）/ `UNKNOWN` / `n/a`；不主動執行 wrapper、無 sidecar 不說 ✅；Step 3 最終 report 新增 `Phase 5: binary <…>` 一列；收尾 `remove_plugin_ctx` 在獨立的 Step 1.9（每次 invocation 必跑）。
- **verify R1 修正（#22）**（歷史紀錄；`plugin_binary_version_effective` 已於 R3 刪除）：helper 新增 `plugin_binary_version_effective`（binary_version → binaryVersion → **version**，印 `value|key`——拿掉 `version` 回退是錯的：che-apple-notes-mcp 的 wrapper 只讀 `version`、che-keychain 的 fallback 分支也讀它，本機 marketplace 13/13 binary-backed plugin 只有 `version`，R1 的寫法讓它們全部從「有 pin」變「無 pin」、Case E 與 Phase 5 ✅ 對真實 plugin 不可達；純 shell plugin 不拿 `version` 當 pin）、`plugin_binary_wrappers`（**逐 wrapper** 一列 `file|asset|install|repo`；R1 把 Phase 1.5 壓成每 plugin 一組，che-telegram-mcp 兩支 wrapper 只驗第一個卻印 `wrappers checked: 4`）、`plugin_install_names`（sidecar 的 key 是 INSTALL 名，不是 asset 名）、`release_assets`（Signal 1 走 gh，查不到說 UNKNOWN）；`plugin_binary_repo` 分級（`*_REPO=` 賦值 > release URL，bare `github.com/o/r` 文件連結不再是候選——R1 會選到 wrapper 註解裡的連結、拿別的 repo 的 tag 驅動 Case E；賦值必須是完整字面，`REPO="o/r${X}"` 回 rc 1 不回截斷前綴；縮排 / `export` 賦值也認；rc 2 只在同一級多值——che-things-mcp / che-zotero-mcp 的 hook 指向舊 fork 是真陽性）；`plugin_binary_name` 逐候選驗證（測試 stub 的 `BINARY_NAME="$binary_name"` 不再吃掉後面合法的名字）、`key` 改 local；wrapper 判定改「真的會下載 release」（test-wrapper-pid.sh 不算第三個 binary）；偵測 regex 改為**逐字**與 idd-close `has_binary_wrapper` 同一條（補 `gh api …/releases`、`api.github.com/.*/releases`）；wrapper 檔名過 allowlist 才進命中清單與貼給使用者的驗證指令；`PBM_GH` 只接受絕對路徑。SKILL.md：Phase 1.5 Step 2 恢復逐 wrapper（每列各自 Signal 1、每 repo 一次 Signal 2、結尾 `wrappers checked: k of N`、抽不到各印一行），hook-only 佈局明說走 Step 3 並停住；Case E 加「proceed without bumping（只同步 shell）」選項，unattended 下**不 abort**（印 `AUDIT: … not bumped under unattended`、照 shell 信號的 case 走——release 剛發完正是自動鏈跑的時刻），「一起 bump」拒絕把 plugin version 降版、key 是 version 時說明兩選項等價；Phase 5 Step 1.5 逐 install 名對 sidecar（`✅ … for all N` / `MISMATCH <name>=vX` / `UNVERIFIED (no sidecar for: …) k/N`）、標題明寫每個 plugin 都跑（收尾在此）；Phase 2 Step 2 補「entry 沒有 version 時加一行」的處方；Phase 1.5 Step 3 的 latest 正規化成 x.y.z、失敗訊息指 `$PLUGIN_DIR`；Case A 補 release-ahead 未核對註記；frontmatter allowed-tools 加 `gh` / `curl`。fence smoke 112 → 160（bump fence 三態、unattended E、多 binary `two`、hook-only、self-hosted `./plugin` marketplace `fx-self`）。
- **verify R2 修正（#22）**：R2 的「有效 pin = binary_version → binaryVersion → version」對真實 wrapper 是錯的前提——本機 22 支 wrapper / hook 實測：4 支的 pin 是 **wrapper 檔內字面** `DESIRED_VERSION="x.y.z"`（agent-cacher、che-latex-mcp、che-telegram-mcp ×2，從不讀 plugin.json；R2 對它們的 Phase 5 報假 MISMATCH）、8 支讀 plugin.json 的 `version`、3 支讀 `binaryVersion` / `binary_version` 再回退 `version`、1 支什麼都不讀。R3 改為 **pin 逐 wrapper 從 wrapper 本身讀**（`plugin_binary_wrappers` 列加 `dir|…|pin|pinsrc`，三種來源封閉列舉：檔內字面 / 檔內 grep 的 manifest key / none；`plugin_binary_pin` 匯總，wrapper 不一致 rc 2、全無 rc 1 → Case B no-pin 重新可達），刪除 `plugin_binary_version_effective`。其餘：`plugin_binary_repo` / `plugin_binary_name` / `plugin_install_names` 只看會下載 release 的 wrapper 檔（輔助檔的 `REPO=` 不能改指 repo）；`plugin_binary_wrappers` 帶 `dir` 欄，Phase 1.5 Step 2 只迭代 bin 列（hooks 列交 Step 3；分子分母同一集合），Step 3 守門改「hooks/ 有會下載 release 的檔」（不限 `session-start.sh`）且本機檔名用 install 名；`release_assets <repo> [tag]` 對 wrapper 自己的 pin tag 查、不合 allowlist 的名字印 `?`；`.mcp.json` 要 `mcpServers` 非空；hooks/ 不限 `*.sh`；`PBM_GH` / `PLUGIN_BIN_DIR` 只在 `PBM_TEST=1` 生效。SKILL.md：Case E 依 `pinsrc` 三分（manifest key / wrapper 字面 / `version`），第一個選項的標籤依來源改（`version` 時明寫「這會改 plugin 的 version」並套降版守門），bump 改**單行字面替換**（manifest 的 `"<key>": "<old>"` 或 wrapper 的 `DESIRED_VERSION="<old>"` 恰一命中才寫，不 `json.dump` 重排）並印復原指令；**unattended**：pin 來源是專用 key / wrapper 字面 → Case E-auto，bump fence 以 `AUTO_PUSH='yes'` 在樹乾淨且分歧 0 0 時自動改 + commit + push（Phase 2 Step 4 同一套 refspec + 事後驗證；否則印 `AUDIT: … refused` 照 shell case），`version` 來源 → 不改、印 AUDIT（Case A bullet 也印 pin 落後）——Phase 0.5 的封閉列舉加 (0)；Phase 5 Step 1.5 逐 bin wrapper 列對各自的 pin，抽不到 install 名 / 沒 pin / 沒 sidecar 任一即 `UNVERIFIED — k/N verified; …`（不印 all N），驗證指令只對合法檔名的 bin 列；收尾 `remove_plugin_ctx` 移到獨立 Step 1.9（每次必跑）；`SHELL_VERSION` / `CUR_VERSION` 過 allowlist；frontmatter 刪 `curl`、`gh` 收窄成 `gh release view`。helper 92 → 107 斷言；fence smoke 160 → 211（kc 改讀 binaryVersion、`two` 改字面 pin、`ver` 讀 version、`nopin`、`mixed` bin+hook、E-auto 三態、部分 unresolved）。
- **verify R3 修正（#22）**：R3 的「pin 逐 wrapper 讀」模型對了，但四處讀法讓它對真資料失效——(1) 「wrapper grep 哪個 key」的 regex 要求引號後直接接空白或冒號，macdoc marketplace 四個 plugin 寫的是 `'"binary_version"[[:space:]]*:'`（引號後是 `[`），全部被判 no-pin：改成非註解行上 `"<key>"` 後任意字元到 `:`（註解行不算——che-word-mcp 的註解先提 `"version"` 再提 `"binary_version"`，不濾會反序）；(2) `release_assets` 拿 pin 裸值當 tag 查，真實 tag 全是 `v` 前綴 → Signal 1 對每支有 pin 的 wrapper 永遠「未核對」：改成先查 `v<x.y.z>` 再查裸值，測試 stub 改成依 tag 回答、未知 tag 回「找不到」（之前的 stub 對任何 tag 都回 asset，這個洞因此活過三輪）；(3) hook-only 但有 pin 的佈局（macdoc：hook 讀 `binary_version` 再自己下載）被 `plugin_binary_pin` 的 bin-only 過濾丟掉 → Case E / Phase 5 對它不可達：改成「會下載的列」= 有 bin/ 時 bin/、沒有時 hooks/，Phase 5 與 Step 3 同一判準（Step 3 對有 pin 的 hook 比 pin、沒 pin 才比 latest，逐 hook 列印 k/N，exec 前再過一次 allowlist）；(4) 多支 wrapper 共用同一字面 pin（che-telegram-mcp）時 `plugin_binary_pin` 只印第一個來源、bump fence 只改一支就 commit+push，事後的 `plugin_binary_pin | cut` 又把 rc 丟掉：`plugin_binary_pin` 現在印**全部**來源（逗號串），bump fence 逐 wrapper 列建目標、先全部驗再一起寫、寫後重讀 rc 必須 0 且值等於新 pin 才 commit，`ALSO_VERSION` 的 version 一律在 manifest（字面 pin 時是第二個檔）。**Security**：`wrapper:<file>` 的檔名過 allowlist（不合法印 `wrapper:?`，列保持 7 欄）；`plugin_binary_repo` 有 bin/ wrapper 時只看 bin/——hooks/ 的 check script 指向舊 fork 不能決定 E-auto 追哪個 remote 的 tag（che-things-mcp / che-zotero-mcp 現在 rc 0 取 bin 的 repo）；E-auto 多一道 asset 預檢，且 `version` 來源在 attended 也不再是預設選項。其餘：asset 名只認宣告的 `RELEASE_ASSET=` / `ASSET_NAME=` / `BINARY_NAME=`（che-keychain 用的是 `RELEASE_ASSET`；不再從 install 名猜——猜錯會變成假的「asset 缺 → mcp-deploy」）；wrapper 點名 key 而 manifest 沒值 → rc 4 `pin-unreadable`（不再誤報「wrapper 不讀 plugin.json」）、wrapper 各自 pin 不同 → `pin-conflict`，兩者與 no-pin / no-clone 是 Case B 的四個封閉子態；Phase 5 不再依 install 名提前去重（同名 binary、不同 pin 的第二支各自比對）；`*_REPO=` 衝突訊息印 file|repo；attended Case E 印 `shell_case=` 供「不 bump」派發；release URL 只在非註解行算下載；`plugin_bin_dir` 公開；語料統計改為 26 支（含 macdoc 四個）。helper 107 → 127 斷言；fence smoke 211 → 272（kc 宣告 `RELEASE_ASSET` + Signal 1 ✅、`ver` 未知 tag → 未核對、`two` asset 缺拒絕 / 一起 bump 三檔 / E-auto 兩支同改、`dup` 同名不同 pin、`kl` pin-unreadable、`hp` hook-only 有 pin 走 Case E / E-auto / Phase 5 / Step 3）。
- **verify R4 修正（#22）**：Case E bump fence 的 asset 預檢狀態改成只升不降（missing > unknown > ok——之前每列無條件覆寫，第一支已知缺 asset、第二支查不到就被蓋成 unknown 而放行）；所有拒絕路徑走同一個出口：attended 印 ✗ 回 1、unattended 印 `AUDIT: … refused` 回 75（asset 缺這個最主要的拒絕理由先前繞過 AUDIT）；替換以檔案為鍵累積（兩支 wrapper 各讀 `binary_version` / `binaryVersion` 時同一 manifest 只寫一次，不互相還原）；wrapper 指向多個 repo → Phase 0.3 (e) `release_ahead=unknown` 且 bump 拒絕（latest 只屬於一個 repo，不能寫進每支）；Case B 加第五個子態 `no-wrapper`（manifest 有 pin 但 bin/ 與 hooks/ 沒有任何檔案會下載）；Phase 5 分 `PENDING-FETCH`（pin 比已安裝新）與 `MISMATCH`；mixed 佈局（bin + 會下載的 hook）在 Step 2 / Step 3 / Phase 5 明說「hook 的下載未核對」而不是指向必定 skip 的 Step 3；Signal 2 沒有 plugin 層 pin 時明說略過；Step 3 的本機目錄改用 `plugin_bin_dir`；`_pbm_file_repo_tier2` / `_pbm_file_home_bin_name` 也只看非註解行（註解裡的 release URL / `$HOME/bin/<name>` 不能決定 repo 或被執行的檔名）；`BINARY_NAME=` 只在非註解行用它下載（`releases/download/…/$BINARY_NAME`、`--pattern`、`browser_download_url`）時才算 asset 名，否則 asset 未宣告 → 預檢「未預檢」而非 blocker；bump 的 writer 與 reader 同樣接受 `local DESIRED_VERSION=`。**兩條 R1 起就有、之前沒入冊的硬 abort**：Phase 0.3 Step 2 對 plugin.json 的 `version` 缺或含 `[0-9A-Za-z.+-]` 以外字元 abort（沒有可比的值）、Phase 2 Step 4 對 marketplace entry 的 `version` 非法 abort（與既有 `NEW_VERSION` allowlist 一致）。helper 127 → 133 斷言；fence smoke 272 → 305（`lat` missing-then-unknown 拒絕 + E-auto AUDIT/75、`tk` 兩 key 同 manifest、`mr` 多 repo、`nw` no-wrapper、kc/two/dup 的 PENDING-FETCH 與真 MISMATCH、hp Step 3 用 seam 目錄執行本機 CLI）。
- **verify R5 修正（#22）**：helper 兩個讀法邊界——(1) `plugin_binary_repo` 先對所有 wrapper 收 `*_REPO=` 賦值、有任何一個就不看 URL 字面，一支賦值 `a/one` + 一支 URL 字面 `b/two` 被讀成單一 repo rc 0：改成**逐檔**分級（`_pbm_file_repo`）再跨檔合併，不同即 rc 2；(2) `_pbm_file_pin` 取檔內第一個 `DESIRED_VERSION="x.y.z"` 字面，`DESIRED_VERSION="1.0.0"` 之後接 `$(grep … "$PLUGIN_JSON")` 的「預設值再讀 manifest」寫法會被讀成過期預設：改成字面只在它是**最後一個** `DESIRED_VERSION=` 賦值時算數，最後一個讀不出來又沒點名 key → `|wrapper:<file>` rc 4（來源說得出、值讀不到）。issue 第 2 點「從 URL 抽、不靠變數名」：`*_REPO=` 賦值現在只在**該變數被用進 release 下載行**（`$REPO` / `${REPO}` 出現在符合 release URL 形狀或 `--repo` 的非註解行）時才算——沒被用的 `DOCS_REPO=` 不是候選，賦值只是 URL 裡那個變數的值。Case E bump fence：逐檔 temp + `os.replace` 寫入，寫入階段失敗印 `write-failed: written=[…] pending=[…]` 並明說**已改**的檔案與復原指令（不再說「沒有任何檔案被改」）；E-auto 寫後 commit / push 失敗印 `AUDIT: … FAILED after write — …`（不是裸 ✗）。Phase 5：PENDING-FETCH 的括號句改成「asset 只有 Signal 1 對這個 tag 查到時才算核對過」；hook-only 佈局的「要驗證」印 hook 檔而不是字面 `<wrapper> --version`。測試座標：`PBM_GH` / `PLUGIN_BIN_DIR` 要 `PBM_TEST=1` **且** `PBM_TEST_ROOT` 已設 **且** `$PWD` 在其下才生效（R7 起 `PBM_TEST_ROOT` 必須是系統 temp 樹下的真實目錄——`/`、`$HOME` 都不算——用實體路徑比對；這把座標縮到 mktemp 的範圍，不是 sandbox：checkout 在 /tmp 底下的 marketplace 不受它保護）；`BINARY_NAME` 的字面值進 ERE 前轉義 `.`。helper 133 → 143 斷言；fence smoke 305 → 314（寫入階段失敗、E-auto push 失敗的 AUDIT、hp 的 hook 驗證指令）。
- **verify R6 修正（#22）**：R6 把 bump fence 的寫入改成 temp + `os.replace` 時掉了兩件事——新 inode 用 umask 預設權限，**0755 的 wrapper 變 0644**（E-auto 還會把 100755→100644 push 出去；che-telegram-mcp / che-latex-mcp / agent-cacher 這些字面 pin 的 wrapper 正是會被改的檔），而固定的 `<path>.pbm-tmp` 暫存名可被預先放的 symlink 帶到 marketplace 之外。改成 `tempfile.mkstemp`（O_EXCL、不可預測、在目標同目錄）+ 複製原 mode + `os.replace`；寫入之後的失敗走 `refuse_after_write()`（印 `FAILED after write — …; files rewritten: …`，不再說 left as is、不叫 unattended 帶著半改的樹照 shell case 走）。其餘：七處 `source plugin-binary-meta.sh` 改 fail-closed（載不到就 abort，不得印成「非 binary-backed」）；`PBM_TEST_ROOT` 須為系統 temp 樹下的真實目錄（`PBM_TEST_ROOT=/` 曾能讓前綴比對匹配所有 cwd）；`DESIRED_VERSION=` 出現在行內（`[ -z "$X" ] || DESIRED_VERSION="$X"`）也算「最後一次賦值」→ 讀不出即 rc 4；wrapper 用 jq / python 讀 `binaryVersion`（沒有 `"key":` 形狀）→ rc 4 帶 key，不再是「不讀任何版本」；`DESIRED_VERSION="latest"` 這種移動 ref 不是 pin（`_pbm_pin_ok` 要求數字開頭）→ rc 4，Phase 5 不再對它永久報 MISMATCH；bump fence 對 pin 本身加 rollback 守門（`NEW_PIN` 不比目前 pin 新就拒絕）；Phase 1.5 Step 2 的 `wrappers checked` 只算 Signal 1 真的查到的列（gh 查不到的另列 `unchecked`），pinned tag 缺 asset 的處方改成「補傳到該 tag 或 bump pin」（`mcp-deploy` 只發新 release）；Step 3 對 pin 也正規化成 x.y.z；Phase 5 結論一行列出全部狀態（MISMATCH 與 PENDING-FETCH 同時存在時都進 report）；E-auto 的 AUDIT 註明 unattended 來自 `IDD_ALL_UNATTENDED=1`；CLAUDE.md 的「Phase 2 Step 1 只消費 helper」改成實情（Step 1 列全表用 inline python `.get`，Step 4 走 helper）。helper 143 → 150 斷言；fence smoke 314 → 328（exec bit 保留 + git 無 mode change、預置 symlink 目標不動、rollback 拒絕、helper 缺失 fail-closed、Phase 2 Step 4 缺 version 分支、E-auto 寫入失敗的 FAILED after write）。
- **verify R7 修正（#22）**：E-auto 的 staging 迴圈逐檔檢查 `git add` 退出碼、commit 前確認每個目標 index == 工作樹（半 stage 的 commit 會 push 出只改一半的 pin；`filter.<x>.required` 的 clean filter 失敗即 `FAILED after write — git add 失敗`）；`_pbm_file_pin` 對「最後一次賦值不是字面也不是 manifest 讀取」（manifest 讀取後接 `${PIN_OVERRIDE:-…}`）回 rc 4 而不是拿較早的 manifest key 當 pin；`plugin_binary_pin` 對「一支讀得到、另一支讀不出」的 partial 狀態只印來源不印值（header 的「不印看起來合理的預設值」在這裡守住）；測試座標的 `$TMPDIR` 先解析、解析不到就關（`TMPDIR` 指向不存在目錄曾讓 pattern 退化成 `/?*`），座標的自述改成「縮小座標、不是 sandbox、PATH 本來就能換 gh」，測試改在 `$HOME` 之下的 cwd 驗證；Phase 5 的 PENDING-FETCH 結論行也帶其他未驗證狀態與 k/N；Phase 1.5 Step 3 的 `hooks checked` 只算真的比對過的列、pin 不是 x.y.z 時明說；Phase 0.3 / 1.5 的 rc 4 訊息對多來源清單改用泛稱；Case B no-pin 模板改成 wrapper pin 模型（「在 plugin.json 補 key」對不讀 key 的 wrapper 是 no-op，處方是給 wrapper 一個 pin）、no-clone / release 文案同步；Phase 0.5 三個 abort 選項描述都提醒「本次若走過 Case E bump，pin 改動仍在工作樹」；Phase 5 ✅ 行數的是 wrapper 列；`detect_binary_repo` 說明對齊新簽章。helper 150 → 157 斷言；fence smoke 328 → 336（staging 失敗、PENDING-FETCH + unresolved 同行、Step 3 未比對不算 checked、count= 精確斷言）。
- **verify R8 修正（#22）**：`_pbm_file_pin` 改成照 shell 的求值順序讀 `DESIRED_VERSION` 的**賦值鏈**——行首的賦值是無條件覆寫（重設鏈），縮排或 `||` 後的是有條件 fallback（接在後面），只提到 `DESIRED_VERSION=` 的 echo / grep 行不算賦值；兩次無條件 manifest 讀取取**最後**一個 key（先前取第一個，bump 會改到 wrapper 沒在用的欄位），manifest 讀取後接縮排的字面預設值時，key 有值用 key、沒值才用字面，鏈上任何一環讀不出就 rc 4；`_pbm_file_repo` 回傳該檔**全部**的 repo 候選（`head -1` 曾把 primary || fallback 的第二個 repo 截掉，單檔雙 repo 因此繞過「多 repo 不自動 bump」），列的 repo 欄對單檔多 repo 留空，Case E bump fence 另以 `plugin_binary_repo` rc 2 拒絕；repo 賦值不再限 `*REPO` 變數名，而是要求變數出現在 release 下載的 repo 位置（`repos/$X/`、`github.com/$X/releases`、`--repo "$X"`——issue 第 2 點的「從 URL 抽、不靠變數名」）；tier 2 認帶引號的 gh 慣用寫法（`--repo "o/r"`、`gh api "repos/o/r/…"`）且 host 錨定（`notgithub.example/o/r/releases/…` 不是 GitHub repo）；`plugin_is_binary_backed` 對讀不動的 `.mcp.json` / manifest 回 rc 4 `unknown:<probe>`，Phase 0.3 Step 1 印 `IS_BINARY_BACKED=unknown`、Step 2 abort、Phase 5 印 UNKNOWN（不再折成「非 binary-backed」）；E-auto 拒絕 `ALSO_VERSION=yes`（unattended 只改 pin，最後一道防線）；Phase 1.5 Step 2 對 asset 名無法顯示的 release 不算 checked、列進 unchecked；Phase 5 MISMATCH 行也帶 k/N；Phase 2 Step 1 印 marketplace 的 name / version 前過 allowlist（換行可偽造狀態行）；Phase 2 Step 4 的 helper 守門改查它真正用的 `marketplace_entry_version`、訊息講 marketplace entry 而不是 binary 判定；rc 4 wrapper 訊息涵蓋非 x.y.z 字面；helper header 的 distribution-detection 參照寫明在 issue-driven-development repo。helper 157 → 171 斷言；fence smoke 336 → 358（asset 名無法顯示不算 checked、MISMATCH k/N、E-auto 拒 ALSO_VERSION 且零寫入、attended 寫入失敗、單檔雙 repo 拒絕、壞 .mcp.json 三處 unknown、Phase 2 Step 1 allowlist）。
- `scripts/test-plugin-update-fences.sh` 新增 che-keychain 形 fixture `kc`（`bin/kc` 無副檔名、`REPO=` / `INSTALL_NAME=`、`binaryVersion`、marketplace entry **無** `version`、hook 只委派不 curl）+ `PBM_GH` stub + `PLUGIN_BIN_DIR` sidecar：Step 1 命中清單、Step 2 Case E / `release_ahead=9.9.9` / stub 失敗 → unknown 且非 E、entry 缺 version 的專屬訊息、Phase 2 Step 1 `(missing — will be set from plugin.json)`、Phase 5 Step 1.5 三態 + 純 shell `n/a`；79 → 112 斷言。
- `resolve-marketplace.sh`：`resolve_plugin_dir <root> <plugin>` 從 manifest 的 `plugins[].source` 解析 plugin 目錄（正規化 `//`、`/./`）；manifest 給不出可用本地目錄時（無 entry、source 不可用、git-subdir 物件、URL、JSON 壞掉或形狀不對、python3 缺席或跑不起來）退回探 `plugins/<name>`，兩者都失敗才回 rc 1 / 2 / 3 / 4 / 5 / 6（未列 / 不可用 / 無 python3 / 讀不動 / 非本地 / 名稱不合法）；`.` 與 `./` 解析為 root（repo 即 plugin）；持有判準一套（manifest 路徑與 legacy `plugins/<name>` 共用）：目錄帶 plugin manifest（`.claude-plugin/plugin.json` **或根目錄 `plugin.json`**，safari-browser 等佈局）就必須解析得動且 `name` 等於請求名（JSON 壞掉或無 name 一律不算——宣告不等於持有），沒有 manifest 時目錄名要等於請求名且有 plugin 形狀（空目錄不算）；有 entry 但 source 不可用（含 typo、含尾端換行等控制字元）是確定的 rc 2、不退回 legacy；兩者都做實體包含檢查；名稱不得以 `.` 或 `-` 開頭；`plugin_names_for_paths` 對解析失敗的名稱印 stderr 警告而非靜默略過。另新增 `plugin_source_of`（已消毒）、`marketplace_plugin_names`（manifest 宣告 ∪ `plugins/` 子目錄，只回傳合法名稱）、`plugin_names_for_paths`（路徑 → plugin 名，以 `git rev-parse --show-prefix` 對齊巢狀 marketplace，root-sourced plugin 擁有全部路徑）、`marketplace_index`、`write_plugin_ctx` / `load_plugin_ctx`（#18）。

### Fixed
- `plugin-update` 對 binary-backed plugin 的五個靜默失效（#22；2026-09-12 che-keychain 0.3.0 上架時五個 phase 全部沒作用也不報錯）：(1) 欄位名——Phase 0.3 Step 2 / Phase 1.5 Signal 2 / Phase 5 改讀 helper：兩種拼法都認，而且（R3）pin 由 wrapper 自己決定——wrapper 讀 `version` 的 plugin（che-apple-notes-mcp 等 8 支）`version` 就是 binary tag，wrapper 有字面 `DESIRED_VERSION` 的（4 支）manifest 根本不是來源；先前的 `or d.get("version")` 對前者對、對後者錯，R1 全部拿掉又對前者錯；(2) 偵測——Phase 0.3 Step 1 / Step 2 與 Phase 1.5 Step 1 表格改 `plugin_is_binary_backed`（`bin/` 任何檔案含 release URL，不限 `*-wrapper.sh`、不限 `GITHUB_REPO=`；hook 委派給 wrapper 的佈局由 bin/ 那一列接住），Phase 1.5 Step 2 的 wrapper 列表改 `find -type f`，repo / binary 名改 `plugin_binary_repo` / `plugin_binary_name`（每 plugin 一次，抽不到各印一行、多 repo 印出取第一個），Step 3 CLI 情境同；(3) release 之後的正向信號——見 Added 的 Case E；(4) marketplace entry 缺 `version`——Phase 0.3 (b) 以 rc 分「entry 不存在（Step 3 新增）」與「缺 version（Step 2 補上）」各印各的理由（先前是 `'' != x` 剛好判成 drift），Phase 2 Step 1 用 `.get` 印 `(missing — will be set from plugin.json)`（先前 `p['version']` KeyError），Phase 2 Step 4 對兩種情況給不同處方；(5) Phase 5 只看 `claude plugin list`——見 Added 的 Step 1.5。Phase 1.5 Step 3 的 `curl …/releases/latest` 改 `latest_release_version`（走 gh、與 Phase 0.3 (e) 共用 stub）。Step 0 的 `sync_intent_gate` / `verify_and_report` 描述同步。
- `plugin-update` Phase 0.3 / 0.5 兩道 gate 判準正交造成的誤攔（#19）：Phase 0.3 現在對**所有** plugin 執行 Step 2（純 shell plugin 的 binary 信號為空；`MP_DRIFT` 與 30 天內 shell 變更本來就跟 binary 無關，先前「非 binary-backed 跳過 0.3」讓純 shell plugin 在 Phase 2 之前沒有任何地方判定 marketplace 落後、也沒有 no-op 早退）；Phase 0.5 的 Case A 從「clean + 0 unpushed → abort 並建議 bypass 跑 `claude plugin marketplace update`」改為 **clean start → 通過**——這道 gate 問的是「樹上既有、不屬於本次 sync 的東西要不要一起推」，Phase 2 的 sync commit 在 0.5 這個時間點還不存在；unattended（idd-all）下 Case A 通過、E' 照常 ff-only 後重測、只有 Case B / C / D / E auto-abort（封閉列舉）；Case A 放行後首次可達的兩道互動閘各補 unattended 分支——Phase 1.5 Step 4（binary 不同步 → auto-abort + audit）、Phase 2.5 Step 2（README stale → 自動「先略過」並在 report 標註）；Phase 0.3 Step 2 新增 `SHELL_DIRTY`（plugin 目錄下未提交的改動）信號——沉睡 30 天的 plugin 改完未 commit 不再被 Case A 用假的「30 天內沒改」擋掉（本機 18/32 個 plugin 落在這條路）；Phase 2 Step 4 只在 marketplace.json 真的有變更時才 commit + push（`MP_DRIFT=no` 的 Case C 不再撞上「nothing to commit」被洗成成功），push 前印出 Phase 0.5 之後混進來的 commit；Phase 0.5 的「任何 state-mutating 前必有人確認」「user 選了 push」「統一 abort」等敘述收斂到 Case B–E，並明寫 clean start 下 marketplace.json 的鏡像 commit 會不經人工確認被 push；`test-plugin-update-fences.sh` 加純 shell fixture（乾淨 / 未提交 / 落差 / 未推送四情境、Case A fence 拒絕誤判並保留 context、Phase 2 Step 4 已同步跳過 / Edit 沒落地 abort / 有落差時真的 push 到 upstream）36 → 71；R2 後補：Phase 0.3 Step 2 再加 `SHELL_UNPUSHED`（未推送且動到 plugin 目錄或 marketplace.json 的 commit）並把 `SHELL_DIRTY` 的 pathspec 含 marketplace.json、Case A 的「bypass 刷 cache」建議只在 repo 0 未推送時才印；Phase 0.5 Case A 的 fence 自己重驗 clean + 0 unpushed（誤判即拒絕，fail-safe）；Case E' 有專用 fence（ff-only 成功回 Step 2 重測、失敗 abort 不重試）；Phase 2 Step 4 先驗 marketplace.json 的 entry 版本等於 plugin.json（Edit 沒落地即 abort，不再謊報「已同步」），push 退回裸 `git push`（R2 一度改成 `git push origin HEAD`，本地 branch 名 ≠ upstream 名時會在 origin 開新分支還印 pushed——已撤回），有混進的 commit 時做 Step 5 同款的 plugin 歸屬分析；unattended 下不經人工確認會發生的動作改為封閉列舉（Phase 2 鏡像 push、Phase 3 marketplace update、Phase 4 plugin update / install）；Phase 1.5 Step 4 與 Phase 2.5 Step 2 的狀況表各加 unattended 列；R4：Phase 2 Step 4 重構——先驗 marketplace.json 的 entry 版本（entry 不存在 / Edit 沒落地分開指引、值經 clean）、有變更才 commit、以 `@{u}..HEAD` 判斷是否需 push（已 commit 未推送的鏡像會被推，不再印「已同步」）、push 明寫從 `@{u}` 拆出的 remote 與 `HEAD:refs/heads/<branch>`（裸 `git push` 在 `push.default=current` / `matching` 下仍會開新分支或什麼都不推卻 rc 0）、push 後驗 `@{u}` == HEAD 才印成功、混進的 commit 做 Step 5 同款歸屬並計未解析名稱；Phase 0.3 先解 `@{u}`（解不到 abort，不再靜默當 0）且計數不再被 `head -10` 截斷；Phase 0.5 Case A 的 fence 驗 divergence 雙零（純 behind 也拒絕）、退出碼 75；Case E' 的 fence 印出 ff 後的新狀態、回 Step 1 重跑 preview、每次 invocation 最多一次；Phase 5 新增 Step 3 最終 report（收錄 Phase 1.5 / 2.5 的 `AUDIT:` 行）；fence 內 `$VAR` 緊接非 ASCII 一律 `${VAR}`（bash 會把該字的第一個位元組併進變數名，值整個消失；plugin-debug 兩處同修）；smoke test 71 → 79（Case A 純 behind 拒絕、無 upstream 時 Phase 0.3 abort、已 commit 未推送的鏡像被 push、`push.default=current` + 本地 branch 改名仍推到 tracked ref 且不開新分支）。2026-08-31 che-apple-mail-mcp 3.0.0 的實例：30 天內改過 ∧ 樹乾淨，0.3 Case C「繼續」與 0.5 Case A「exit 0」同時成立。
- 單一 plugin marketplace（`"source": "./plugin"`，如 che-keychain / che-apple-mail-mcp / che-ical-mcp）在 `plugin-update` Step 0.1 被判為「不在任何 marketplace」，繞過後 Phase 0.3 / 1.5 / 2.5 的偵測全部對不存在的目錄回答「沒有」（#18）。
- 巢狀同名 marketplace 的解析目標：che-local-plugins 命中的是**父層** che-claude-config（其 source 指進子 checkout）而非子層——父層才是 `known_marketplaces.json` 註冊、實際被 clone 與服務的那份；舊行為把版本寫進不會被服務的子層 manifest（兩份長期分岔）。R8 起 `marketplace_candidates` / `resolve_marketplace_root` 與 `find_plugin_marketplace` / `plugin_holders` 套同一條規則：**巢狀在另一個同名候選裡的 root 是它的 subtree，不算第二份 checkout**（`_drop_nested_roots`），`plugins/` tie-break 只在真的多份 checkout 時適用（反轉 2.4.0 #20 對 che-local-plugins 的預期；`plugin-upgrade` / `plugin-health` / `tool-readme-sync-plugin.md` 經 `resolve_marketplace_root` 也因此指向父層——它們的 `plugins/<name>` 硬編仍在 #23）。`plugin_holders` 以「marketplace 名 + 實體目錄」去重並保留最外層 root，不同名的 marketplace 列同一個目錄仍是兩個持有者。這是語意變更，不是副作用（#18 verify R6/R8）。

## [2.4.0] - 2026-09-01

### Changed

- **`resolve-marketplace.sh` 改為發現式，不再硬編列舉**（#20）。原本兩份必須手動
  同步的清單——`MARKETPLACE_NAMES` 與 `resolve_marketplace_root` 的 `case`——各只有
  4 筆。實測本機 38 份 manifest、24 個相異 marketplace：**硬編漏掉 20 個**，含
  `macdoc`、`bestasr`、`issue-driven-development`。零假陰性（硬編知道的 4 個掃描全
  找得到），所以那是純覆蓋率缺口、不是取捨。

  後果不只是「找不到」。`plugin-update` 的 Phase 0.1 gate 會 abort 並建議去
  `plugin-deploy` / `plugin-create`——**對一個已上架且安裝好的 plugin，那是錯的補救
  方向**。

  改法：掃 `~/Developer` 底下的 `*/.claude-plugin/marketplace.json`（`find`，最多 4
  層），讀各檔**自報的 `name`**。名稱與目錄名 13/33 不同（`bestasr` 住在
  `bestASR-project/bestASR`），所以目錄名不能當身分。**新增 marketplace 不再需要改
  任何程式碼。**

  三個既有函式的簽章與回傳格式不變（14 個 consumer 不必動）。

### Added

- **`marketplace_candidates <name>`**——回傳所有命中的 root，一行一個，precedence
  序。契約對齊姊妹檔 `resolve-mcp-project.sh` 的 `mcp_project_candidates`：讓 caller
  與測試**看得到** shadowing，而不是靠推測。

### Fixed

- **同名多候選的消歧**。`che-local-plugins` 有兩份 manifest 自報同名：父層
  `che-claude-config` 是 aggregator（source 指進子層、自己沒有 `plugins/`），子層才是
  實體 marketplace。規則是**擁有 `plugins/` 的候選優先**。

  這條規則**只在同名多候選時當 tie-break，不是全域准入條件**——實作中途曾把它當成
  後者，結果砍掉 9 個合法 marketplace（`rush`、`che-keychain`、`che-ical-mcp`…）：
  那類 repo 本身就是那個 plugin，manifest 的 source 寫 `./plugin`（**單數**）。等於
  一邊修 #20 的覆蓋率缺口、一邊用另一個機制把它重新造出來。已有 fixture 測試釘住。

- **`find_plugin_marketplace` 查一個 plugin 會噴出別的 marketplace 的警告。** 它對每個
  名稱各呼叫一次 `resolve_marketplace_root`，而後者在同名多候選時會 warn ——於是查
  `macdoc` 會印出 `che-apple-mail-mcp` 的多重 checkout 警告。那個警告對**呼叫者指名**
  的 marketplace 是對的，對這輪掃描剛好走過的則純屬雜訊。同一個迴圈也讓一次查詢重建
  33 次索引。改成直接走訪索引一次。

  **`[ -d "$root/plugins/$plugin" ]` 那行沒有動**——它是 [#18](https://github.com/PsychQuant/che-plugin-devtools/issues/18)
  的範圍。本次只改列舉候選的方式。

- **git worktree 不得被選中**。選中它會讓 `plugin-update` 的 Phase 0.5 git gate 跑在
  worktree 上，正是 #16 要防的「gate 跑在錯的 repo 上」換一條路徑進來。

  判別 `--git-dir` ≠ `--git-common-dir`，但**兩者必須先正規化成絕對路徑**：git 會回
  相對當下 cwd 較短的那個形式，從 main checkout 的子目錄查會拿到絕對的 `--git-dir`
  配相對的 `../.git`。直接比字串會把**每一個這樣的子目錄**都判成 worktree——實際踩到，
  `che-local-plugins` 因此完全解析不到。

### Performance

一次完整掃描 **0.90s → 0.25s**，測試 suite **103.6s → 21s**。兩處，都是砍 spawn：

- **worktree 判定加了無 subprocess 的快路徑。** 原本每個候選一次 `git rev-parse`。
  改成先往上走到最近的 `.git` 看型態：**是目錄就必定是 main checkout、不可能是
  worktree**，直接判定——38 個候選裡 33 個走這條。只有 `.git` 是**檔案**時才呼叫 git，
  因為 linked worktree 與 submodule 都用檔案（本機那 5 個檔案裡有 2 個是 submodule），
  這一格確實不能只看型態決定。git 呼叫 38 → 5。

- **`find_plugin_marketplace` 一次查詢從 33 次索引重建降為 1 次**（見 Fixed）。

- **走訪與剖析改用 shell 內建。** `dirname` 換成 `${var%/*}`（每個 manifest 省 2 次、
  walk-up 每層各省 1 次），抽名字的 `sed | sed | head` 併成單一 sed。約 340 次 spawn
  降到約 40 次。合併後的 sed 在真實的多行 manifest 上與原三段式輸出相同；單行 JSON
  兩者都回空字串、同樣退回 `python3` fallback，行為未變。

**不做 shell 變數快取**（曾實作、已移除）。所有呼叫點都是
`$(resolve_marketplace_root x)`，函式整個跑在子 shell 裡，它設的變數回不到父 shell
——那份快取一次都沒生效。留著會讓讀者以為有快取，比沒有更糟。

提案階段寫的是「不加快取，已量測 0.079s」。那個數字**只量了 sed 抽名字**，沒把
worktree 偵測算進去；結論碰巧對，但依據是錯的。真正的成本在 spawn，所以修在那裡。

## [2.3.0] - 2026-08-26

### Fixed

- **`plugin-deploy` Step 2.5 的 BLOCK 對 75% 的 wrapper 從沒執行過**（#17）。
  它靠 `grep '^BINARY_NAME='` 與 `grep '^GITHUB_REPO='` 認出要查什麼，**抽不到就
  `continue`**——不 echo、不計入 `MCP_STALE`、不影響結束碼。使用者看到一片安靜，
  而 deploy 照常往下走。

  實測 `psychquant-claude-plugins` 的 12 個真實 wrapper：**只有 3 個**兩行都抽得到。
  野生有三種方言——`GITHUB_REPO=`+`BINARY_NAME=`、**`REPO=`**+`BINARY_NAME=`（8 個）、
  以及 binary 名當函式參數（agent-cacher、claude-ltm）。

  修法**不是**再多列舉一種寫法（雖然順手多認了 `REPO=`，那只減少誤報、不是保證）
  ——下一個方言還會出現。判準改成：**抽不出來就代表沒驗過，那必須說出來。**
  抽不到的 wrapper 逐一具名報出，並用 AskUserQuestion 三選一（已手動確認 /
  去補 wrapper / 中止），**預設中止**。

  修正後涵蓋率 25% → 92%，剩下的一個不再靜默。

- **`plugin-update` Phase 1.5 Signal 1 同一段**，同樣改成具名報出（該處是 warn 不是
  BLOCK，符合 plugin-update 的協助型定位，但沉默與「檢查過沒問題」不可區分）。

### 這是同一個失敗類別的第三次

`#16` 修的兩個（`resolve-marketplace.sh` 的 zsh word-split、`plugin-update` 不檢查
回傳碼）與本次是同一形狀：**失敗變成空字串，然後被當成沒事**。三次都不是「寫錯
邏輯」，是**沒有問「這個 API 失敗時我怎麼知道」**。

## [2.2.0] - 2026-08-26

### Fixed

- **`resolve-marketplace.sh` 在 zsh 下對每一個 plugin 都解析失敗**（#16）。
  `for mp in $MARKETPLACE_NAMES` 依賴 unquoted 變數的 word-split，而 zsh 預設不做
  那件事。這個檔案是被 `source` 的，所以跑它的是呼叫端的 shell——`#!/bin/bash`
  那行不生效，而 **Claude Code 的 Bash 工具跑在 zsh**。實測 `find_plugin_marketplace
  harness-devtools` 在 bash 回 0 並印出正確結果、在 zsh 回 1 且無輸出。改成換行
  分隔 + `while read`（here-doc，不是 pipe——pipe 的 subshell 會讓 `return 0` 只
  結束子 shell）。五個 skill 都 source 它。
- **`plugin-update` Phase 0 不檢查 marketplace 解析失敗**（#16）。`MP_NAME` /
  `MP_ROOT` 靜默變空字串後，Phase 0.3 的 `PLUGIN_DIR` 變成 `/plugins/<name>`
  （binary gate 整個失效），Phase 0.5 的 `cd "$MP_ROOT"` 成為 no-op ——**git state
  gate 因此跑在使用者當下所在的 repo 上，並邀請他 push 一個不相干的 repo**。
  新增 Step 0.1 marketplace resolution gate，abort 並指出正確的下一步
  （`plugin-deploy` 首次上架 / `plugin-create` / binary-backed 要先 `mcp-deploy`）。

### Added

- 測試套件新增 zsh 分支。先前整份測試只跑 bash（檔頭逐字寫著
  "Deliberately runs under /bin/bash"），**那正是上面第一個 bug 活下來的原因**。
  變異確認：改回空白分隔後 zsh 兩條紅、bash 全部照樣綠。
- README 新增「哪個 skill、什麼順序」段。先前 24 個 skill 逐條列出但沒有任何一處
  說明首次上架與後續同步的差別，而 `plugin-update` 的描述（marketplace.json 同步 +
  安裝檢查）字面上讀起來就像涵蓋首次上架。

## [2.1.0] - 2026-08-01

`mcp-upgrade` 新增 MCP protocol 版本維度，並修正它 description 與實作矛盾之處。做的是 #14。

### Added

- **`mcp-upgrade` Phase 1.5：Protocol 版本檢查（語言無關）**。

  Phase 1 查的是 **SDK 套件版本**（`swift-sdk 0.12.0`），Phase 1.5 查的是 **protocol 版本**（`YYYY-MM-DD`）—— 兩者是不同的東西，升一個不保證升另一個。此前 24 個 skill **沒有任何一個**處理後者（`grep -rl protocolVersion skills/` 零命中）。

  三段結構：

  1. **現查官方 current 版本** —— 版本號**不寫進 skill**。protocol 每隔數月換一次，寫死等於埋一個保證過期的事實（本輪 #11 剛因為同一個形狀吃虧）。
  2. **偵測專案宣告** —— 分三種情況判定，風險不同：硬編碼（最高，SDK 升級也不會帶動）／引用 SDK 常數（中）／未宣告（低）。
  3. **判定遷移工作量** —— 跨 breaking change 時列出該版 Negotiation 段實際要求的必要項，不報告成「改個字串」。

  「落後幾代」從 spec repo 的 `docs/specification/` 目錄取完整版本序列計算（`llms.txt` 只給 current 一個）。日期字串按 `YYYY-MM-DD` 字典序比較即等同時間序。取不到序列時**退回只報「落後 / 未落後」** —— 報不出代數是可接受的降級，報錯的代數不是。

  同步擴充 Phase 4 報告（新增 `🔌 Protocol 版本` 段）與 Phase 5 執行選項（落後時才出現「Protocol 版本遷移」）。

### Fixed

- **`mcp-upgrade` description 與實作矛盾**。原文寫「本 skill 只分析與提議、**不改動 code**」，但它的 `allowed-tools` 含 `Write, Edit`，且 Phase 5「等待核可並執行」會編輯 `Package.swift`、跑 `swift package update` / `npm update` / `pip install --upgrade`。

  那句話是 v2.0.0（27 個 description 重寫）時寫的 —— 當時讀了 Phase 0–3 就下結論，**沒讀到 Phase 5**。而該次自訂的流程第 2 條正是「讀該 skill 的 SKILL.md body，觸發語要從它實際會做的事提煉，不能憑名字猜」；照做了，但讀得不夠遠。新 description 明確寫出「核可的項目才動手改」及會執行的實際指令。

- **偵測腳本漏排除建置產物**（實作過程中自己踩到並修正）。`.build/checkouts/` 底下是整包 MCP SDK 原始碼，當然含 `protocolVersion` 與各版本日期；不排除的話，一個「未宣告、完全交給 SDK」的乾淨專案會被報成「硬編碼三個版本」。

  **這個坑在 Claude Code 環境裡看不到** —— 它注入的 `grep` 實為 `ugrep --ignore-files`，自動遵守 `.gitignore`（`.build/` 正在裡面）。同一個專案：原生 `grep` 掃出 184 行、Claude Code 的 `grep` 掃出 0 行。skill 交付給原生環境跑，必須自己寫 `--exclude-dir`。

## [2.0.3] - 2026-08-01

修 2.0.2 引入的 live bug：resolver 確定地指向四個月前的過時原始碼。修的是 #11。

### Fixed

- **`MCP_ROOTS_SPEC` 順序：`che-msg` 移到 `che-mcps` 之前。**

  `che-telegram-all-mcp` / `che-telegram-bot-mcp` 在兩處都有，但**不是同一個專案的兩份副本**：

  | | `che-msg/` | `che-mcps/` |
  |---|---|---|
  | 形態 | monorepo 子目錄（無自己的 `.git`）| 獨立 clone（有自己的 `.git`）|
  | remote | `PsychQuant/che-msg` | `kiki830621/che-telegram-*-mcp` |
  | 最後 commit | **2026-06-14** | 2026-02-22 |
  | 檔案結構 | 重構後（`TelegramAllLib/`、`CLIBootstrap.swift`…）| 重構前（`TDLibClient.swift`）|

  舊順序把 `che-mcps` 排前面，於是六個 `mcp-*` skill 被確定地導向**落後四個月**的原始碼。#2 的 closing summary 寫「resolver 依 precedence 取 che-mcps 那份，行為確定且有測試 pin 住，所以工具層安全」—— 前半正確、結論錯誤。**確定不等於正確**：測試 pin 住的是「第一個 root 勝出」這條規則，不是「勝出的那份是對的」。

- **同名遮蔽從靜默變可見**。`resolve_mcp_project` 現在偵測「同一名稱存在於多個 umbrella」，往 **stderr** 印出全部候選並標明取了哪個。stdout 仍只有單一路徑，呼叫端的 `cd "$(resolve_mcp_project x)"` 不受影響。

  這正是本 issue 的根因形狀：靜默地在數份同名之中挑一個，挑錯了也沒有任何訊號。無遮蔽時不印任何東西（不製造雜訊）。

### Added

- **`mcp_project_candidates <name>`** —— 依 precedence 順序列出所有候選路徑。讓「有幾份、分別在哪」成為可查詢的事實，而非只能從警告訊息推斷。

**未做的事**：本機 `~/Developer/che-mcps/che-telegram-{all,bot}-mcp` 這兩個過時 clone **未刪除** —— 那是不可逆的資料層動作，留給使用者決定。resolver 現在不會取到它們，且若取到會警告，所以留著不影響正確性。

## [2.0.2] - 2026-07-31

六個 `mcp-*` skill 有 11 處指向一個**已經不存在**的專案目錄。修的是 #2。

### Fixed

- **11 處硬編碼 `~/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/<name>`** —— 該路徑在本機不存在（連 `projects/mcp` 那層都沒有）。

  **失效方式是靜默的**：`cd <deadpath>/$1` 沒帶 `2>/dev/null &&`，`cd` 失敗後 shell 照樣往下執行，於是 `mcp-debug` / `mcp-test` / `mcp-diagnose` 會對**呼叫者當時的 cwd** 做檢查、建 `logs/`、然後回報結果。看起來成功，對象卻是錯的專案。

  改用新的 `scripts/resolve-mcp-project.sh`；找不到時 `require_mcp_project` 印出搜尋過的位置與可用專案清單並回非零。

### Added

- **`scripts/resolve-mcp-project.sh`** —— MCP 專案路徑的 single source of truth，與 `resolve-marketplace.sh` 同構。25 個測試（fixture 以覆寫 `HOME` 建合成樹，因此 precedence 與收錄判準都可測，且順帶 pin 住「root 是 HOME 相對而非絕對路徑」這個契約）。

  三個 umbrella 各有收錄模式：

  | Root | Mode | 理由 |
  |---|---|---|
  | `~/Developer/che-mcps` | `any` | 主 umbrella，含共用 library |
  | `~/Developer/che-msg` | `any` | telegram 家族自己的 umbrella |
  | `~/Developer` | `mcp-suffix` | 一般目錄，只收 `*-mcp` |

  兩個判準都是實測校正出來的，不是預設對的：

  - **`~/Developer` 若當成 `any`**，`list_mcp_projects` 會從 24 個變成 **42 個** —— 多出的 22 個是 `macdoc` / `rush` / `safari-browser` 等與 MCP 無關的 Swift package，會讓錯誤訊息裡的「可用的專案」清單反而誤導人。
  - **收錄判準若只認 `Package.swift`**，會靜默漏掉 `iss-compute-mcp` —— 它是 Python，只有 `requirements.txt`。改為接受任一語言的 package metadata。

### Notes（診斷推翻了 issue 的原假設）

#2 原本寫「需先定組織原則」，理由是 `che-telegram-mcp` 內嵌在 `psychquant-claude-plugins/plugins/` 而非 `che-mcps/`。**那句話是錯的**：該目錄底下 `find -name Package.swift` 回 0 —— 它是下載 binary 的 plugin wrapper，不是原始碼專案。真正的 telegram MCP 在 `che-mcps/` 與 `che-msg/` 底下。

所以本次**不搬動任何專案**，只加一支能跨 umbrella 解析的函式。順帶查到一件確實需要決定、但不屬本 issue 的事：`che-telegram-all-mcp` 與 `che-telegram-bot-mcp` 在 `che-mcps/` 與 `che-msg/` **各有一份不同 inode 的實體目錄**（不是 symlink）。resolver 依 precedence 取 `che-mcps` 那份，但兩份副本本身該不該合併，留待另開 issue。

## [2.0.1] - 2026-07-31

修掉改名後殘留的失效引用，並補上一支讓這類殘留可機械偵測的檢查腳本。修的是 #1。

### Added

- **`scripts/check-skill-references.sh`** —— 掃全 repo 找出「指向不存在 skill 的引用」與「已退役的 plugin 前綴」。exit 0 全過 / 1 有 findings / 2 路徑錯，附 `--format tsv` 供 CI 消費。15 個測試（`test-check-skill-references.sh`）。

  **為什麼需要它**：改名的成本不在改名本身，在引用的長尾。本 repo 踩過兩代 —— `changelog-tools → doc-tools → doc-guardian`。第二次改名時掃的是「當前名字」，所以寫著更早的 `changelog-tools` 的引用**搜不到、也就沒人知道它們存在**，一路存活到兩代之後。skill 引用不像 `import`，指向不存在的目標時是完全靜默的。

  刻意的前瞻／歷史引用不需 allowlist 檔：同一行寫明 `Phase 2` / `尚未實作` / `刻意保留` 等字樣即跳過，`CHANGELOG.md` 與 `test-*` 整份跳過（前者的舊名是當時的事實，後者的舊名是 fixture 資料）。

### Fixed

- **`rules/tool-readme-sync-plugin.md` 與 `skills/plugin-deploy/SKILL.md` 指向 `mcp-tools/rules/tool-readme-sync.md`** —— 該路徑在合併後已不存在。改為同目錄的 `tool-readme-sync-mcp.md`。

- **`rules/tool-readme-sync-plugin.md` 的 marketplace 審計範例硬編碼絕對路徑**（`/Users/che/Developer/psychquant-claude-plugins/`）。改為 `resolve-marketplace.sh` —— 那支腳本正是 v1.0.0 為了消滅這類硬編碼而寫的，這處是漏網的第 6 處。同段落把「plugin 都住在 `psychquant-claude-plugins`」的單一 marketplace 假設一併泛化。

- **`hooks/post-push-deploy-reminder.sh` 印出 `/mcp-tools:mcp-deploy`** —— 那是給使用者照著打的提示，前綴已失效。

**刻意未改的兩處**：`README.md` 中解釋「合併前為何會靜默斷裂」的那句仍寫 `/mcp-tools:mcp-deploy` —— 它描述的正是合併前的情境，改成新前綴會讓句子自相矛盾。同理 `CLAUDE.md` 裡「不要用舊的 `/plugin-tools:` 前綴」的反例。兩處都已標註，檢查腳本據此跳過。

## [2.0.0] - 2026-07-31

### Changed

- **plugin 更名 `devtools` → `harness-devtools`**（breaking）。呼叫方式由 `/devtools:*` 改為 `/harness-devtools:*`；**skill 名不變**。

  舊名的問題不是已經撞名，而是**沒說出它管什麼**。環境中 `agent-sdk-dev` / `mcp-server-dev` / `plugin-dev` / `feature-dev` 都指明了對象，`devtools` 是唯一只說「開發工具」的；加上官方 `chrome-devtools-mcp` 名稱相近，容易混淆。新名指明範圍 —— 它管的是 **Claude Code harness 這一層**（plugin、MCP server、CLI、skill），而 `harness` 正是官方用語。

  改名時機選在此刻：僅本機安裝、無外部使用者、0 stars / 0 forks，成本最低。101 處 `/devtools:` 引用 + 28 個檔案以機械替換完成，`che-plugin-devtools`（repo / marketplace 名）的 31 處未受影響 —— 替換用 negative lookbehind 排除 `che-plugin-` 與已替換的 `harness-` 前綴。

  本檔 v1.0.0 entry 內的 `/devtools:*` 字樣**刻意保留**：那是當時的事實。

- **16 個 skill 的 description 重寫**，依 invocation 模式採兩種寫法：

  - **auto-invocation**（`cli-*` 4 個 + `mcp-test` / `mcp-debug` / `mcp-diagnose` / `mcp-issue`）—— 四段結構（做什麼 / Use when / 防止的失敗）。其中三個「診斷」類的第四段改寫為**與鄰近 skill 的分工**，因為它們最大的失敗模式不是沒被觸發，是觸發錯的那一個（`diagnose` 連線層 / `debug` 功能層 / `test` 全面驗證）。
  - **manual-only**（8 個 `mcp-*`，`disable-model-invocation: true`）—— **不寫觸發語**（寫了也永遠不會 fire），改為「做什麼 + 與鄰近 skill 的分工」。此組有兩對極易混淆：`clone` vs `clone-references`（已知 URL vs 要先搜尋）、`deploy` vs `publish` vs `sync` vs `install`（發到自己 Release / 上架官方 Registry / 三處 binary 一致性 / 從 Release 裝到本機）。

  desc 字元數：`cli-*` 42–85 → 245–344；`mcp-*` auto 29–60 → 242–278；`mcp-*` manual 38–67 → 168–222。全部改用 YAML block scalar。

**Migration**

```bash
claude plugin uninstall devtools@che-plugin-devtools
claude plugin install harness-devtools@che-plugin-devtools
```

其他 repo 或個人筆記中的 `/devtools:*` 引用需一併更新為 `/harness-devtools:*`。


## [1.0.0] - 2026-07-30

首個版本。由三個既有 plugin 合併而成，遷入新 marketplace `che-plugin-devtools`。

### Added

- **`scripts/resolve-marketplace.sh`** — marketplace 路徑解析的 single source of truth。提供 `resolve_marketplace_root <name>` 與 `find_plugin_marketplace <plugin>` 兩個函數，取代先前散落在 5 處 SKILL.md / rules 的硬編碼 `psychquant-claude-plugins` 路徑。
- 24 個 skills 並置於單一 plugin：`plugin-*`(6) / `mcp-*`(14) / `cli-*`(4)，前綴天然不衝突，呼叫方式由 `/plugin-tools:plugin-update` 改為 `/devtools:plugin-update`（其餘同理）。

### Changed

- **合併三個前身 plugin**：`plugin-tools` 1.18.0 + `mcp-tools` 1.16.0 + `cli-tools` 1.1.2 → `devtools` 1.0.0。

  合併理由：三者形成循環依賴（`plugin-tools` ↔ `mcp-tools` 雙向，`cli-tools` → `mcp-tools`），`mcp-deploy` 一支就被跨 plugin 引用 19 次；而 Claude Code **沒有 plugin 依賴宣告機制**（`plugin.json` 無 `dependencies` 欄位）。分開安裝時，只裝其中一個會讓 `plugin-update` 的 dependency-aware orchestration 在呼叫 `/mcp-tools:mcp-deploy` 時找不到 skill，**且無任何事前警告**。「可選擇性安裝」在此 call graph 下是假選項。

- **`rules/tool-readme-sync.md` 拆為三份並存**，內容逐位元不變：
  - `tool-readme-sync-plugin.md`（141 行，md5 `8348f73a…`）
  - `tool-readme-sync-mcp.md`（156 行，md5 `85040e3b…`）
  - `tool-readme-sync-cli.md`（177 行，md5 `b3049168…`）

  三份原本同名但 md5 各異，是已各自演化的 drift 分支而非複製品。合併需逐條判斷哪些差異是刻意的，屬內容判斷而非搬家動作，故延後為獨立 issue 處理——以保住本次遷移「行為完全一樣」這個可驗證的成功條件。

**Migration notes**

- v1.0.0 之前的 commit history 見 [`PsychQuant/psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)，遷移基準 commit `cfb8849`。三個前身各自的 CHANGELOG 保留於該 repo。
- 舊呼叫方式 `/plugin-tools:*`、`/mcp-tools:*`、`/cli-tools:*` 一律改為 `/devtools:*`，skill 名本身不變。

[Unreleased]: https://github.com/PsychQuant/che-plugin-devtools/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/PsychQuant/che-plugin-devtools/releases/tag/v2.0.0
[1.0.0]: https://github.com/PsychQuant/che-plugin-devtools/releases/tag/v1.0.0
