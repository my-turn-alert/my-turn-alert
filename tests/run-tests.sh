#!/usr/bin/env bash
# 跑所有可在本機自動化的測試；缺執行檔的測試會略過並提示。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "== bash: test-popup-common =="; bash "$HERE/test-popup-common.sh" || rc=1
echo "== bash: test-assign =="; [ -f "$HERE/test-assign.sh" ] && { bash "$HERE/test-assign.sh" || rc=1; }
echo "== bash: test-alert =="; [ -f "$HERE/test-alert.sh" ] && { bash "$HERE/test-alert.sh" || rc=1; }
echo "== bash: test-pathfix =="; [ -f "$HERE/test-pathfix.sh" ] && { bash "$HERE/test-pathfix.sh" || rc=1; }
echo "== bash: test-cap =="; [ -f "$HERE/test-cap.sh" ] && { bash "$HERE/test-cap.sh" || rc=1; }
echo "== bash: test-locks =="; [ -f "$HERE/test-locks.sh" ] && { bash "$HERE/test-locks.sh" || rc=1; }
echo "== bash: test-autogen =="; [ -f "$HERE/test-autogen.sh" ] && { bash "$HERE/test-autogen.sh" || rc=1; }
echo "== bash: test-image-dir-override =="; [ -f "$HERE/test-image-dir-override.sh" ] && { bash "$HERE/test-image-dir-override.sh" || rc=1; }
echo "== bash: test-getwindow =="; [ -f "$HERE/test-getwindow.sh" ] && { bash "$HERE/test-getwindow.sh" || rc=1; }
if command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
  PS=powershell; command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
  echo "== pwsh: test-grid =="; [ -f "$HERE/test-grid.ps1" ] && { "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/test-grid.ps1" 2>/dev/null || echo "$HERE/test-grid.ps1")" || rc=1; }
  echo "== pwsh: test-close-state =="; [ -f "$HERE/test-close-state.ps1" ] && { "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/test-close-state.ps1" 2>/dev/null || echo "$HERE/test-close-state.ps1")" || rc=1; }
else echo "(skip pwsh tests: powershell not found)"; fi
# 找一個「真的能跑」的 Python
PY=""
for cand in python3 python "py -3"; do
  if $cand -c "import sys; sys.exit(0)" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -n "$PY" ]; then
  echo "== py: test-grid ($PY) =="; [ -f "$HERE/test-grid.py" ] && { $PY "$HERE/test-grid.py" || rc=1; }
else
  echo "(skip py grid test: no working python interpreter found)"
fi
exit $rc
