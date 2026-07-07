# get-window.ps1 — 輸出當前 CLI 終端機視窗的 "hwnd<TAB>pid"。
# 用法：
#   powershell ... -File get-window.ps1 -Pids 1234,5678   ← 多個候選起點（推薦；單次冷啟動試多個）
#   powershell ... -File get-window.ps1 -FromPid 1234     ← 單一起點（相容舊用法）
#
# 為何吃「多個候選 pid」：Git Bash 的 hook 程序，其 Windows ParentProcessId 常指向已結束的
# 中介 forker，導致從它往上爬第一跳就斷。呼叫端（alert.sh）會沿 MSYS /proc 祖先鏈收集多個
# 候選 winpid 一次傳進來；本腳本只 Add-Type 一次、在單一行程內對每個候選各自往上爬。
#
# 三段策略（依序，找到即輸出）：
#   A. Console-title 對應（v1.4.3 新增；解 Win11 ConPTY 委派）——
#      Win11 預設把主控台委派給 Windows Terminal：shell 沒有自己的視窗，
#      視窗屬於 WindowsTerminal.exe，而 WT 不在程序樹祖先鏈上 → 舊策略全滅（hwnd=0）。
#      解法（全部唯讀 API，不改任何系統狀態）：
#        對每個祖先 AttachConsole → GetConsoleTitle → FreeConsole，
#        再用 EnumWindows 找「標題完全一致」的終端機視窗
#        （class = CASCADIA_HOSTING_WINDOW_CLASS / ConsoleWindowClass）。
#        視窗標題只反映作用中分頁；比不到時用 UI Automation（唯讀）列舉各 WT 視窗的
#        分頁名稱再比對。任何一步出現 0 或 2+ 個候選 → 視為不明，換下一祖先/下一策略，
#        絕不猜（誤綁比綁不到更糟：會誤關別人的圖、點圖切錯視窗）。
#      term_pid 輸出該「console 對應成功的祖先」pid（通常是 claude.exe 本人）：
#        同一 WT 視窗多個分頁各自的 CLI 會拿到不同 key（舊策略下全部撞成 WT pid）。
#   B. 祖先鏈終端機視窗（舊策略 1）：往上爬找「終端機名稱 + 有可見主視窗」的祖先
#      （VS Code 內建終端機、由 WT 直接生成的 shell 等走這條）。
#   C. GetConsoleWindow（舊策略 2）：黑窗（傳統 conhost）常可直接取得。
#   全滅 → "0<TAB>0"（renderer 對 (0,0) 永不自動關，只能點圖關）。
param(
  [string]$Pids = '',
  [int]$FromPid = $PID
)
$ErrorActionPreference = 'SilentlyContinue'

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class GW {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll")] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint GetConsoleTitle(StringBuilder sb, uint size);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);

  public class WinInfo { public long Hwnd; public uint Pid; public string Cls; public string Title; }
  // 只列舉「終端機類」可見視窗：WT（CASCADIA）與傳統 conhost（ConsoleWindowClass）。
  public static List<WinInfo> TerminalWindows() {
    var list = new List<WinInfo>();
    EnumWindows(delegate(IntPtr h, IntPtr lp) {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(256); GetClassName(h, cn, 256);
      string c = cn.ToString();
      if (c != "CASCADIA_HOSTING_WINDOW_CLASS" && c != "ConsoleWindowClass") return true;
      var tt = new StringBuilder(1024); GetWindowText(h, tt, 1024);
      uint p; GetWindowThreadProcessId(h, out p);
      list.Add(new WinInfo { Hwnd = h.ToInt64(), Pid = p, Cls = c, Title = tt.ToString() });
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static string ClassOf(long hwnd) {
    var sb = new StringBuilder(256); GetClassName((IntPtr)hwnd, sb, 256); return sb.ToString();
  }
}
'@

$termNames = @('windowsterminal','wt','powershell','pwsh','cmd','conhost','code','alacritty','wezterm')

# 候選起點清單：優先 -Pids（逗號分隔字串，跨 -File 邊界最可靠），否則退回單一 -FromPid。
$startPids = @()
if ($Pids -and $Pids.Trim() -ne '') {
    foreach ($tok in ($Pids -split '[,\s]+')) {
        $n = 0
        if ([int]::TryParse($tok, [ref]$n) -and $n -gt 0) { $startPids += $n }
    }
}
if ($startPids.Count -eq 0) { $startPids = @($FromPid) }

function Emit([long]$hwnd,[int]$ProcessId) { Write-Output ("{0}`t{1}" -f $hwnd, $ProcessId); exit 0 }

# 開頭先記下繼承來的 console 視窗：策略 A 會反覆 FreeConsole/AttachConsole，
# 跑完後 GetConsoleWindow 只會回 0；策略 C 要用這個「進場時」的值。
$initialCw = [GW]::GetConsoleWindow()

# 單次快照整棵程序表（一次 CIM 查詢；逐 pid 查每次 ~0.1-0.3s，祖先多時會吃掉 timeout 預算）
$procMap = @{}
foreach ($p in (Get-CimInstance Win32_Process)) {
    $procMap[[int]$p.ProcessId] = @{
        Name   = (($p.Name -replace '\.exe$','')).ToLower()
        Parent = [int]$p.ParentProcessId
    }
}

# 合併所有候選起點的祖先鏈（保序去重；淺者優先 → term_pid 盡量貼近 CLI 本人）
$ancestors = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($start in $startPids) {
    $cur = [int]$start
    for ($i = 0; $i -lt 12 -and $cur -gt 4; $i++) {
        if (-not $procMap.ContainsKey($cur)) { break }
        if (-not $seen.ContainsKey($cur)) { $seen[$cur] = $true; [void]$ancestors.Add($cur) }
        $next = $procMap[$cur].Parent
        if ($next -eq $cur) { break }
        $cur = $next
    }
}

# --- 策略 A：console-title 對應（唯讀；解 ConPTY 委派） ---
$termWins = [GW]::TerminalWindows()

function Find-ByTabName([string]$title) {
    # 視窗標題比不到（CLI 分頁非作用中）時，用 UI Automation 唯讀列舉每個 WT 視窗的
    # 分頁名稱。恰好一個視窗含同名分頁才回傳；0 或 2+ → $null（不猜）。
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes } catch { return $null }
    $hits = @()
    foreach ($w in $termWins) {
        if ($w.Cls -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { continue }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
            if ($null -eq $root) { continue }
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::TabItem)
            $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
            foreach ($t in $tabs) {
                if ($t.Current.Name -eq $title) { $hits += $w; break }
            }
        } catch {}
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

if ($termWins.Count -gt 0) {
    foreach ($a in $ancestors) {
        [void][GW]::FreeConsole()
        if (-not [GW]::AttachConsole([uint32]$a)) { continue }
        $sb = New-Object System.Text.StringBuilder 1024
        [void][GW]::GetConsoleTitle($sb, 1024)
        $title = $sb.ToString()
        $cw = [GW]::GetConsoleWindow().ToInt64()
        [void][GW]::FreeConsole()

        # A-a) 傳統 conhost：console 自帶真視窗（class 必須是 ConsoleWindowClass；
        #      ConPTY 的假視窗會謊稱 visible，class 不同，靠 class 排除）。
        if ($cw -ne 0 -and [GW]::ClassOf($cw) -eq 'ConsoleWindowClass' -and [GW]::IsWindowVisible([IntPtr]$cw)) {
            Emit $cw $a
        }
        if (-not $title) { continue }
        # A-b) 視窗標題完全一致（CLI 分頁正是作用中分頁）；恰好一個才算
        $exact = @($termWins | Where-Object { $_.Title -eq $title })
        if ($exact.Count -eq 1) { Emit $exact[0].Hwnd $a }
        # A-c) UIA 分頁名稱比對（CLI 分頁不在前面時）
        $byTab = Find-ByTabName $title
        if ($null -ne $byTab) { Emit $byTab.Hwnd $a }
    }
}

# --- 策略 B：祖先鏈上「終端機名稱 + 有可見主視窗」（VS Code、WT 直生 shell 等） ---
foreach ($a in $ancestors) {
    if (-not ($termNames -contains $procMap[$a].Name)) { continue }
    $proc = Get-Process -Id $a -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0 -and [GW]::IsWindowVisible($proc.MainWindowHandle)) {
        Emit ([long]$proc.MainWindowHandle) ([int]$a)
    }
}

# --- 策略 C：進場時的 GetConsoleWindow（黑窗常可直接取得），用視窗取得擁有它的 pid。
#     限 ConsoleWindowClass：ConPTY 的 PseudoConsoleWindow 會謊稱 visible，不可誤信。 ---
if ($initialCw -ne [IntPtr]::Zero -and
    [GW]::ClassOf($initialCw.ToInt64()) -eq 'ConsoleWindowClass' -and
    [GW]::IsWindowVisible($initialCw)) {
    $opid = 0; [void][GW]::GetWindowThreadProcessId($initialCw, [ref]$opid)
    Emit ([long]$initialCw) ([int]$opid)
}

# 皆失敗
Emit 0 0
