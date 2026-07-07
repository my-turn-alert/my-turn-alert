#!/usr/bin/env bash
# test-getwindow.sh — get-window.ps1 的煙霧測試（Windows only）。
# 視窗環境因機而異，無法斷言特定 hwnd；鎖的是不變式：
#   1) 輸出永遠恰好一行 "數字<TAB>數字"（呼叫端 cut -f 依賴此格式）。
#   2) 不存在的 pid → 優雅回 "0<TAB>0"，不噴錯、不掛住。
#   3) 從本測試自己的祖先鏈呼叫 → hwnd 與 pid 同時為 0 或同時非 0
#      （絕不能只有其中一個有值），且在 timeout 預算內完成。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *) echo "(skip: not Windows)"; exit 0 ;;
esac
PS=powershell; command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
GW="$HERE/../scripts/get-window.ps1"
command -v cygpath >/dev/null 2>&1 && GW="$(cygpath -w "$GW")"

PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

# Case 1+2: 不存在的 pid → "0<TAB>0"，單行，格式正確
out="$(timeout 20 "$PS" -NoProfile -ExecutionPolicy Bypass -File "$GW" -Pids "999999" 2>/dev/null | tr -d '\r')"
lines="$(printf '%s' "$out" | grep -c . || true)"
ok "$lines" "1" "bogus pid: exactly one output line"
ok "$out" "$(printf '0\t0')" "bogus pid: graceful 0<TAB>0"

# Case 3: 真實祖先鏈 → 格式正確且 hwnd/pid 同進退
_cands=""; _cur="$$"; _i=0
while [ "$_i" -lt 8 ] && [ -n "$_cur" ] && [ "$_cur" != "0" ] && [ "$_cur" != "1" ]; do
  _wp="$(cat "/proc/$_cur/winpid" 2>/dev/null)"
  [ -n "$_wp" ] && _cands="${_cands:+$_cands,}$_wp"
  _ppid="$(cat "/proc/$_cur/ppid" 2>/dev/null)"
  [ "$_ppid" = "$_cur" ] && break
  _cur="$_ppid"
  _i=$((_i + 1))
done
out="$(timeout 20 "$PS" -NoProfile -ExecutionPolicy Bypass -File "$GW" -Pids "$_cands" 2>/dev/null | tr -d '\r')"
if printf '%s' "$out" | grep -qE '^[0-9]+	[0-9]+$'; then
  ok fmt fmt "real ancestry: output is 'digits<TAB>digits'"
else
  ok "bad[$out]" fmt "real ancestry: output is 'digits<TAB>digits'"
fi
hwnd="$(printf '%s' "$out" | cut -f1)"; tpid="$(printf '%s' "$out" | cut -f2)"
if { [ "$hwnd" = "0" ] && [ "$tpid" = "0" ]; } || { [ "$hwnd" != "0" ] && [ "$tpid" != "0" ]; }; then
  ok paired paired "real ancestry: hwnd & pid both zero or both non-zero"
else
  ok "split(h=$hwnd,p=$tpid)" paired "real ancestry: hwnd & pid both zero or both non-zero"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
