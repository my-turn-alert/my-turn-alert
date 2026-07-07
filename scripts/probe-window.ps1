# probe-window.ps1 — 診斷：從指定 PID 往上爬程序樹，找出 CLI 終端機視窗。
# 用法（從 Claude Code 所在的 CLI 手動執行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-window.ps1
# 或由 alert.sh 暫時帶入 hook 的 bash PID：
#   powershell ... -File scripts\probe-window.ps1 -FromPid <pid>
param([int]$FromPid = $PID)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class P {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

$termNames = @('windowsterminal','wt','powershell','pwsh','cmd','conhost','code','alacritty','wezterm')

$stateDir = Join-Path $env:USERPROFILE '.claude\alert-need-human'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$out = Join-Path $stateDir 'probe.txt'

$lines = @()
$lines += "=== probe @ FromPid=$FromPid ==="
$cw = [P]::GetConsoleWindow()
$lines += ("GetConsoleWindow() = {0}  visible={1}" -f $cw, ([P]::IsWindowVisible($cw)))

$lines += "--- parent chain (from FromPid upward) ---"
$cur = $FromPid
for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur"
    if (-not $p) { break }
    $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
    $mh = if ($proc) { $proc.MainWindowHandle } else { 0 }
    $title = if ($proc) { $proc.MainWindowTitle } else { '' }
    $name = ($p.Name -replace '\.exe$','').ToLower()
    $isTerm = $termNames -contains $name
    $mark = if ($isTerm -and $mh -ne 0) { '  <== TERMINAL+WINDOW' } elseif ($isTerm) { '  <== terminal (no MainWindowHandle)' } else { '' }
    $lines += ("[{0}] pid={1} name={2} mainHwnd={3} title='{4}'{5}" -f $i, $cur, $name, $mh, $title, $mark)
    $cur = [int]$p.ParentProcessId
}
$lines | Tee-Object -FilePath $out
Write-Host "`n--> 已寫入 $out"
