# show-popup.ps1 — Windows 長駐 renderer（單一實例）。
# 輪詢狀態夾，把所有 pending 圖排成自適應網格顯示於右下角；不搶焦點。
#
# 圖消失的時機（任一即可）：
#   1) 點擊圖片：立刻關閉並把對應 CLI 視窗叫到前景。
#   2) 「使用者實際在對應 CLI 操作」——以 GetLastInputInfo 偵測。
#      - 若 popup 出現時你『沒有』在那個 CLI（StartedInCli=false）→
#        切回該 CLI（前景 hwnd 等於該 CLI 的 hwnd）連續 RequiredHits ticks 即關。
#      - 若 popup 出現時你『已經』在那個 CLI（StartedInCli=true）→
#        必須前景持續是該 CLI 且 GetLastInputInfo 出現新輸入（鍵盤/滑鼠任一動作）
#        晚於 popup 出現的時間，才會關。這對應「在此視窗再點一下或敲一鍵才消失」。
#   * 最低顯示 MinVisibleMs（1500ms）內絕不關，避免一瞬白屏。
#   * 比對「前景是哪一個 CLI」一律用 hwnd 而非 process name（解決 v1.2.x 多 CLI 互擾）。
#
# 安全：
#   - 從 pending 讀到的 key 一律經白名單過濾（^[A-Za-z0-9_.-]{1,128}$），防 path traversal。
#   - renderer 只刪 pending 內、組合自白名單 key 的 .txt。
#   - 不裝/移除全域 hook；GetLastInputInfo 是被動讀取 API，不攔截鍵盤滑鼠。

param(
  [int]$MaxPerRow = 3,
  [double]$MaxLayoutWidthRatio = 0.40,
  [int]$CellMaxPx = 320,
  [int]$GapPx = 12,
  [int]$MarginPx = 20,
  [int]$PollMs = 100,
  [int]$MinVisibleMs = 1500,
  [int]$RequiredHits = 3,
  [int]$LiveSweepMs = 2000
)

$ErrorActionPreference = 'Stop'

# 共用 grid 數學
. "$PSScriptRoot/lib/grid.ps1"

$StateDir = if ($env:ALERT_STATE_DIR) { $env:ALERT_STATE_DIR } else { Join-Path $env:USERPROFILE '.claude\alert-need-human' }
$PendingDir = Join-Path $StateDir 'pending'
New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
$PidFile = Join-Path $StateDir 'renderer.pid'

# 內建 default（讀到的 image_path 開不了時做最後退路）
$DefaultImage = if ($env:ALERT_DEFAULT_IMAGE) { $env:ALERT_DEFAULT_IMAGE } else { Join-Path $PSScriptRoot '..\assets\default-alert.png' }

$MaxPopups = if ($env:ALERT_MAX_POPUPS) { [int]$env:ALERT_MAX_POPUPS } else { 100 }
if ($MaxPopups -lt 1) { $MaxPopups = 1 }

# 單格尺寸上限：張數少時 cell 由版面寬除出來會大得離譜（單張 = 螢幕寬 40%），
# 設上限讓 1~3 張時維持角落小圖。ALERT_CELL_MAX 可覆寫。
if ($env:ALERT_CELL_MAX -match '^[0-9]+$') { $CellMaxPx = [int]$env:ALERT_CELL_MAX }
if ($CellMaxPx -lt 80) { $CellMaxPx = 80 }

# 指定顯示螢幕（1-based）。未設 / 非數字 / 超界 → 0 = 自動（最新 alert 的 CLI 所在螢幕）。
$MonitorIndex = 0
if ($env:ALERT_MONITOR -match '^[0-9]+$') { $MonitorIndex = [int]$env:ALERT_MONITOR }

# 診斷記錄（預設關閉）：設 ALERT_DEBUG=1 時，把事件寫到 state_dir/renderer-debug.log。
$DebugLog = if ($env:ALERT_DEBUG -eq '1') { Join-Path $StateDir 'renderer-debug.log' } else { $null }
function Write-Dbg([string]$msg) {
  if ($null -eq $DebugLog) { return }
  try { Add-Content -LiteralPath $DebugLog -Value ("{0} {1}" -f ([Environment]::TickCount), $msg) -ErrorAction SilentlyContinue } catch {}
}

# 測試模式：dot-source 用；不啟動 form/timer。
$TestMode = $env:ALERT_TEST_MODE -eq '1'

# 啟動時清掉孤兒 click 訊號檔（若上次 renderer 在消費 .sig 前就被關掉）。
try { Get-ChildItem -LiteralPath $StateDir -Filter 'clicked-*.sig' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}

# 單一實例：原子寫入 PID，殺舊 renderer。
if (Test-Path -LiteralPath $PidFile) {
  try {
    $oldPid = [int](Get-Content -LiteralPath $PidFile -ErrorAction Stop | Select-Object -First 1)
    $op = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($op -and $op.ProcessName -match '^(powershell|pwsh)$' -and $oldPid -ne $PID) {
      Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
if (-not $TestMode) {
  try {
    $tmp = "$PidFile.new"
    Set-Content -LiteralPath $tmp -Value $PID -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tmp -Destination $PidFile -Force -ErrorAction SilentlyContinue
  } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);

  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
}
'@

# WS_EX_NOACTIVATE 視窗的點擊難題：彈窗永遠非前景，所以每次點擊都是「啟動點擊」，
# Windows 先送 WM_MOUSEACTIVATE，預設 WndProc 常回 MA_NOACTIVATEANDEAT(4) → 吞掉
# WM_LBUTTONDOWN，於是 PictureBox 的 MouseDown/Click 永遠不觸發（點了沒反應的根因）。
# 解法：subclass 表單的 WndProc，對 WM_MOUSEACTIVATE 一律回 MA_NOACTIVATE(3)：不奪焦、
# 也不吞點擊。這是被動攔截自己視窗訊息，不裝任何全域 hook，符合安全邊界。
Add-Type @'
using System;
using System.Windows.Forms;
public class NoActivateHook : NativeWindow {
  const int WM_MOUSEACTIVATE = 0x0021;
  const int MA_NOACTIVATE = 0x0003;   // 不奪焦、不吞點擊
  public NoActivateHook(Form f) { this.AssignHandle(f.Handle); }
  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATE; return; }
    base.WndProc(ref m);
  }
}
'@ -ReferencedAssemblies System.Windows.Forms

function Get-LastInputTick {
  $info = New-Object Fg+LASTINPUTINFO
  $info.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type]([Fg+LASTINPUTINFO]))
  [void][Fg]::GetLastInputInfo([ref]$info)
  return [uint32]$info.dwTime
}

function Test-PidAlive([int]$ProcessId) {
  # 用 in-process Get-Process（微秒級），絕不在 UI 執行緒上 spawn 外部行程查詢
  # （每次 ~480ms，會把 WinForms 訊息泵餓死 → 點擊與重繪都延遲數秒）。
  # term_pid 來自 /proc/winpid 祖先鏈，是真正的 Windows pid，Get-Process 查得到。
  if ($ProcessId -le 0) { return $false }
  try {
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { return $true }
  } catch {}
  return $false
}

function Focus-Window([int64]$hwnd) {
  if ($hwnd -eq 0) { return }
  $h = [IntPtr]$hwnd
  if (-not [Fg]::IsWindow($h)) { return }
  [void][Fg]::ShowWindow($h, 9)   # SW_RESTORE
  $fg = [Fg]::GetForegroundWindow()
  $tFg = 0; [void][Fg]::GetWindowThreadProcessId($fg, [ref]$tFg)
  $tMe = [Fg]::GetCurrentThreadId()
  try {
    [void][Fg]::AttachThreadInput($tMe, $tFg, $true)
    [void][Fg]::SetForegroundWindow($h)
  } finally {
    [void][Fg]::AttachThreadInput($tMe, $tFg, $false)
  }
}

function Remove-Item-Pending([string]$key) {
  if (-not (Test-KeySafe $key)) { return }
  Remove-Item -LiteralPath (Join-Path $PendingDir "$key.txt") -ErrorAction SilentlyContinue
  # ack 戳記：使用者已看過並關閉此 CLI 的圖。alert.sh 據此在短時間內
  # 抑制同一 CLI 的 idle 重複提醒（Stop 後 ~60s Claude Code 會再發
  # idle_prompt → 沒有戳記的話圖會「幽靈重現」）。
  try { Set-Content -LiteralPath (Join-Path $StateDir "acked-$key.stamp") -Value '1' -ErrorAction SilentlyContinue } catch {}
}

function Close-Popup([string]$k, $box) {
  # 點圖的統一關閉路徑。順序刻意為：先把圖移除 + 刪 pending（使用者要的「秒關」），
  # 最後才 Focus-Window —— 即使聚焦動作慢或丟例外，圖也已經消失了。
  # idempotent：重複呼叫（MouseDown + Click 都觸發）不會出錯。
  try {
    if ([string]::IsNullOrEmpty($k)) { return }
    if (-not (Test-KeySafe $k)) { return }
    Write-Dbg "Close-Popup k=$k itemsBefore=$($script:Items.Count)"
    $it = $script:Items[$k]
    $hwnd = if ($null -ne $it) { [int64]$it.Hwnd } else { 0 }

    # 1) 立刻視覺移除（Image 先摘下再 Dispose，防 ImageAnimator 碰到死 Image）
    if ($null -ne $box) {
      if ($null -ne $box.Image) {
        $oldImg = $box.Image
        try { $box.Image = $null } catch {}
        try { $oldImg.Dispose() } catch {}
      }
      try { $form.Controls.Remove($box) } catch {}
      try { $box.Dispose() } catch {}
    }
    # 2) 清狀態 + 刪 pending 檔
    $script:Items.Remove($k) | Out-Null
    $script:KeyState.Remove($k) | Out-Null
    Remove-Item-Pending $k
    # 3) 重排或收尾
    if ($script:Items.Count -gt 0) { Layout-And-Render } else { Sync-Pending }
    # 4) 最後才聚焦對應 CLI（慢/失敗都不影響上面的關閉）
    if ($hwnd -ne 0) { Focus-Window $hwnd }
    Write-Dbg "Close-Popup done k=$k itemsAfter=$($script:Items.Count)"
  } catch { Write-Dbg "Close-Popup ERR $($_.Exception.Message)" }
}

function Test-KeySafe([string]$key) {
  # 白名單：只接受 [A-Za-z0-9_.-]{1,128}；防 path traversal。
  if (-not $key) { return $false }
  return ($key -match '^[A-Za-z0-9_.\-]{1,128}$') -and ($key -notmatch '^\.+$')
}

function Set-BoxImage([System.Windows.Forms.PictureBox]$pb, [string]$path) {
  if ($path -and (Test-Path -LiteralPath $path)) {
    try { $pb.Image = [System.Drawing.Image]::FromFile($path); return } catch {}
  }
  if ($DefaultImage -and (Test-Path -LiteralPath $DefaultImage)) {
    try { $pb.Image = [System.Drawing.Image]::FromFile($DefaultImage); return } catch {}
  }
  try {
    $w = [Math]::Max(80, $pb.Width); $h = [Math]::Max(80, $pb.Height)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 255, 244, 214))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 200, 60, 60), 3)
    $g.DrawRectangle($pen, 2, 2, $w - 5, $h - 5)
    $name = if ($path) { Split-Path -Leaf $path } else { '(no image)' }
    $msg = "image load failed`n$name"
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 120, 40, 0))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($msg, $font, $brush, (New-Object System.Drawing.RectangleF(4, 4, $w - 8, $h - 8)), $fmt)
    $g.Dispose()
    $pb.Image = $bmp
  } catch {}
}

# 不搶焦點的視窗
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.BackColor = [System.Drawing.Color]::White

$script:Items = @{}
# 每個 key 的關閉狀態機：
#   CliHwnd            該 CLI 的視窗 handle（pending 內 hwnd 欄）
#   TermPid            該 CLI 的 Windows pid（pending 內 term_pid 欄；0 表示未知）
#   FirstShownTick     首次出現的 TickCount（算最低顯示時間）
#   StartedInCli       popup 出現的瞬間使用者是否已在該 CLI（決定關閉條件）
#   BaselineLastInput  popup 出現時的 GetLastInputInfo 值（StartedInCli=true 用）
#   ReturnHits         前景命中該 CLI 的連續次數（去抖）
#   ClickRequested     使用者已點圖（下一次 tick 立即關 + 聚焦）
$script:KeyState = @{}
$script:LastLiveSweep = [uint32]0   # 上次掃 term_pid 存活的 TickCount（節流用）
$script:InTick = $false             # Tick-Once re-entrancy guard
$script:NoAct = $null               # WM_MOUSEACTIVATE 攔截器（維持參考避免 GC）

function Test-ForegroundIsCli($CliHwnd, $TermPid) {
  $fg = [Fg]::GetForegroundWindow()
  if ($CliHwnd -ne 0) { return ($fg -eq [IntPtr]$CliHwnd) }
  # hwnd 未知：只接受「前景視窗擁有者 pid == 該 CLI 的 term_pid」的精確比對。
  # 絕不可退回 process-name 比對——使用者永遠在「某個」終端機裡工作，名稱比對會把
  # 任何終端機視窗都當成該 CLI，圖在沒人理它時 ~2 秒就自己消失（v1.4.1 實際故障）。
  # 兩者皆未知（0,0）→ 永不自動關：只能點圖關，或 CLI 死亡由自癒清除。
  if ($TermPid -ne 0) {
    $fgPid = 0; [void][Fg]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    return ($fgPid -eq $TermPid)
  }
  return $false
}

function Read-Pending {
  $result = @{}
  Get-ChildItem -LiteralPath $PendingDir -Filter *.txt -ErrorAction SilentlyContinue | ForEach-Object {
    $rawKey = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    if (-not (Test-KeySafe $rawKey)) { return }
    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)) {
      $idx = $line.IndexOf('=')
      if ($idx -gt 0) { $h[$line.Substring(0,$idx)] = $line.Substring($idx+1) }
    }
    if ($h.ContainsKey('key')) {
      $k = $h['key']
      if (-not (Test-KeySafe $k)) { return }
      if ($k -ne $rawKey) { return }   # 檔名與內含 key 必須一致
      $result[$k] = @{
        Path    = $h['image_path']
        Hwnd    = [int64]($h['hwnd'])
        TermPid = [int]($h['term_pid'])
        Seq     = [int]($h['seq'])
      }
    }
  }
  return $result
}

function Compute-GridCell([int]$n, [int]$maxLayoutW, [int]$maxLayoutH) {
  $cols = Get-GridCols $n $MaxPerRow
  # n>9 時改採 ceil(sqrt(n)) 不超過 10，避免 100 張時 3 欄會塞滿整個螢幕高
  if ($n -gt 9) {
    $cols = [Math]::Min(10, [int][Math]::Ceiling([Math]::Sqrt($n)))
    if ($cols -lt $MaxPerRow) { $cols = $MaxPerRow }
  }
  $rows = Get-GridRows $n $cols
  $cell = [int](($maxLayoutW - ($cols + 1) * $GapPx) / $cols)
  if ($cell -gt $CellMaxPx) { $cell = $CellMaxPx }
  if ($cell -lt 80) { $cell = 80 }
  $needH = $rows * $cell + ($rows + 1) * $GapPx
  if ($needH -gt $maxLayoutH) {
    $cell = [int](($maxLayoutH - ($rows + 1) * $GapPx) / $rows)
    if ($cell -lt 48) { $cell = 48 }
  }
  return @{ Cols = $cols; Rows = $rows; Cell = $cell }
}

function Layout-And-Render {
  # 先把 Image 從 PictureBox 摘下來（設 null）再 Dispose：
  # 若在還掛著的狀態下 Dispose，PictureBox 的 ImageAnimator（重排/移除時會呼叫
  # Animate/CanAnimate → get_FrameDimensionsList）會碰到已死的 Image →
  # ArgumentException「參數無效」跳 .NET JIT 錯誤對話框（v1.4.2 實際故障，
  # 第二張 popup 出現觸發重排時發生）。
  foreach ($c in @($form.Controls)) {
    if ($c -is [System.Windows.Forms.PictureBox] -and $null -ne $c.Image) {
      $old = $c.Image
      $c.Image = $null
      try { $old.Dispose() } catch {}
    }
  }
  $form.Controls.Clear()
  # @(...) 強制陣列化：單一 key 時 .Keys | Sort-Object 會回單字串，索引會取到字元。
  $keys = @($script:Items.Keys | Sort-Object { $script:Items[$_].Seq })
  if ($keys.Count -gt $MaxPopups) { $keys = @($keys[0..($MaxPopups - 1)]) }
  $n = $keys.Count
  if ($n -eq 0) { return }

  # 多螢幕：ALERT_MONITOR=N（1-based）指定第 N 個螢幕；未設或超界 → 以「最新一張
  # alert 的 CLI」所在螢幕為主，無則用 Primary。
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $pinned = $false
  if ($MonitorIndex -ge 1) {
    try {
      $screens = @([System.Windows.Forms.Screen]::AllScreens)
      if ($MonitorIndex -le $screens.Count) {
        $area = $screens[$MonitorIndex - 1].WorkingArea
        $pinned = $true
      }
    } catch {}
  }
  if (-not $pinned) {
    try {
      $latestKey = $keys[$n - 1]
      $latestHwnd = $script:Items[$latestKey].Hwnd
      if ($latestHwnd -ne 0) {
        $scr = [System.Windows.Forms.Screen]::FromHandle([IntPtr]$latestHwnd)
        if ($scr) { $area = $scr.WorkingArea }
      }
    } catch {}
  }

  $maxLayoutW = [int]($area.Width * $MaxLayoutWidthRatio)
  if ($n -gt 9) { $maxLayoutW = [int]($area.Width * 0.85) }   # 多張時放寬版面
  $maxLayoutH = [int]($area.Height * 0.9)
  $g = Compute-GridCell $n $maxLayoutW $maxLayoutH
  $cols = $g.Cols; $rows = $g.Rows; $cell = $g.Cell

  $layoutW = $cols * $cell + ($cols + 1) * $GapPx
  $layoutH = $rows * $cell + ($rows + 1) * $GapPx
  $form.Width = $layoutW
  $form.Height = $layoutH
  $form.Left = $area.X + $area.Width  - $layoutW - $MarginPx
  $form.Top  = $area.Y + $area.Height - $layoutH - $MarginPx

  for ($i = 0; $i -lt $n; $i++) {
    $k = $keys[$i]
    $rowI = [int][Math]::Floor($i / $cols)
    $colI = $i % $cols
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pb.Width = $cell; $pb.Height = $cell
    $pb.Left = $GapPx + $colI * ($cell + $GapPx)
    $pb.Top  = $GapPx + $rowI * ($cell + $GapPx)
    $pb.BackColor = [System.Drawing.Color]::White
    Set-BoxImage $pb $script:Items[$k].Path
    $pb.Tag = $k
    $form.Controls.Add($pb)
    # 只綁 MouseDown（在 no-activate 視窗上比 Click 可靠，且配合 NoActivateHook 一定觸發）。
    # 事件內只做「最小事」：標記 ClickRequested + 立刻把這張藏起來（即時回饋）。
    # 真正的移除/重排留給下一個 tick 在乾淨的 stack 上做，避免「事件還在 stack 上就 dispose
    # 自己」造成 ObjectDisposedException 被吞掉、看起來像沒反應。
    # 重要：事件處理器內【不可】依賴 $script:KeyState / $script:Items 等 script 變數——
    # WinForms 事件回呼的執行 runspace 與 script 主體不同，$script:* 在此解析為 $null，
    # 呼叫 .ContainsKey() 會丟「在 null 上呼叫方法」並被 catch 吞掉 → 點圖永遠沒反應。
    # 解法：handler 只用「事件參數本身就有」的東西（$sender.Tag = key、$PendingDir、$StateDir），
    # 直接刪 pending 檔（檔案是跨 runspace 共享的真實狀態），並把這張藏起來即時回饋。
    # 真正的移除/重排/聚焦交給下一個 tick（在正確的 script 範圍執行）。
    $pb.Add_MouseDown({
      param($sender, $e)
      try {
        $key = "$($sender.Tag)"
        # 寫一個 click 訊號檔，讓 tick 知道「這是點擊關閉」→ 要把對應 CLI 叫到前景。
        if ($key -match '^[A-Za-z0-9_.\-]{1,128}$') {
          $sig = Join-Path $StateDir ("clicked-" + $key + ".sig")
          try { Set-Content -LiteralPath $sig -Value '1' -ErrorAction SilentlyContinue } catch {}
          # ack 戳記：抑制 Stop 之後尾隨的 idle_prompt 讓圖幽靈重現
          try { Set-Content -LiteralPath (Join-Path $StateDir ("acked-" + $key + ".stamp")) -Value '1' -ErrorAction SilentlyContinue } catch {}
          $pf = Join-Path $PendingDir ($key + ".txt")
          Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue
        }
        try { $sender.Visible = $false } catch {}
      } catch {}
    }.GetNewClosure())
    $script:Items[$k].Box = $pb
  }
}

function Init-KeyState([string]$k, [hashtable]$item, [uint32]$nowTick, [uint32]$lastInput) {
  $fg = [Fg]::GetForegroundWindow()
  $startedIn = $false
  if ($item.Hwnd -ne 0 -and $fg -eq [IntPtr]$item.Hwnd) {
    $startedIn = $true
  } elseif ($item.Hwnd -eq 0 -and $item.TermPid -ne 0) {
    $fgPid = 0; [void][Fg]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    if ($fgPid -eq $item.TermPid) { $startedIn = $true }
  }
  return @{
    CliHwnd           = [int64]$item.Hwnd
    TermPid           = [int]$item.TermPid
    FirstShownTick    = $nowTick
    StartedInCli      = $startedIn
    BaselineLastInput = $lastInput
    ReturnHits        = 0
    ClickRequested    = $false
  }
}

function Compute-Close([hashtable]$st, [bool]$fgIsCli, [uint32]$nowTick, [uint32]$lastInput) {
  # 回傳：'close'（該關）、'tick'（繼續）；ReturnHits 由呼叫端維護。
  if ($st.ClickRequested) { return 'close' }
  if (([int32]($nowTick - $st.FirstShownTick)) -lt $MinVisibleMs) { return 'tick' }
  if (-not $fgIsCli) {
    $st.ReturnHits = 0
    return 'tick'
  }
  if ($st.StartedInCli) {
    # 必須在 CLI 內看到新的輸入活動（任意鍵或滑鼠）才關。
    # 用 signed 差值跨越 32-bit DWORD wrap：手動 normalize 進 [-2^31, 2^31) 區間。
    $diff = [long]$lastInput - [long]$st.BaselineLastInput
    if ($diff -gt 0x7FFFFFFFL) { $diff -= 0x100000000L }
    elseif ($diff -lt -0x80000000L) { $diff += 0x100000000L }
    if ($diff -le 0) {
      $st.ReturnHits = 0
      return 'tick'
    }
  }
  $st.ReturnHits++
  if ($st.ReturnHits -ge $RequiredHits) { return 'close' }
  return 'tick'
}

function Sync-Pending {
  $latest = Read-Pending
  # 自癒：term_pid 已死 → 刪 pending。每 ~2 秒掃一次即可（Get-Process 雖快，
  # 但沒必要每 100ms 對每張圖都查），避免無謂負載。
  $nowSweep = [uint32][Environment]::TickCount
  if (([int32]($nowSweep - $script:LastLiveSweep)) -ge $LiveSweepMs) {
    $script:LastLiveSweep = $nowSweep
    foreach ($k in @($latest.Keys)) {
      $tp = $latest[$k].TermPid
      if ($tp -le 0) { continue }
      if (-not (Test-PidAlive $tp)) {
        Remove-Item-Pending $k
        $latest.Remove($k)
      }
    }
  }
  # 點圖訊號：handler 會刪 pending 檔 + 寫 clicked-<key>.sig。這裡偵測「消失但有 sig」的 key，
  # 用我們還握有的舊 hwnd 把對應 CLI 叫到前景，然後刪 sig。（handler 跨 runspace 無法存取
  # $script:Items，故聚焦這步留在 tick 做。）
  foreach ($k in @($script:Items.Keys)) {
    if (-not $latest.ContainsKey($k)) {
      $sig = Join-Path $StateDir ("clicked-" + $k + ".sig")
      if (Test-Path -LiteralPath $sig) {
        $hwndc = [int64]$script:Items[$k].Hwnd
        Write-Dbg "click-close k=$k hwnd=$hwndc"
        if ($hwndc -ne 0) { Focus-Window $hwndc }
        Remove-Item -LiteralPath $sig -ErrorAction SilentlyContinue
      }
    }
  }

  $changed = $false
  if ($latest.Count -ne $script:Items.Count) { $changed = $true }
  else {
    foreach ($k in $latest.Keys) {
      if (-not $script:Items.ContainsKey($k) -or $script:Items[$k].Path -ne $latest[$k].Path) { $changed = $true; break }
    }
  }
  $script:Items = $latest

  $now = [uint32][Environment]::TickCount
  $lastInput = Get-LastInputTick
  foreach ($k in @($latest.Keys)) {
    if (-not $script:KeyState.ContainsKey($k)) {
      $script:KeyState[$k] = Init-KeyState $k $latest[$k] $now $lastInput
    }
  }
  foreach ($k in @($script:KeyState.Keys)) {
    if (-not $latest.ContainsKey($k)) { $script:KeyState.Remove($k) }
  }

  if ($latest.Count -eq 0) {
    try {
      if ((Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1) -eq "$PID") {
        Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
      }
    } catch {}
    if ($null -ne $script:Timer) { $script:Timer.Stop() }
    if ($null -ne $form -and $form.Visible) { $form.Close() }
    return
  }
  if ($changed) { Layout-And-Render }
  if ($null -ne $form -and -not $form.Visible) { $form.Show() }
}

function Tick-Once {
  # 防 re-entrancy：tick 內若做了較重的事（重排、I/O），避免下一個 WM_TIMER 插進來。
  if ($script:InTick) { return }
  $script:InTick = $true
  try {
    $now = [uint32][Environment]::TickCount
    $lastInput = Get-LastInputTick
    $closeKeys = New-Object System.Collections.ArrayList
    foreach ($k in @($script:Items.Keys)) {
      $st = $script:KeyState[$k]
      if ($null -eq $st) { continue }
      $it = $script:Items[$k]
      $fgIsCli = Test-ForegroundIsCli $it.Hwnd $it.TermPid
      $verdict = Compute-Close $st $fgIsCli $now $lastInput
      if ($verdict -eq 'close') { [void]$closeKeys.Add($k) }
    }
    foreach ($k in $closeKeys) {
      Write-Dbg "tick close k=$k"
      # 自動關閉（回到 CLI）：移除 pending + 狀態即可，不需聚焦（使用者本來就在那）。
      # 點圖關閉走另一條路：handler 刪 pending + 寫 .sig，由 Sync-Pending 負責聚焦。
      Remove-Item-Pending $k
      $script:KeyState.Remove($k) | Out-Null
    }
    Sync-Pending
  } catch { Write-Dbg "Tick ERR $($_.Exception.Message)" }
  finally { $script:InTick = $false }
}

if ($TestMode) { return }

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $PollMs
$script:Timer.Add_Tick({ Tick-Once })

$form.Add_Shown({ $script:Timer.Start() })
$GWL_EXSTYLE = -20
$form.Add_HandleCreated({
  try {
    $ex = [Fg]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
    [void][Fg]::SetWindowLong($form.Handle, $GWL_EXSTYLE, $ex -bor 0x08000000 -bor 0x00000080)
    # 掛上 WM_MOUSEACTIVATE → MA_NOACTIVATE 攔截，讓點擊不被吞。
    # 存到 $script:NoAct 維持參考，避免 .NET wrapper 被 GC 後攔截失效。
    $script:NoAct = New-Object NoActivateHook($form)
    Write-Dbg "NoActivateHook attached hwnd=$($form.Handle)"
  } catch { Write-Dbg "HandleCreated ERR $($_.Exception.Message)" }
})
$form.Add_Load({ try { Sync-Pending } catch {} })

Write-Dbg "renderer start PID=$PID pending=$PendingDir"
[void]$form.ShowDialog()
Write-Dbg "renderer exit PID=$PID"
