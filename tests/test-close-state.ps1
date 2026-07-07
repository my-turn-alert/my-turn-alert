# test-close-state.ps1 — Compute-Close 純函式測試。
# 用 ALERT_TEST_MODE=1 dot-source show-popup.ps1，跳過 form/timer 啟動。
$env:ALERT_TEST_MODE = '1'
$env:ALERT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("alert-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $env:ALERT_STATE_DIR 'pending') | Out-Null

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\scripts\show-popup.ps1')

$fail = 0
function Should([bool]$cond, [string]$msg) {
  if ($cond) { Write-Host "PASS: $msg" } else { $script:fail++; Write-Host "FAIL: $msg" }
}

# Case 1：StartedInCli=true，前景持續是 CLI，但 GetLastInputInfo 沒前進 → 永遠不關
$st = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]0
  StartedInCli = $true
  BaselineLastInput = [uint32]1000
  ReturnHits = 0
  ClickRequested = $false
}
$verdict = Compute-Close $st $true ([uint32]5000) ([uint32]1000)
Should ($verdict -eq 'tick') "started-in-CLI: same lastInput → no close even after MinVisibleMs"
$verdict = Compute-Close $st $true ([uint32]10000) ([uint32]1000)
Should ($verdict -eq 'tick') "started-in-CLI: 10s passed, still same lastInput → still no close"

# Case 2：lastInput 前進 → 連續 RequiredHits 後關
$st.ReturnHits = 0
$v1 = Compute-Close $st $true ([uint32]5000) ([uint32]1100)
$v2 = Compute-Close $st $true ([uint32]5100) ([uint32]1100)
$v3 = Compute-Close $st $true ([uint32]5200) ([uint32]1100)
Should ($v1 -eq 'tick' -and $v2 -eq 'tick' -and $v3 -eq 'close') "started-in-CLI: lastInput advanced → close after 3 hits"

# Case 3：leave-then-return（StartedInCli=false）：streak 即可關，不需 lastInput
$st2 = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]0
  StartedInCli = $false
  BaselineLastInput = [uint32]1000
  ReturnHits = 0
  ClickRequested = $false
}
$v1 = Compute-Close $st2 $true ([uint32]5000) ([uint32]1000)
$v2 = Compute-Close $st2 $true ([uint32]5100) ([uint32]1000)
$v3 = Compute-Close $st2 $true ([uint32]5200) ([uint32]1000)
Should ($v1 -eq 'tick' -and $v2 -eq 'tick' -and $v3 -eq 'close') "not-in-CLI: streak alone closes without input"

# Case 4：MinVisibleMs 內無條件不關
$st3 = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]4000
  StartedInCli = $false
  BaselineLastInput = [uint32]0
  ReturnHits = 0
  ClickRequested = $false
}
$verdict = Compute-Close $st3 $true ([uint32]4500) ([uint32]9999)
Should ($verdict -eq 'tick') "MinVisibleMs floor: 500ms in → no close"

# Case 5：Click 路徑：MinVisibleMs 內也直接關
$st4 = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]4000
  StartedInCli = $true
  BaselineLastInput = [uint32]9000
  ReturnHits = 0
  ClickRequested = $true
}
$verdict = Compute-Close $st4 $false ([uint32]4100) ([uint32]9000)
Should ($verdict -eq 'close') "click: ClickRequested wins MinVisibleMs + lastInput checks"

# Case 6：DWORD wrap：BaselineLastInput=0xFFFFFFFE，current=2 → signed-diff = 4，視為「之後」
$st5 = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]0
  StartedInCli = $true
  BaselineLastInput = [uint32]([uint32]::MaxValue - 1)
  ReturnHits = 0
  ClickRequested = $false
}
$v1 = Compute-Close $st5 $true ([uint32]5000) ([uint32]2)
$v2 = Compute-Close $st5 $true ([uint32]5100) ([uint32]2)
$v3 = Compute-Close $st5 $true ([uint32]5200) ([uint32]2)
Should ($v1 -eq 'tick' -and $v2 -eq 'tick' -and $v3 -eq 'close') "DWORD wrap: signed-diff correctly detects post-wrap input"

# Case 7：fgIsCli=false 時 ReturnHits 歸零
$st6 = @{
  CliHwnd = 12345
  TermPid = 6789
  FirstShownTick = [uint32]0
  StartedInCli = $false
  BaselineLastInput = [uint32]0
  ReturnHits = 2
  ClickRequested = $false
}
$verdict = Compute-Close $st6 $false ([uint32]5000) ([uint32]9999)
Should ($verdict -eq 'tick' -and $st6.ReturnHits -eq 0) "fgIsCli=false resets ReturnHits"

# Case 8：Test-KeySafe 白名單
Should (Test-KeySafe "12345") "key '12345' is safe"
Should (Test-KeySafe "noctx-1234-5") "key 'noctx-1234-5' is safe"
Should (-not (Test-KeySafe "../etc/passwd")) "traversal '../etc/passwd' rejected"
Should (-not (Test-KeySafe "a/b")) "path-sep 'a/b' rejected"
Should (-not (Test-KeySafe "a\b")) "backslash 'a\\b' rejected"
Should (-not (Test-KeySafe "")) "empty key rejected"
Should (-not (Test-KeySafe "...")) "dots-only key rejected"

# Case 9：Test-PidAlive 必須是 in-process（快），且不可 spawn tasklist.exe
# （回歸：tasklist 每次 ~480ms，跑在 UI 執行緒會把點擊與重繪延遲數秒）。
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$selfAlive = Test-PidAlive $PID
$sw.Stop()
Should ($selfAlive) "Test-PidAlive: own PID reported alive"
Should (-not (Test-PidAlive 999999999)) "Test-PidAlive: bogus PID reported dead"
Should ($sw.ElapsedMilliseconds -lt 100) "Test-PidAlive: in-process & fast (<100ms, got $($sw.ElapsedMilliseconds)ms)"

# 原始碼層級防呆：renderer 不得在 Test-PidAlive 內 spawn tasklist.exe。
$src = Get-Content -Raw (Join-Path $here '..\scripts\show-popup.ps1')
Should (-not ($src -match 'tasklist\.exe')) "show-popup.ps1 does not spawn tasklist.exe (UI-thread starvation guard)"

# 回歸（v1.4.1 實際故障）：hwnd=0 時嚴禁退回 process-name 比對。使用者永遠在「某個」
# 終端機裡工作，名稱比對會把任何終端機視窗都當成該 CLI → 沒人理的圖 ~2 秒自己消失。
Should (-not ($src -match 'TerminalProcessNames')) "renderer has no process-name foreground fallback (spurious-close guard)"
# hwnd=0 且 term_pid=0（視窗抓取完全失敗）→ 永不視為「在 CLI」→ 只能點圖關。
Should (-not (Test-ForegroundIsCli 0 0)) "Test-ForegroundIsCli(0,0) is always false (unknown window never auto-closes)"

# 回歸：no-activate 視窗必須攔截 WM_MOUSEACTIVATE 回 MA_NOACTIVATE，否則點擊被吞 → 點圖永遠不關。
Should ($src -match 'WM_MOUSEACTIVATE') "renderer overrides WM_MOUSEACTIVATE (click-eaten guard)"
Should ($src -match 'NoActivateHook') "renderer installs NoActivateHook subclass"
# 回歸：tick 需有 re-entrancy guard，避免重排與點擊互相打架。
Should ($src -match 'InTick') "Tick-Once has re-entrancy guard"

# Case 10：點圖即時關閉的關鍵不變式 —— Compute-Close 在 ClickRequested 時無視一切立即 close
$stClick = @{
  CliHwnd = 0; TermPid = 0; FirstShownTick = [uint32]([Environment]::TickCount)
  StartedInCli = $true; BaselineLastInput = [uint32]9999; ReturnHits = 0; ClickRequested = $true
}
Should ((Compute-Close $stClick $false ([uint32]([Environment]::TickCount)) ([uint32]9999)) -eq 'close') "click closes immediately even within MinVisibleMs"

if ($fail -eq 0) {
  Write-Host "close-state: PASS"
  exit 0
} else {
  Write-Host "close-state: FAIL=$fail"
  exit 1
}
