# 設計：多實例提醒彈窗（alert-need-human v1.2.0）

- 日期：2026-06-29
- 狀態：已通過 brainstorming，待使用者審查
- 適用平台：Windows（完整）、macOS（盡力而為）

## 1. 背景與目標

現有 plugin（v1.1.1）的行為：每次 Claude 回應結束（`Stop`），於螢幕右下角彈出**一張**圖片，新彈窗取代舊彈窗（單一實例）。彈窗在「切回終端機 + 連續確認」或「30 分鐘硬上限」後自動關閉。

使用者要求三項改變：

1. **取消所有「定時自動消失」**。圖片要**一直顯示**，直到使用者**回到對應的 Claude Code CLI**——具體指「點擊該 CLI 視窗、或在該 CLI 輸入文字」等於使用者已回來——才消失。不再有「顯示 N 秒就關」或「30 分鐘上限」。
2. **多實例**：多個 Claude Code 同時跑時，**每個 CLI 對應一張圖**。多個都停下時，螢幕上同時顯示多張圖。**點某張圖 = 把對應的那個 CLI 視窗叫到前景，且該圖消失**；其餘 CLI 的圖續留。圖片來源為使用者指定的資料夾，按檔名順序分配。
3. **自適應網格版面**：依圖片數量自動排版——1/2/3 張排成一橫列、4 張 2×2、更多則換行成網格；每張圖自適應縮放、完整顯示不裁切。

額外需求（對話中補充）：除了一般回應結束，**只要「AI 沒在繼續跑、輪到人或要你查看結果」都要跳圖**，包含：工具/MCP 中途結構化提問、需要授權、閒置等待、以及 **API 錯誤（如 HTTP 400）**。

## 2. 關鍵事實（已查證 Claude Code hook 機制）

以下為設計所依據、經查證的事實（依官方文件）：

- **Stop hook stdin** 含 `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`permission_mode`、`stop_hook_active` 等欄位。`session_id` 在**同一 session 生命週期內穩定不變**，跨每輪 Stop 都相同；`/clear` 或重開 CLI 會產生新 id。
- **`${CLAUDE_PLUGIN_ROOT}`** 是官方支援的環境變數，展開為 plugin 安裝根目錄絕對路徑。
- **API 錯誤觸發 `StopFailure` 事件，而非 `Stop`**。`StopFailure` 可用 matcher 篩選錯誤類型：`rate_limit`、`overloaded`、`authentication_failed`、`billing_error`、`invalid_request`（對應 HTTP 400）、`model_not_found`、`server_error`（對應 5xx）、`max_output_tokens`（context 超限）、`unknown` 等。`StopFailure` 無法阻擋（output/exit code 被忽略），純通知用途。
- **`Notification` hook** stdin 含 `session_id`、`cwd`、`transcript_path`、`message`、`permission_mode`。matcher 值：`permission_prompt`（等待授權）、`idle_prompt`（閒置等待輸入）、`elicitation_dialog`（MCP 工具中途請求結構化輸入）等。
- **`Stop` 在 Claude「純文字回答後」也會觸發**（不限工具使用後）——故 superpowers 等流程「問完問題、把控制權交回使用者」會觸發 `Stop`。
- **`SubagentStop`** 為獨立事件，子代理結束時觸發、**不**觸發 `Stop`。本設計**刻意不監聽** `SubagentStop`（子代理結束時主流程仍在跑，非「輪到人」）。
- **未明確 / 風險點**：hook 子程序是否仍「附著」在 CLI 的終端機 console，官方文件**未明確**；故「在 hook 內以 `GetConsoleWindow()` 直接取得 CLI 視窗」**不保證可行**，須以探針驗證（見 §6）。

## 3. 架構總覽

採「**單一 renderer + 狀態資料夾**」模型。

```
事件（Stop / StopFailure / Notification:permission_prompt|idle_prompt|elicitation_dialog）
  └─ hooks/hooks.json 觸發
       └─ bash scripts/alert.sh   ← 薄「寫入器」：寫狀態 + 確保 renderer 在跑，立即 exit 0
            ├─ 讀 stdin JSON（取 session_id、cwd；缺漏可容忍）
            ├─ 抓本 CLI 終端機視窗 handle + 終端機 pid（見 §6）
            ├─ 依「佔座規則」決定本 CLI 配哪張圖（見 §5）
            ├─ 寫 pending/<key>.json（同一 CLI 覆寫，不堆疊）
            └─ 搶 renderer.lock → 若 renderer 未跑則背景啟動 → 釋放鎖
                 └─ 長駐 renderer（Windows: PowerShell+WinForms / macOS: Python+Tkinter）
                      ├─ 輪詢 pending/：新增→加入網格重排；刪除→移除重排；空→自我結束
                      ├─ 前景視窗 == 某圖的 hwnd（或該 pid 取得焦點）→ 刪該圖（使用者回到該 CLI）
                      └─ 點某圖 → SetForegroundWindow(該圖 hwnd) + 刪該圖
```

**職責邊界**

| 單元 | 職責 | 依賴 | 不負責 |
|---|---|---|---|
| `alert.sh` | 跨平台分派；讀 stdin；抓 handle；佔座決定圖片；寫 pending 檔；確保 renderer 在跑 | uname、ps/CIM、平台 popup 腳本 | 不畫任何 UI、不等待 |
| `show-popup.ps1`（renderer，Windows） | 擁有單一彈窗視窗；輪詢狀態夾；網格排版；點擊/回到-CLI 偵測與關閉；自癒 | WinForms、Win32（前景/焦點 API） | 不決定配哪張圖（由 hook 寫好） |
| `show-popup.sh`（renderer，macOS） | 同上之 macOS 盡力而為版 | Tkinter、osascript | 同上 |
| 狀態資料夾 | hook 與 renderer 之間的唯一通訊介面 | 檔案系統 | — |

**為何選此模型**：版面需求（單列→網格的整體佈局）本質上要「一處統一掌握全部圖、統一排版」；點擊/關閉邏輯亦只需一處。若改用「N 個獨立彈窗各自算位置」會在版面協調與定位上產生競態，較難維護。

## 4. 狀態模型與資料流

**狀態資料夾**：`~/.claude/alert-need-human/`（跨 session 共享；不放專案目錄內）

```
~/.claude/alert-need-human/
├── pending/
│   └── <key>.json        ← 一個待顯示 alert（內容見下）
├── renderer.pid          ← 長駐 renderer 的 PID（單一實例）
├── renderer.lock         ← 啟動互斥鎖（避免多事件同時搶開 renderer）
├── assign.json           ← pid → 圖片路徑 的佔座記錄（穩定綁定，見 §5）
└── seq                   ← 全域遞增序號（決定網格排列先後）
```

`pending/<key>.json` 內容：

檔名 `<key>.json` 的 `key` 即主鍵（預設為 `term_pid` 字串；取不到時為 `session_id`，見下）。檔案內容：

```json
{
  "key": "<主鍵：term_pid（預設）或 session_id（退路）>",
  "session_id": "<若該事件有提供，否則空字串>",
  "image_path": "<絕對路徑>",
  "hwnd": "<終端機視窗 handle，整數字串；macOS 為空>",
  "term_pid": "<終端機程序 pid>",
  "cwd": "<工作目錄>",
  "reason": "stop | stop_failure | permission | idle | elicitation",
  "seq": 123,
  "ts": 0
}
```

**主鍵選擇**：以**終端機視窗 pid（`term_pid`）**為 `key`，而非 `session_id`。理由：
- `StopFailure` 等事件的 stdin 是否帶 `session_id` 無法 100% 確認；以終端機 pid 為鍵可在欄位缺漏時仍正常運作。
- 終端機視窗 pid 在「該視窗存活期間」永遠穩定，跨 `/clear`、跨 session 不變——天然對應「一個視窗一張圖」。
- `session_id` 仍存入檔案作輔助/除錯。
- 若 §6 探針顯示某環境取不到穩定的 `term_pid`，退而以 `session_id` 為鍵（見 §6 退路）。

**資料流要點**

- **同一 CLI 覆寫**：同個終端機 pid 連續觸發多次事件，只更新自己那一個 pending 檔（覆寫），不疊圖。
- **一直顯示、無計時器**（需求 1）：renderer **不含**任何「顯示 N 秒後關」或「最長上限」邏輯。一張圖僅在兩種情況消失——使用者**點它**，或**回到它對應的 CLI**（前景視窗為該 hwnd / 該 pid 取得焦點）。
- **自癒**：renderer 啟動及每輪輪詢時，若某 pending 檔的 `term_pid` 已不存在（CLI 已關），刪該檔，避免孤兒圖與點到已回收的 hwnd。
- **pending 空 → renderer 自我結束**並清掉 `renderer.pid`。

## 5. 圖片來源與分配規則

**圖片資料夾**（零設定慣例）：`~/.claude/alert-images/`
- 放圖進去即生效；資料夾內圖檔**按檔名（不分大小寫）排序**。
- 建議 PNG（macOS Tkinter 僅支援 PNG/GIF；跨平台一致用 PNG 最保險）。

**佔座與穩定綁定**（對應使用者選擇「依出現先後佔座，之後記住」+「每個 CLI 固定一張圖」）：
- 某終端機 pid **首次**觸發時，從排序後清單取「目前未被占用、序最前」的圖，寫入 `assign.json`（`term_pid → image_path`）。
- 之後同一 pid 的所有事件都沿用同一張圖（讀 `assign.json`）。
- pid 消失（CLI 關閉）時，renderer 自癒會一併釋放其 `assign.json` 條目，該圖可被新 CLI 取用。

**圖片不夠分 → 循環重複用**（使用者選擇）：
- 同時在跑的 CLI 數量超過資料夾圖片數時，第 N 個取第 `((N-1) mod 圖數)+1` 張。不同 CLI 可能重複同一張圖。

**圖片來源優先順序（由高到低，逐級退路；向後相容）**：
1. **資料夾 `~/.claude/alert-images/` 內有圖** → 依上述佔座規則 per-CLI 分配（主路徑）。
2. 資料夾不存在或為空，但**舊單張 `~/.claude/alert-image.png` 存在** → 所有 CLI 都用這張（相容舊版）。
3. 以上皆無 → 全部使用內建 `assets/default-alert.png`（沿用舊預設行為）。
4. 連內建圖都找不到 → 安靜不顯示，不報錯。

## 6. 視窗綁定與「點圖切到對應 CLI」（需求 2 技術核心）

### 6.1 Windows——先以探針驗證

**實作第一步**交付獨立探針腳本 `scripts/probe-window.ps1`，由使用者在「實際以 cmd / PowerShell 跑 Claude Code」的環境執行一次（或暫時掛成 hook 跑一次），將下列資訊 dump 至 `~/.claude/alert-need-human/probe.txt`：

1. `GetConsoleWindow()` 的回傳值及該視窗的標題與類別名。
2. 從目前程序**往上爬 parent 程序樹**（PowerShell 以 `Get-CimInstance Win32_Process` 依 `ParentProcessId` 逐層上溯），列出每層的 `行程名 + PID + MainWindowHandle`，並標出第一個「行程名屬於 cmd/powershell/pwsh/conhost/WindowsTerminal 且有可見主視窗」的層級。

使用者回貼結果後，據此**鎖定**抓 handle 的方法。抓取優先順序（後備鏈）：

```
1) GetConsoleWindow()              ── 黑窗（conhost）情境通常可直接取得
2) 爬 parent 程序樹找終端機主視窗  ── 最穩健後備（即使 hook 脫離 console，parent 鏈仍指回啟動它的終端機）
3) 皆失敗 → best-effort：點圖時把「最近作用的終端機視窗」叫到前面，或以視窗標題比對
```

**點圖切視窗**：以存下的 `hwnd` 呼叫 `SetForegroundWindow`；必要時先 `ShowWindow(SW_RESTORE)` 還原最小化，並以 `AttachThreadInput` 處理 Windows 前景權限限制。

**term_pid 取得**：以上述程序樹找到的終端機那層 PID 為 `term_pid`（即使選用 `GetConsoleWindow()` 取 hwnd，仍另行上溯取得擁有該視窗的程序 pid）。

### 6.2 macOS——盡力而為

hook 無法取得視窗 handle。退而求其次：
- hook 端記下 `cwd`，並嘗試取得控制 TTY（若可得）。
- 點圖時以 AppleScript 嘗試把「標題或路徑符合該 session 的終端機視窗/分頁」帶到前景；無法精準辨識時，僅把終端機 App 叫到前面。
- 明確標示 macOS 為**盡力而為**，不保證跳到「正確那一個分頁」。
- macOS 的關閉偵測（回到對應 CLI）以「最前景 App 是終端機類 + 該 session 標記」近似；無法達到 Windows 的 per-window 精度時，退回「前景為終端機 App 即視為回來」。

### 6.3 綁定生命週期

`pending` 檔同存 `hwnd` 與 `term_pid`。renderer 發現 `term_pid` 已死 → 視為該 CLI 關閉，自動移除該圖並釋放其 `assign.json` 條目。

## 7. 自適應網格版面（需求 3）

- **視窗屬性**：無邊框、`TopMost`、貼螢幕**右下角**、**不搶焦點**（Windows 套用 `WS_EX_NOACTIVATE`；macOS 以對應方式避免奪焦）。不搶焦點為硬性要求——因彈窗可能在回合中途（權限、錯誤）跳出，絕不能打斷使用者輸入。
- **排列規則**（對應使用者選擇「單列優先，4 張起網格」）：
  - 欄數 `cols = min(總數, MaxPerRow)`，`MaxPerRow` 預設 3。
  - 列數 `rows = ceil(總數 / cols)`。
  - 例：1→1×1、2→1×2、3→1×3、4→2×2、5/6→2×3。
- **自適應大小**：定義「總版面寬上限」`MaxLayoutWidthRatio`（預設螢幕寬 ~40%）。格子邊長 = `(總版面寬 − 間距) / cols`，隨張數增加自動縮小；每張圖以原始長寬比**完整縮放不裁切**（WinForms `PictureBoxSizeMode.Zoom` / Tkinter 等比縮放）。整體高度依列數計算，並確保不超出螢幕工作區。
- **每張圖**為獨立可點區塊（PictureBox / Label），點擊觸發 §6 的切視窗 + 移除。

## 8. 觸發時機（hooks.json）

監聽下列事件（全集；對應使用者「只要 AI 沒在繼續跑、輪到人就跳」）：

| 事件 | matcher | 何時 |
|---|---|---|
| `Stop` | （無 matcher） | Claude 回完／純文字提問後／等待輸入前 |
| `StopFailure` | （無 matcher，全收） | API 錯誤：400/429/5xx/overloaded/billing/context 超限等 |
| `Notification` | `permission_prompt` | 等待使用者授權工具 |
| `Notification` | `idle_prompt` | 閒置等待使用者輸入 |
| `Notification` | `elicitation_dialog` | MCP 工具中途請求結構化輸入 |

**不監聽** `SubagentStop`（子代理結束時主流程仍在跑，非「輪到人」）。

`hooks.json` 範例（移除對 `Stop` 無意義的 `"matcher": "*"`）：

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ] }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ]
      }
    ]
  }
}
```

## 9. 設定參數

集中放各 renderer 腳本頂端（比照舊版風格），README 列表說明：

| 項目 | 預設 | 說明 |
|---|---|---|
| 每列上限 `MaxPerRow` | 3 | 超過才換行成網格 |
| 版面寬比例 `MaxLayoutWidthRatio` | 0.40 | 總版面寬 ÷ 螢幕寬上限 |
| 格子間距 `GapPx` | 12 | 圖與圖之間留白 |
| 右下角邊距 `MarginPx` | 20 | 離螢幕右下角 |
| 輪詢間隔 `PollMs` | 300 | renderer 掃 pending/ 與前景偵測的間隔 |
| 圖片資料夾 | `~/.claude/alert-images/` | 放圖即生效 |

**移除的舊參數**：`MinVisibleMs`、`MaxVisibleMs`、`RequiredHits`、以及「離開終端機再切回 + 連續確認」整套關閉邏輯（新模型僅靠「點圖／回到對應 CLI」關閉）。

## 10. 錯誤處理與韌性

- **絕不影響 Claude**：`alert.sh` 全程吞錯（`2>/dev/null`）、無論如何 `exit 0`；不阻塞、背景啟動 renderer 後立即返回。renderer 崩潰不回饋主流程。
- **自癒**：renderer 啟動清除死 `term_pid` 的孤兒 pending 檔與 `assign.json` 條目；`pending/` 空即自我結束。
- **競態**：`renderer.lock` 確保多事件同時觸發只起一個 renderer；pending 檔以 `term_pid` 命名，覆寫而非堆疊；`seq` 與 `assign.json` 的更新採「讀-改-寫」搭配鎖以避免交錯。
- **找不到圖**：依 §5 退路；最終皆無則安靜不顯示（不報錯）。

## 11. 向後相容與版本

- 版本 bump 至 **1.2.0**（`plugin.json` 與 `marketplace.json` 同步）。
- 保留並更新 `assets/default-alert.png` 與舊單張 `~/.claude/alert-image.png` 支援（見 §5 退路）。
- README 全面改寫：新行為（一直顯示、多圖、點圖切 CLI、網格）、新資料夾、新觸發事件、新參數、探針說明、疑難排解。
- `.gitattributes`、`.gitignore` 沿用；新增忽略狀態夾不適用（狀態夾在 `~/.claude` 下，非專案內）。

## 12. 測試計畫

1. **探針**（§6.1）：使用者實際環境跑一次，確認抓 handle 與 term_pid 的可行路徑；據此鎖定實作。
2. **單一 CLI**：跑完 → 跳一張圖 → 點圖／切回該 CLI → 圖消失、renderer 結束。
3. **兩個 CLI 都停**：跳兩張圖（網格 1×2）→ 點 #1 → #1 的 CLI 到前景且 #1 圖消失、#2 仍在 → 切回 #2 對應 CLI → #2 消失。
4. **版面**：資料夾放 0／1／4／6 張圖，驗證退路與 1×N→網格排列、等比縮放不裁切。
5. **觸發時機**：分別驗證 `Stop`、`Notification`（permission/idle/elicitation）、`StopFailure`（可暫以假 hook 或可觸發的錯誤模擬）皆能跳圖；確認 `SubagentStop` 不跳。
6. **不搶焦點**：彈窗跳出時，在 CLI 持續打字不被打斷。
7. **韌性**：強制關閉某 CLI → 其孤兒圖被 renderer 自動移除；殺掉 renderer → 下次事件能重新拉起。

## 13. 已知限制

- macOS 的「點圖切到正確分頁」為盡力而為，可能僅能把終端機 App 叫到前面。
- 「回到對應 CLI 即關」依賴前景視窗/pid 偵測；同一終端機程式的多視窗在某些環境可能無法 per-window 區分（視 §6 探針結果而定）。
- `StopFailure` 與部分 `Notification` 的 stdin 欄位以查證為準；若實際缺 `session_id`，設計已以 `term_pid` 為主鍵容錯。
- `idle_prompt` 的觸發閒置時間由 Claude Code 決定，文件未明確。
