function Get-GridCols([int]$n, [int]$M = 3) {
  if ($n -le 0) { return 0 }
  if ($n -le $M) { return $n }
  return [Math]::Min($M, [int][Math]::Ceiling([Math]::Sqrt($n)))
}
function Get-GridRows([int]$n, [int]$c) {
  if ($c -le 0) { return 0 }
  return [int][Math]::Ceiling($n / [double]$c)
}
