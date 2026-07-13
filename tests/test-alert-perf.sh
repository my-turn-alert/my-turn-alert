#!/usr/bin/env bash
# test-alert-perf.sh — 整條 alert.sh hook 的「外部程序 spawn 預算」端對端測試。
#
# 背景（v1.5.1 實際故障）：多 CLI 高負載下 MSYS 的 fork 成本飆到 ~0.3s/次，
# hook 一次跑 200+ 個外部程序（grep/sed/tr/cut/cat/mktemp/...）→ 總時長衝破
# 60s timeout → pending 沒寫 → 完全不彈圖。單點優化配圖掃描不夠，
# 整條熱路徑的 spawn 總量必須有預算上限，否則之後任何人加一個
# 「每張圖跑一次的小 grep」都會讓故障悄悄回歸。
#
# 測法：PATH shim 對所有常用外部工具記數再轉呼真品，跑一次完整 alert.sh
# （假視窗行、停用 renderer、auto-images 已齊備），斷言總 spawn 數 ≤ 預算。
# 用次數不用秒數：確定性、不受機器負載影響。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }
ok_le(){ if [ "$1" -le "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want <= [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"; mkdir -p "$ALERT_IMAGE_DIR"
export ALERT_FAKE_WINLINE=$'4242\t777'
export ALERT_NO_RENDERER=1
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"

. "$HERE/../scripts/lib/popup-common.sh"

# 實機故障情境：4 張使用者圖全被舊 session 佔用 + 100 張 auto-images 齊備
for i in 1 2 3 4; do : > "$ALERT_IMAGE_DIR/u$i.png"; done
AUTO="$(pc_auto_image_dir)"; mkdir -p "$AUTO"
i=1; while [ "$i" -le 100 ]; do : > "$AUTO/$(printf '%03d' "$i").png"; i=$((i+1)); done
# 佔用行帶新鮮 last_used（v1.7.0）：無戳記的舊 2 欄行會被佔座回收清掉，溢位不成立。
AF="$(pc_state_dir)/assignments.tsv"
NOW="$(date +%s)"
for i in 1 2 3 4; do printf 'old-sess-%s\t%s/u%s.png\t%s\n' "$i" "$ALERT_IMAGE_DIR" "$i" "$NOW"; done > "$AF"

# --- spawn 計數 shim ---
SHIM="$SBX/shim"; mkdir -p "$SHIM"
CNT="$SBX/spawncount"
TOOLS="grep sed tr sort find basename dirname cut head tail awk wc xargs cat mktemp stat uname date ps mv rm touch cp timeout cygpath tasklist"
for u in $TOOLS; do
  real="$(command -v "$u" 2>/dev/null)" || continue
  [ -n "$real" ] || continue
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s" >> "%s"\n' "$u" "$CNT"
    printf 'exec "%s" "$@"\n' "$real"
  } > "$SHIM/$u"
  chmod +x "$SHIM/$u"
done

# --- 1) 新 session（溢位掃描路徑）：功能正確 + spawn 預算 ---
: > "$CNT"
OLDPATH="$PATH"
PATH="$SHIM:$PATH"
printf '{"session_id":"perf-e2e-new","cwd":"/tmp/proj","hook_event_name":"Stop"}' \
  | bash "$HERE/../scripts/alert.sh"
rc=$?
PATH="$OLDPATH"
spawns="$(wc -l < "$CNT" | tr -d ' ')"

ok "$rc" "0" "alert.sh exits 0"
PF="$ALERT_STATE_DIR/pending/777.txt"
[ -f "$PF" ] && ok yes yes "pending written" || ok no yes "pending written"
ok "$(pc_read_field "$PF" session_id)" "perf-e2e-new" "session_id recorded"
img="$(pc_read_field "$PF" image_path)"
case "$img" in *001.png) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: overflow assigns first unused auto — got [$img]";; esac
ok_le "$spawns" 40 "e2e spawn budget, new session (pre-fix was 200+)"
echo "  (info) new-session spawns=$spawns"

# --- 2) 既有綁定（快路徑）：預算要更低 ---
: > "$CNT"
PATH="$SHIM:$PATH"
printf '{"session_id":"perf-e2e-new","cwd":"/tmp/proj","hook_event_name":"Stop"}' \
  | bash "$HERE/../scripts/alert.sh"
PATH="$OLDPATH"
spawns2="$(wc -l < "$CNT" | tr -d ' ')"
ok_le "$spawns2" 35 "e2e spawn budget, existing binding"
echo "  (info) existing-binding spawns=$spawns2"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
