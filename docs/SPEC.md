# alert-need-human — 設計與規格（v1.4.0）

## 規格目標（需求總表）

1. 作為 Claude Code CLI 的 plugin：當 Claude Code 執行到**需要人為操作**的步驟時，跳出圖片提醒。
2. **點圖片** → 回到（開啟/前景化）對應的 Claude Code CLI 畫面，圖片消失。
3. 圖片顯示期間，**點該 CLI 或在該 CLI 輸入文字** → 該圖片關閉。
4. 圖片可以有多張：使用者可自行放圖，**某個資料夾**（`~/.claude/alert-images/`）就是放置圖片的位置。
5. 多個 CLI 同時觸發時，**依檔名排序**從資料夾取圖；**每個 CLI 對應一張固定的圖**；CLI 數量超過圖片數量時**循環重複**使用。
6. 圖片顯示在**螢幕右下角**；使用者**可指定顯示在第幾個螢幕**（`ALERT_MONITOR`，1-based）。
7. 右下角同時可顯示 1~100 張、上限 100 張：**只服務前 100 個 CLI，之後的 CLI 不彈圖（後面不管）**；既有 CLI 的更新不受影響，舊圖關閉後空位釋出、新 CLI 才會再被服務。

## 用途

**Claude Code 在每次「需要人為操作」的時刻，在螢幕角落彈出一張對應該 CLI 的圖片來提醒你。**

「需要人為操作」涵蓋：

- AI 思考完畢、回應結束（Stop）
- API 錯誤、token 超限、餘額/額度問題（StopFailure）
- 要求授權使用工具（Notification: permission_prompt）
- 閒置等待輸入（Notification: idle_prompt）
- MCP 工具中途請求結構化輸入（Notification: elicitation_dialog）
- 上述包含 superpowers 系列 skill 在 brainstorming 等流程中對你發出的提問

支援多個 Claude Code CLI 同時跑：**每個 CLI 對應一張獨立的圖片**，全部統一在螢幕右下角的有限範圍內排版顯示。

## 設計目標與不變式

1. **觸發即彈** — 上述任一事件發生即在右下角彈出該 CLI 對應的圖片。
2. **點圖 = 切回 CLI + 圖消失** — 滑鼠左鍵點擊任一張圖，會把對應的 CLI 視窗叫到前景，並立即移除該圖（其他 CLI 的圖不受影響）。
3. **回到 CLI = 圖消失（per-hwnd）** — 切回該圖對應的 CLI 視窗即可關閉，*但是*：
   - 若 popup 出現的當下使用者**並不在**那個 CLI（StartedInCli=false）→ 切回該 CLI 即會自動關。
   - 若 popup 出現的當下使用者**已經在**那個 CLI（StartedInCli=true）→ 必須在那個 CLI 視窗**再點一下滑鼠或敲一個鍵**，圖才會消失。沒有任何輸入活動的話，圖會一直留在那。
4. **最低顯示時間** — `MinVisibleMs`（1500ms）內絕不關，避免一瞬間白屏感。
5. **同一 CLI 多次觸發** — 沿用同一個 key（term_pid 為主鍵），新 pending 覆寫舊的，不會堆積。
6. **同時最多 100 張（先到先服務）** — 已有 `ALERT_MAX_POPUPS`（預設 100）個 pending 時，**新的 CLI 不再被服務**（producer 端 `alert.sh` 直接略過，不寫 pending、不佔圖）；既有 CLI 的更新照常放行。舊圖關閉後空位釋出，之後觸發的新 CLI 才會被服務。renderer 額外做一次顯示層的截斷保險（同樣保留 seq 最小的前 N 張）。
7. **可選的圖片來源** — 使用者素材夾 `~/.claude/alert-images/`（按檔名排序循環使用）；空了就**自動生成** 001..100 編號圖到 `~/.claude/alert-need-human/auto-images/`，**不寫入**使用者素材夾。
8. **安全邊界（嚴格遵守）** — 本 plugin 只寫入兩個位置：
   - dev 時：repo 自己
   - 執行時：`$(pc_state_dir)`（預設 `~/.claude/alert-need-human/`）
   - 使用者素材夾 `~/.claude/alert-images/` **只讀**，自動生成寫到 state 夾。
   - 完全不動：登錄檔、PATH、開機啟動、排程任務、系統服務、全域 Hook、其他使用者檔案。

## 觸發與資料流

```
事件（Stop / StopFailure / Notification:permission|idle|elicitation）
  └─ hooks/hooks.json 觸發 bash scripts/alert.sh
       ├─ 讀 stdin JSON：session_id、cwd、hook_event_name、message
       ├─ 抓本 CLI 終端機視窗：MSYS /proc 祖先鏈 → get-window.ps1 → (hwnd, term_pid)
       │    get-window 三段策略（v1.4.3；全部唯讀 API）：
       │    A. Console-title 對應（解 Win11 ConPTY 委派：shell 無自己視窗、視窗屬於
       │       不在祖先鏈上的 WindowsTerminal）：對每個祖先 AttachConsole →
       │       GetConsoleTitle → 與終端機類視窗（CASCADIA/ConsoleWindowClass）標題
       │       精確比對；比不到再用 UIA 唯讀列舉 WT 分頁名。0 或 2+ 候選 → 不猜。
       │       term_pid = 對應成功的祖先（通常是 claude.exe 本人）→ 同一 WT 視窗
       │       多分頁多 CLI 的 key 不互撞。
       │    B. 祖先鏈上「終端機名稱 + 可見主視窗」（VS Code 等）。
       │    C. 進場時 GetConsoleWindow（限 ConsoleWindowClass；ConPTY 的
       │       PseudoConsoleWindow 謊稱 visible，靠 class 排除）。
       │    全滅 → (0,0)：renderer 永不自動關，只能點圖關。
       ├─ KEY 決策：term_pid → sanitized session_id → noctx-PID-SEQ（唯一性兜底）
       ├─ pc_cap_allows_key：上限閘門（已滿 → 先 pc_cleanup_stale 清死 CLI 再試一次，仍滿才 exit）
       ├─ pc_assign_image：穩定佔座（同一 term_pid 永遠對應同一張圖）
       ├─ pc_atomic_write → pending/<KEY>.txt （realpath-validated 在 state_dir 內）
       │    ※ 產出優先：pending 寫入排在清孤兒之前——就算 hook 之後被 timeout 殺掉，圖已有得畫
       ├─ pc_cleanup_stale "$KEY"：家務（跳過剛寫的 KEY，防 ps 快照時差誤殺自己）
       └─ pc_with_lock renderer → 若 renderer 未跑則啟動 show-popup.ps1 / show-popup.sh
            └─ 100ms tick：Read-Pending → Sync 狀態機 → 評估關閉 → 繪製網格
```

## 鎖與孤兒自癒

所有跨行程互斥用 `pc_with_lock`（mkdir 原子鎖，等待上限 ~2 秒）。v1.4.0 的實際故障模式：
持鎖 hook 被 timeout SIGKILL → 鎖目錄永久殘留 → 之後每次 hook 各多等 2 秒/鎖 →
總時長超過 hooks.json timeout → pending 沒寫成（不彈圖），且被殺時又留下新孤兒鎖——自我惡化螺旋。

v1.4.1 起三層防禦：

1. **破鎖**：等待中發現鎖齡（mtime）超過 `ALERT_LOCK_STALE_SECS`（預設 30 秒，遠大於任何合法臨界區）→ `rmdir` 破鎖重搶。
2. **trap 釋放**：取得鎖即掛 `EXIT`/`HUP INT TERM` trap；被殺（SIGKILL 除外）或正常退出都保證釋放。SIGKILL 留下的孤兒由第 1 層收拾。
3. **視窗抓取加 `timeout`**（預設 6 秒，`ALERT_WINCAP_TIMEOUT` 可調）：PowerShell 偶發性極慢時降級為 hwnd=0（renderer 退回 process-name 比對），不讓整支 hook 被拖死。

另外 `pc_is_alive` / `pc_cleanup_stale` 在 Windows 改走單次 `ps -W` 快照（~0.16s）取代逐一 `tasklist`（~0.5s/次），N 張 pending 只掃一次。

## pending 檔格式

純文字 key=value，每行一個欄位（避免 jq 相依）：

```
key=<sanitized KEY>          ← 主鍵；同時是檔名 base（檔名 = key）
session_id=<原始 session id> ← 僅供觀測，不入檔名
image_path=<Windows 形式路徑> ← FromFile 開得了
hwnd=<int64>                 ← CLI 視窗 handle；0 = 抓不到
term_pid=<Windows pid>       ← 從 MSYS /proc/winpid 取得；0 = 未知或 macOS
cwd=<...>
reason=<stop|stop_failure|permission|idle|elicitation>
seq=<全域遞增整數>            ← 決定網格排序（先到先服務的先後依據）
```

## Per-key 關閉狀態機（show-popup.ps1）

每張 popup 在 `KeyState[$k]` 中保有：

| 欄位 | 來源 | 用途 |
| --- | --- | --- |
| `CliHwnd` | pending `hwnd` | 「前景是這個 CLI 嗎」的精準比對對象 |
| `TermPid` | pending `term_pid` | hwnd=0 時的退路比對 |
| `FirstShownTick` | `TickCount` 當下 | 最低顯示時間判定 |
| `StartedInCli` | 出現瞬間的 `GetForegroundWindow()==CliHwnd` | 決定走哪一條關閉條件 |
| `BaselineLastInput` | 出現瞬間的 `GetLastInputInfo().dwTime` | StartedInCli=true 時：用 signed-diff 偵測新輸入 |
| `ReturnHits` | 累進 | 連續 RequiredHits ticks 命中才關（去抖） |
| `ClickRequested` | 點圖事件 | 下一 tick 立即關 |

關閉決策（`Compute-Close`，純函式以便測試）：

```
if ClickRequested:                 → close
if now - FirstShownTick < MinVisibleMs: → tick
fgIsCli = (CliHwnd!=0 AND GetForegroundWindow == CliHwnd)
          OR (CliHwnd==0 AND TermPid!=0 AND fgPid==TermPid)
          ※ 兩者皆未知（hwnd=0 且 term_pid=0）→ fgIsCli 恆 false：永不自動關，
            只能點圖關（或 CLI 死亡由自癒清除）。
            嚴禁退回 process-name 比對——使用者永遠在「某個」終端機裡工作，
            名稱比對會把任何終端機都當成該 CLI，圖 ~2 秒就自己消失（v1.4.1 實際故障）。
if not fgIsCli:                    ReturnHits=0; → tick
if StartedInCli:
    delta = (int32)(GetLastInputInfo - BaselineLastInput)
    if delta <= 0:                 ReturnHits=0; → tick   ← 無新輸入：不關
ReturnHits++
if ReturnHits >= RequiredHits:     → close
else:                              → tick
```

`(int32)` 強制 signed 比較，正確處理 32-bit DWORD wrap（~49.7 天）。

點圖（`PictureBox.Add_Click`）：直接 `Focus-Window(CliHwnd)` + `Remove-Item-Pending`，不等 tick；同時設 `ClickRequested=true` 作為安全網。

## 圖片來源優先序

1. `assignments.tsv` 內既有佔座（**KEY** 與圖檔路徑的穩定綁定；v1.4.4 起以 KEY 而非
   term_pid 為鍵——視窗抓取失敗時多 CLI 的 term_pid 同為 0，會共用一行 → 全同一張圖）
2. `ALERT_IMAGE_DIR` 內的支援格式（png/jpg/jpeg/gif/bmp；**最少使用優先**，同數取檔名序。
   不用「行數 % 總數」盲循環：座位釋放後行數回退，新 CLI 會撞上使用中的圖）
3. **自動生成的 `auto-images/`**（state_dir 內，001.png..100.png）— `ALERT_DISABLE_AUTOGEN=1` 時跳過
4. `ALERT_LEGACY_IMAGE`（舊單張，預設 `~/.claude/alert-image.png`）
5. `ALERT_DEFAULT_IMAGE`（plugin 內建）
6. 全無 → 空字串 → renderer 畫「載入失敗」黃底紅框提示（永不白屏）

## 自動生成編號圖

當 `pc_list_images` 回傳空時，第一張 alert 觸發時呼叫 `pc_ensure_numbered_images`：

- Windows：`scripts/lib/gen-auto-images.ps1`，單一 PowerShell 行程內用 `System.Drawing` 一次生成 100 張 320×320 PNG（每張不同色相 + 大字數字）。
- macOS / Linux：`scripts/lib/gen_auto_images.py`，優先 Pillow；無 Pillow 時退回 Tkinter PhotoImage 寫 GIF。
- 寫入位置永遠是 `state_dir/auto-images/`，**從不寫使用者素材夾**。
- 同 process 整批生成（不會 100 次冷啟動 PowerShell）。
- 寫入用 `path.tmp` → `Move-Item -Force` 原子替換，避免 list 到半成品。
- `pc_with_lock autogen` 串行化；若中途失敗，下次 alert 觸發時會補生缺漏的編號。

## 幽靈重現抑制（ack 戳記）

Claude Code 在 Stop 事件後 ~60 秒常對同一 CLI 再補發 `Notification: idle_prompt`——
那不是新事件，是舊事件的回音。若不處理，使用者剛關掉的圖會在幾十秒後「幽靈重現」。

- renderer 關圖（點圖或回 CLI 自動關）時寫 `acked-<KEY>.stamp`。
- alert.sh 收到 **idle** 事件時：戳記存在且齡 ≤ `ALERT_ACK_SUPPRESS_SECS`（預設 120 秒）
  → 直接 exit，不重彈；戳記過期 → 刪戳記、視為新 idle 照常彈。
- 收到**非 idle** 事件（stop/stop_failure/permission/elicitation）→ 刪戳記、照常彈
  （真的有新狀況，不能被抑制吃掉）。

## Renderer Image 生命週期（防 ImageAnimator 崩潰）

PictureBox 的 Image 必須「先摘下（設 null）再 Dispose」。在還掛著的狀態下 Dispose，
重排/移除時 WinForms 的 ImageAnimator（Animate → CanAnimate → get_FrameDimensionsList）
會碰到已死的 Image → `ArgumentException: 參數無效` 跳 .NET JIT 錯誤對話框
（v1.4.2 實際故障：第二張 popup 出現觸發重排時發生）。`Layout-And-Render` 與
`Close-Popup` 兩處皆遵守此順序。

## 上限保護（先到先服務，超過不管）

`pc_cap_allows_key "$ALERT_MAX_POPUPS" "$KEY"`（預設 cap=100）：

- 若 `pending/$KEY.txt` 已存在（同一 CLI 再次觸發） → 放行（更新既有 pending，不算新增）。
- 否則若目前 `pending/*.txt` 數量 ≥ cap → **拒絕**：alert.sh 直接 `exit 0`，不寫 pending、不佔圖、不啟 renderer。第 101 個以後的 CLI 就是「不管」。
- 舊 pending 被關閉（點圖 / 回 CLI / CLI 死亡自癒清除）後數量降回 cap 以下，之後觸發的新 CLI 自然被服務。
- renderer 端額外於 `Layout-And-Render` / `read_pending` 切片到 `MaxPopups` 張作顯示層保險（保留 seq 最小＝最早的前 N 張，與先到先服務一致）。

## 安全邊界（白名單可寫位置）

| 路徑 | 讀 | 寫 | 註 |
| --- | --- | --- | --- |
| repo 自己 | dev/install | dev only | runtime 不會寫 |
| `$(pc_state_dir)` (`~/.claude/alert-need-human/` 預設) | ✅ | ✅ | `pc_atomic_write` 會 realpath-validate 拒絕 escape |
| `$(pc_state_dir)/auto-images/` | ✅ | ✅ | 唯一寫圖片的位置 |
| `$(pc_image_dir)` (`~/.claude/alert-images/` 預設) | ✅ | ❌ | 使用者素材，本 plugin 視為唯讀 |
| 登錄檔 / PATH / 開機啟動 / Scheduled Task / 全域 Hook | — | ❌ | 完全不動 |

防禦機制：

- `pc_sanitize_key`：所有從 JSON/stdin/檔案讀進來的 key 一律過 `[A-Za-z0-9_.-]{1,128}`，再剝開頭的點。
- `pc_safe_grep_pattern`：在 `pc_release_assign` 前 escape regex metas。
- `pc_atomic_write` realpath-validate 拒絕 `..` 段與 escape 出 state_dir。
- renderer 端 `Test-KeySafe` 白名單；檔名與內含 `key=` 不一致 → 整筆丟棄。
- `Test-PidAlive` 用 `tasklist` 比對精確 PID 欄位，避免 MSYS pid 誤判（v1.2.x 舊 bug）。
- `GetLastInputInfo` 是被動讀取 API，不是 keylogger hook。本 plugin **不**安裝 `SetWindowsHookEx` / `WH_KEYBOARD_LL` 等全域 hook。

## 已知限制

- **Windows Terminal 多分頁同一 hwnd**：同一個 WT 視窗的不同分頁共用一個 hwnd，無法 per-tab 區分。「切到正確分頁」是視窗等級而非分頁等級的近似。v1.4.3 起 key（term_pid）已改為各 CLI 自己的 pid，多分頁多 CLI 的 pending 不再互撞、各有各的圖；但「回到視窗」的關閉判定仍是視窗等級（切到同視窗任一分頁都算回來）。
- **多螢幕**：預設以「最新一張 alert 的 CLI」所在螢幕作主螢幕；設 `ALERT_MONITOR=N`（1-based，超界回退預設邏輯）可固定顯示在第 N 個螢幕。所有 popup 永遠集中在同一螢幕的右下角網格，不會分散到各自 CLI 的螢幕。
- **macOS**：沒有 GetLastInputInfo 等價 API，用 `ioreg HIDIdleTime` / `System Events idle time` 近似；可能受到 sandbox 影響。
- **GetLastInputInfo wraparound**：32-bit DWORD ms 每 49.7 天 wrap，已用 `(int32)` signed-diff 處理。
- **100 張極端情況**：100 popup 即使 80px 也要 6720 像素總寬，網格切到 10 欄 + 高度受限會降到 48px 最低；視覺密度高但仍可點。

## 環境變數

| 變數 | 預設 | 用途 |
| --- | --- | --- |
| `ALERT_STATE_DIR` | `~/.claude/alert-need-human` | 狀態資料夾（測試覆寫用） |
| `ALERT_IMAGE_DIR` | `~/.claude/alert-images` | 使用者素材夾 |
| `ALERT_DEFAULT_IMAGE` | `<plugin>/assets/default-alert.png` | 後備預設圖 |
| `ALERT_LEGACY_IMAGE` | `~/.claude/alert-image.png` | 舊單張（向後相容） |
| `ALERT_MAX_POPUPS` | 100 | 同時可見上限（先到先服務；滿了之後的新 CLI 不服務） |
| `ALERT_MONITOR` | —（自動） | 指定顯示在第 N 個螢幕（1-based，Windows）；未設或超界時用「最新 alert 的 CLI 所在螢幕」。macOS renderer（tkinter）只認主螢幕，此變數無效 |
| `ALERT_DISABLE_AUTOGEN` | 0 | 設為 1 時不會自動生成 001..100 |
| `ALERT_NO_RENDERER` | 0 | 設為 1 時 alert.sh 只寫 pending，不啟動 renderer（測試用） |
| `ALERT_FAKE_WINLINE` | — | 測試用：直接指定 `"<hwnd>\t<term_pid>"` 字串 |
| `ALERT_TEST_MODE` | 0 | dot-source show-popup.ps1 時跳過 form/timer 啟動 |

## 測試矩陣（tests/run-tests.sh）

| 測試 | 保障 |
| --- | --- |
| `test-popup-common.sh` | 狀態夾、原子寫、release_assign 不誤刪、cleanup_stale |
| `test-assign.sh` | 圖片排序、佔座穩定、循環、退路鏈 |
| `test-alert.sh` | 端到端：pending 內容、reason 映射、同 key 覆寫 |
| `test-pathfix.sh` | 路徑轉換正確 + resolve 退回 default + 端到端 image_path 可開 |
| `test-cap.sh` | cap 滿時新 key 被拒、同 key update 放行、ALERT_MAX_POPUPS 覆寫、regex-injection 防護 |
| `test-autogen.sh` | 自動生成 100 張、idempotent、ALERT_IMAGE_DIR 唯讀（不被寫入） |
| `test-image-dir-override.sh` | ALERT_IMAGE_DIR 設定 / 空 / 不存在 的優先序行為 |
| `test-grid.ps1` / `.py` | 網格數學跨平台一致 |
