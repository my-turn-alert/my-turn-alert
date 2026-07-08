<div align="center">

![my-turn-alert](./assets/hero.png)

# my-turn-alert

**Claude Code 跑完了、卡住了、在等你 —— 彈圖提醒你,點圖切回去。**

*Visual popup alerts when any Claude Code CLI needs a human. Click the image to jump back to that CLI.*

[![Version](https://img.shields.io/badge/version-1.5.0-blue)](./.claude-plugin/plugin.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey)](#平台支援)
[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-plugin-D97757)](https://code.claude.com/docs/en/plugins)

[English](./README.md) · **繁體中文**

[安裝](#-安裝) · [功能](#-功能總覽) · [自訂圖片](#%EF%B8%8F-自訂圖片) · [設定](#%EF%B8%8F-進階設定) · [疑難排解](#-疑難排解) · [運作原理](#-運作原理)

</div>

---

## 這是什麼?

如果你常**同時開好幾個 Claude Code**、跑完卻沒注意到該換你了,這個 plugin 就是為你做的。

它監聽 Claude Code 的 **Stop / StopFailure / Notification** 事件——當任一 CLI 回應結束、發生 API 錯誤、要求授權、或閒置等你輸入時,在螢幕右下角彈出一張**對應該 CLI 的圖片**,把你的注意力拉回來。**點圖片就直接切回那個 CLI 視窗**。

![多實例示意](./assets/demo-multi.png)

## ✨ 功能總覽

| | 功能 | 說明 |
| --- | --- | --- |
| 🔔 | **該你了就彈圖** | 回應結束、API 錯誤、權限請求、閒置等待——涵蓋所有「輪到人」的時機 |
| 🖱️ | **點圖即切回** | 點任一張圖,對應的 CLI 視窗立刻前景化,該圖消失(其他圖不受影響) |
| 🧠 | **回去就自動關** | 以視窗 handle 精準比對:你切回那個 CLI,它的圖就自動關掉 |
| 🗂️ | **一 session 一張圖** | 同時跑 N 個 Claude Code,每個 session 永久綁定一張獨立圖片,一眼認出是誰在叫你 |
| 📐 | **自適應網格** | 1~3 張一排、4 張 2×2、更多自動換行縮放;永不裁切、不超出螢幕 |
| 🖼️ | **零設定自訂圖** | 把圖丟進 `user-images/` 即生效且**恆優先**;不夠分時才用自動生成的編號圖補位 |
| 🔇 | **不吵你** | 彈窗不搶焦點、不打斷打字;同一 CLI 重複觸發只覆寫不堆疊;關掉後 ~2 分鐘內的事件回音不重彈 |
| 🛡️ | **安全邊界明確** | 只讀寫自己的狀態資料夾;不碰登錄檔、PATH、開機啟動、全域鍵盤 Hook([詳見安全章節](#%EF%B8%8F-安全邊界)) |
| 💨 | **不拖慢 Claude** | hook 數百毫秒內返回;長駐 renderer 背景繪圖,全部圖關完自動退出 |

## 📦 安裝

在 Claude Code 中依序輸入這三行:

```text
/plugin marketplace add my-turn-alert/my-turn-alert
/plugin install my-turn-alert@my-turn-alert
/plugin enable my-turn-alert@my-turn-alert
```

> ⚠️ **第三步別漏掉**:plugin 安裝後**預設是停用的**,必須 `enable` 後(或執行 `/reload-plugins`、重開 session)hook 才會生效。如果裝完沒反應,九成是這一步沒做。

裝好後,下次 Claude 回應結束時,螢幕右下角就會跳出提醒圖:

<div align="center">

<img src="./assets/default-alert.png" width="220" alt="預設提醒圖">

</div>

### 平台支援

| 平台 | 支援程度 | 需求 |
| --- | --- | --- |
| **Windows** | ✅ 完整(含點圖切視窗、回 CLI 自動關) | Git Bash(Claude Code 內建使用)+ PowerShell |
| **macOS** | 🟡 盡力而為(可叫出終端機 App,無法精準切 tab) | `python3` + Tkinter |

### 更新 / 停用 / 移除

```text
/plugin marketplace update my-turn-alert   # 更新到最新版
/plugin disable my-turn-alert@my-turn-alert   # 暫時關閉
/plugin uninstall my-turn-alert@my-turn-alert # 移除
```

## 🎯 觸發時機

預設監聽以下事件,涵蓋「AI 沒在跑、輪到你或需要你查看」的所有時機:

| 事件 | 何時跳 |
| --- | --- |
| **Stop** | Claude 每次回應結束、純文字提問後、等待輸入前 |
| **StopFailure** | API 錯誤:HTTP 400(invalid_request)、429(rate_limit)、5xx(server_error)、overloaded、billing_error、max_output_tokens(context 超限)等 |
| **Notification** (`permission_prompt`) | Claude 要你授權使用工具時 |
| **Notification** (`idle_prompt`) | Claude 閒置等待你輸入時 |
| **Notification** (`elicitation_dialog`) | MCP 工具中途請求結構化輸入時 |

**不監聽** `SubagentStop`(子代理結束時主流程仍在跑,非「輪到人」)。

這些設定寫在 [`hooks/hooks.json`](./hooks/hooks.json),想改觸發時機可自行編輯。

## 🖼️ 自訂圖片

**零設定,放圖即生效**——把你的圖片(建議 PNG)丟進**使用者專屬資料夾**:

| 系統 | 路徑 |
| --- | --- |
| Windows | `%USERPROFILE%\.claude\alert-need-human\user-images\` |
| macOS | `~/.claude/alert-need-human/user-images/` |

(首次觸發時自動建立;`~/.claude/alert-images/` 也同樣有效,兩處合併使用。)

**你的圖永遠優先**(v1.5.0):每個 Claude Code session 按檔名順序(不分大小寫)佔一張你的圖並**永久綁定**——同一個 session 從頭到尾都是同一張圖,不隨視窗或完成順序改變。你的圖全部被佔用後,**多出來的 session 才會用自動生成的編號圖**補位;下一輪循環仍然先回到你的圖。

**圖片來源優先順序**(由高到低,逐級退路):

1. **使用者圖**(`user-images/` + `~/.claude/alert-images/` 合併)→ 每個 session 綁定一張
2. **使用者圖用完(或沒有)→ 自動生成 001..100 編號圖**(寫到 `~/.claude/alert-need-human/auto-images/`,**不動你的圖**;`ALERT_DISABLE_AUTOGEN=1` 可關)
3. 舊單張 `~/.claude/alert-image.png` 存在 → 所有 CLI 共用這張(向後相容)
4. 以上皆無 → 內建預設圖 `assets/default-alert.png`
5. 連內建圖都找不到 → renderer 畫黃底紅框「載入失敗」提示(**永不白屏**)

> 💡 如果你曾把自己的圖誤丟進 `auto-images/`,不用搬:下次觸發時 plugin 會自動把非編號圖檔遷移到 `user-images/`,既有綁定不會斷。

> 💡 圖片格式建議 **PNG**:macOS 的 Tkinter 只吃 PNG / GIF;Windows 支援 PNG / JPG / GIF / BMP。跨平台一致就統一用 PNG。

## 🧹 彈窗什麼時候消失?

- **點圖** → 立刻關閉,同時把對應的 CLI 視窗叫到前景。
- **切回對應 CLI**(以視窗 hwnd 精準比對,不是 process name 全域比對):
  - 彈窗出現時你**不在**那個 CLI → 切回該 CLI 視窗即自動關。
  - 彈窗出現時你**已經在**那個 CLI → 需在該視窗**再點一下滑鼠或敲一個鍵**才關;沒有輸入活動的話圖會一直留著等你。
- **最低顯示 1.5 秒**內絕不關,避免一瞬白屏。
- 點一張圖只關那一張;其他 CLI 的圖繼續顯示。
- 同一 CLI 連續觸發會覆寫自己的圖,不會疊一堆。
- **同時最多 100 張**(`ALERT_MAX_POPUPS`):先到先服務;滿了之後的新 CLI 不彈圖,舊圖關閉釋出空位後才再服務。

## ⚙️ 進階設定

### 網格大小、位置、間距

預設值寫在彈窗腳本最上方(`scripts/show-popup.ps1` 與 `show-popup.sh`),想改就改:

| 項目 | 預設 | 變數(Windows / macOS) | 說明 |
| --- | --- | --- | --- |
| 每列上限 | 3 | `$MaxPerRow` / `MAX_PER_ROW` | 超過才換行成網格 |
| 版面寬比例 | 0.40 | `$MaxLayoutWidthRatio` / `MAX_LAYOUT_WIDTH_RATIO` | 總版面寬 ÷ 螢幕寬上限 |
| 單格尺寸上限 | 320 px | `$CellMaxPx` / `CELL_MAX`(環境變數 `ALERT_CELL_MAX`) | 單張圖的大小上限——1~3 張時維持角落小圖不佔螢幕 |
| 格子間距 | 12 px | `$GapPx` / `GAP` | 圖與圖之間留白 |
| 右下角邊距 | 20 px | `$MarginPx` / `MARGIN` | 離螢幕右下角的距離 |
| 輪詢間隔 | 300 ms | `$PollMs` / `POLL_MS` | renderer 掃狀態夾與前景偵測的間隔 |

**自適應網格排列規則**:1/2/3 張一排 → 4 張 2×2 → 5/6 張 3×2 → 更多依 `cols = min(總數, MaxPerRow)` 換行。每張圖等比縮放不裁切,整體高度不超出螢幕工作區。

**多螢幕**:預設顯示在「最新一張 alert 的 CLI」所在螢幕右下角;設 `ALERT_MONITOR=N`(1-based)可固定顯示在第 N 個螢幕(Windows;超界回退預設行為)。

### 環境變數

| 變數 | 預設 | 用途 |
| --- | --- | --- |
| `ALERT_STATE_DIR` | `~/.claude/alert-need-human` | 狀態夾(測試/沙箱用) |
| `ALERT_IMAGE_DIR` | `~/.claude/alert-images` | 外部使用者素材夾(與 `user-images/` 合併,唯讀) |
| `ALERT_MAX_POPUPS` | `100` | 同時可見上限(先到先服務;滿了之後的新 CLI 不彈圖) |
| `ALERT_MONITOR` | 自動 | 指定顯示在第 N 個螢幕(1-based);未設或超界時用最新 alert 的 CLI 所在螢幕 |
| `ALERT_CELL_MAX` | `320` | 單張彈圖的尺寸上限(px);想要大圖可調高 |
| `ALERT_DISABLE_AUTOGEN` | `0` | 設 `1` 關閉空資料夾時自動生成 001..100 |
| `ALERT_DEFAULT_IMAGE` | plugin 內建 | 全部退路都失敗時的最終預設圖 |
| `ALERT_LOCK_STALE_SECS` | `30` | 鎖目錄超過此齡視為孤兒(被 kill 的 hook 留下的),自動破鎖 |
| `ALERT_WINCAP_TIMEOUT` | `6` | 抓終端機視窗的 PowerShell 呼叫上限秒數;超時降級為 hwnd=0 |

## 🪟 視窗綁定與探針(Windows)

**「點圖切到對應 CLI」靠的是綁定終端機視窗 handle。** 預設認得 Windows Terminal、PowerShell、cmd、VS Code 內建終端機等(清單在 `scripts/get-window.ps1` 頂端的 `$termNames`)。

**如果點圖沒切到對的 CLI(或切不過去)**:

1. 在你實際跑 Claude Code 的終端機執行診斷探針:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "腳本路徑/scripts/probe-window.ps1"
   ```
   (「腳本路徑」= plugin 安裝目錄,通常在 `~/.claude/plugins/...`)
2. 探針會將終端機程序樹與視窗資訊 dump 至 `~/.claude/alert-need-human/probe.txt`。
3. 打開該檔,找到你的終端機程序名(例如 `Tabby.exe` / `Hyper.exe` / `Cmder.exe`),加進 `scripts/get-window.ps1` 頂端的 `$termNames` 陣列。
4. 下次彈窗就能正確切換了。

**macOS 限制**:「點圖切到正確分頁」為盡力而為,可能僅能把終端機 App 叫到前面(無法精準辨識 tab)。

## 🩺 疑難排解

| 症狀 | 可能原因與解法 |
| --- | --- |
| 裝完完全沒反應 | 忘了 `/plugin enable ...` 或 `/reload-plugins`(見安裝第三步) |
| Windows 沒彈窗 | 需要 Git Bash(Claude Code 在 Windows 預設用它跑 hook);PowerShell 須能執行(本 plugin 已用 `-ExecutionPolicy Bypass`) |
| macOS 沒彈窗 | 需要可用的 `python3` + Tkinter;缺 Tkinter 時 renderer 會安靜結束。裝好 python3-tk 即可 |
| 點圖沒切到對的 CLI | 跑一次 `probe-window.ps1`(見上方章節),把你的終端機程序名加進清單 |
| macOS 切不到正確分頁 | 已知限制,僅能把終端機 App 叫到前面 |
| 想暫時關掉 | `/plugin disable my-turn-alert@my-turn-alert` |
| 之前會彈、後來漸漸不彈了 | v1.4.0 以前的孤兒鎖問題;v1.4.1 起自動破鎖自癒。手動急救:刪 `~/.claude/alert-need-human/` 下的 `*.lock` 目錄 |
| 彈窗跳出時打字被打斷 | 不應該發生(彈窗不搶焦點);若仍中斷,請開 issue 回報終端機類型與環境 |

## 🧩 運作原理

```
事件(Stop / StopFailure / Notification:permission|idle|elicitation)
  └─ hooks/hooks.json 觸發
       └─ bash scripts/alert.sh   ← 薄「寫入器」:寫狀態 + 確保 renderer 在跑,立即返回
            ├─ 讀 stdin JSON(取 session_id、cwd)
            ├─ 抓本 CLI 終端機視窗 handle + 終端機 pid
            ├─ 依「佔座規則」決定本 CLI 配哪張圖
            ├─ 寫 ~/.claude/alert-need-human/pending/<key>.txt
            └─ 搶 renderer.lock → 若 renderer 未跑則背景啟動 → 釋放鎖
                 └─ 長駐 renderer(Windows: PowerShell+WinForms / macOS: Python+Tkinter)
                      ├─ 輪詢 pending/:新增→加入網格重排;刪除→移除重排;空→自我結束
                      ├─ 前景視窗 == 某圖的 hwnd → 刪該圖
                      └─ 點某圖 → SetForegroundWindow(該圖 hwnd) + 刪該圖
```

彈窗以背景方式啟動,`alert.sh` 數百毫秒內返回,**不會卡住 Claude** 的下一步。

**狀態資料夾** `~/.claude/alert-need-human/`(跨 session 共享;不放專案目錄內):

```
~/.claude/alert-need-human/
├── pending/<key>.txt     ← 一個待顯示 alert(以終端機 pid 為主鍵)
├── renderer.pid          ← 長駐 renderer 的 PID(單一實例)
├── renderer.lock         ← 啟動互斥鎖
├── assignments.tsv       ← session_id → 圖片路徑 的佔座記錄(永久綁定)
├── user-images/          ← 你的圖片放這裡(優先使用)
├── auto-images/          ← 自動生成的編號圖(只補溢位)
└── seq                   ← 全域遞增序號(決定網格排列先後)
```

**自癒**:renderer 每輪輪詢時,若某 pending 檔的終端機 pid 已不存在(CLI 已關)→ 刪該檔,避免孤兒圖;`pending/` 空時 renderer 自我結束。

### 目錄結構

```
my-turn-alert/
├── .claude-plugin/
│   ├── plugin.json          # plugin 身分
│   └── marketplace.json     # 安裝來源定義
├── hooks/
│   └── hooks.json           # Stop / StopFailure / Notification hook → alert.sh
├── scripts/
│   ├── alert.sh             # 跨平台分派器:偵測 OS、寫狀態、拉起 renderer
│   ├── popup-common.sh      # 共用函式:圖片探索、佔座分配、檔案鎖
│   ├── show-popup.ps1       # Windows renderer(PowerShell + WinForms 網格)
│   ├── show-popup.sh        # macOS renderer(Python + Tkinter 網格)
│   ├── get-window.ps1       # Windows 終端機視窗解析(含 ConPTY 委派處理)
│   ├── probe-window.ps1     # Windows 視窗綁定診斷探針
│   └── lib/                 # 自動生成編號圖、網格數學
├── assets/                  # 內建預設圖與 README 圖片
├── tests/                   # 測試(bash / PowerShell / Python)
└── docs/SPEC.md             # 完整設計規格
```

## 🛡️ 安全邊界

本 plugin 嚴格只讀寫以下位置;**完全不動其他系統設定**:

| 位置 | 讀 | 寫 | 用途 |
| --- | --- | --- | --- |
| `~/.claude/alert-need-human/`(state) | ✅ | ✅ | pending、佔座、序號、renderer.pid、各 .lock、user-images/、auto-images/ |
| `~/.claude/alert-images/`(外部使用者素材) | ✅ | ❌ | 你放的圖片,本 plugin 視為唯讀 |
| plugin 安裝目錄 | ✅(讀腳本) | ❌(runtime) | 只在 install/update 時被 Claude Code 寫 |

**不會碰**:登錄檔、PATH、`~/.bashrc`/`~/.zshrc`/profile.ps1、開機啟動、Scheduled Task、Windows 服務、全域鍵盤/滑鼠 Hook(`SetWindowsHookEx` 一律不用;`GetLastInputInfo` 是被動讀取 API)、其他使用者目錄。

防禦機制:所有從 JSON/stdin/檔案讀進來的 key 一律過白名單 `[A-Za-z0-9_.-]{1,128}`;原子寫入 realpath-validate 拒絕 `..` 路徑逃逸;PID 比對做 regex escape 防 injection;renderer 端再次驗證檔名與內容一致。

詳細資料流、關閉狀態機與安全分析請見 [`docs/SPEC.md`](./docs/SPEC.md)。

## 🧪 測試

```bash
bash tests/run-tests.sh
```

涵蓋:狀態夾與原子寫入、圖片佔座與循環、端到端 pending 內容、路徑轉換、上限閘門與 regex-injection 防護、自動生成 idempotent、網格數學跨平台一致(詳見 [`docs/SPEC.md`](./docs/SPEC.md) 測試矩陣)。

## 授權

[MIT](./LICENSE)
