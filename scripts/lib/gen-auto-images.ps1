# gen-auto-images.ps1 — 在 -OutDir 內生成 001.png..100.png 共 100 張編號圖。
# 用途：當使用者素材夾為空時，作為「每個 CLI 一張獨立圖」的退路。
# 設計原則：
#   - 寫入位置由呼叫端指定（popup-common.sh::pc_ensure_numbered_images 給的是 state_dir/auto-images），
#     本腳本不自行解析 ~/.claude/...；不會寫到 state_dir 以外的位置。
#   - 同一行程內生成全部 100 張，避免 100 次 PowerShell 冷啟動。
#   - 已存在的檔不覆蓋（idempotent）。
#   - 全程使用 System.Drawing；不裝任何第三方相依。
param(
  [Parameter(Mandatory=$true)][string]$OutDir,
  [int]$Count = 100
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

Add-Type -AssemblyName System.Drawing

# HSV → RGB（每張圖一個不同色相，視覺上易分辨）
function ConvertFrom-Hsv([double]$h, [double]$s, [double]$v) {
  $c = $v * $s
  $hh = $h / 60.0
  $x = $c * (1 - [Math]::Abs(($hh % 2) - 1))
  $r = 0; $g = 0; $b = 0
  switch ([int][Math]::Floor($hh) % 6) {
    0 { $r = $c; $g = $x; $b = 0 }
    1 { $r = $x; $g = $c; $b = 0 }
    2 { $r = 0;  $g = $c; $b = $x }
    3 { $r = 0;  $g = $x; $b = $c }
    4 { $r = $x; $g = 0;  $b = $c }
    5 { $r = $c; $g = 0;  $b = $x }
  }
  $m = $v - $c
  return [System.Drawing.Color]::FromArgb(
    255,
    [int][Math]::Min(255, [Math]::Max(0, [int](255 * ($r + $m)))),
    [int][Math]::Min(255, [Math]::Max(0, [int](255 * ($g + $m)))),
    [int][Math]::Min(255, [Math]::Max(0, [int](255 * ($b + $m))))
  )
}

$size = 320
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center

if ($Count -lt 1) { $Count = 1 }
if ($Count -gt 100) { $Count = 100 }
for ($i = 1; $i -le $Count; $i++) {
  $name = "{0:D3}.png" -f $i
  $path = Join-Path $OutDir $name
  if (Test-Path -LiteralPath $path) { continue }

  $bg = ConvertFrom-Hsv (($i - 1) * 3.6) 0.35 0.95
  $fg = ConvertFrom-Hsv (($i - 1) * 3.6) 0.85 0.35
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear($bg)
    $pen = New-Object System.Drawing.Pen($fg, 6)
    $g.DrawRectangle($pen, 8, 8, $size - 16, $size - 16)
    $font = New-Object System.Drawing.Font('Segoe UI', 140, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush($fg)
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $g.DrawString("$i", $font, $brush, $rect, $fmt)
    $brush.Dispose(); $font.Dispose(); $pen.Dispose(); $g.Dispose()
    $tmp = "$path.$PID.tmp"   # per-process tmp:種子行程與背景補齊行程可能同時在跑
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    Move-Item -LiteralPath $tmp -Destination $path -Force
  } finally {
    $bmp.Dispose()
  }
}
