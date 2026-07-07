. "$PSScriptRoot/../scripts/lib/grid.ps1"

$cases = @(
  @{n=0;c=0;r=0}, @{n=1;c=1;r=1}, @{n=2;c=2;r=1}, @{n=3;c=3;r=1},
  @{n=4;c=2;r=2}, @{n=5;c=3;r=2}, @{n=6;c=3;r=2}, @{n=7;c=3;r=3}, @{n=9;c=3;r=3},
  @{n=10;c=3;r=4}, @{n=12;c=3;r=4}
)
$fail = 0
foreach($x in $cases){
  $c = Get-GridCols $x.n 3; $r = Get-GridRows $x.n $c
  if($c -ne $x.c -or $r -ne $x.r){ $fail++; Write-Host ("FAIL n={0}: got {1}x{2} want {3}x{4}" -f $x.n,$r,$c,$x.r,$x.c) }
}
# M!=3 case
if((Get-GridCols 4 2) -ne 2){ $fail++; Write-Host "FAIL n=4,M=2: cols not 2" }
if((Get-GridRows 4 2) -ne 2){ $fail++; Write-Host "FAIL n=4,M=2: rows not 2" }
if($fail -eq 0){ Write-Host "grid: PASS"; exit 0 } else { Write-Host "grid: FAIL=$fail"; exit 1 }
