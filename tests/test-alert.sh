#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"; mkdir -p "$ALERT_IMAGE_DIR"; : > "$ALERT_IMAGE_DIR/a.png"
export ALERT_FAKE_WINLINE=$'4242\t777'   # 假 hwnd=4242 term_pid=777
export ALERT_NO_RENDERER=1
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"

# 餵一個 Stop 事件的 JSON 給 alert.sh
printf '{"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"

PF="$ALERT_STATE_DIR/pending/777.txt"
[ -f "$PF" ] && ok yes yes "pending file by term_pid created" || ok no yes "pending file by term_pid created"
. "$HERE/../scripts/lib/popup-common.sh"
ok "$(pc_read_field "$PF" hwnd)" "4242" "hwnd recorded"
ok "$(pc_read_field "$PF" term_pid)" "777" "term_pid recorded"
ok "$(pc_read_field "$PF" session_id)" "sess-1" "session_id recorded"
ok "$(basename "$(pc_read_field "$PF" image_path)")" "a.png" "image assigned"
ok "$(pc_read_field "$PF" reason)" "stop" "reason mapped from Stop"

# 同一 term_pid 再來一次 Notification → 覆寫、仍一個檔
printf '{"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"Notification","message":"permission needed"}' | bash "$HERE/../scripts/alert.sh"
n="$(ls "$ALERT_STATE_DIR/pending" | wc -l | tr -d ' ')"
ok "$n" "1" "same term_pid overwrites (no stacking)"
ok "$(pc_read_field "$PF" reason)" "permission" "reason updated to permission"

# 大小寫混合的 Notification message 仍應映射為 permission（reason mapping 會轉小寫）
printf '{"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"Notification","message":"Permission Needed"}' | bash "$HERE/../scripts/alert.sh"
ok "$(pc_read_field "$PF" reason)" "permission" "reason case-insensitive (uppercase msg)"

# 回歸（v1.4.2 實際故障）：兩個視窗抓取失敗（term_pid=0）的 CLI 必須各自拿到
# 不同的 key 與不同的圖——舊版以 term_pid 佔座，同為 0 → 共用一行 → 同一張圖。
: > "$ALERT_IMAGE_DIR/b.png"   # 第二張素材
export ALERT_FAKE_WINLINE=$'0\t0'
printf '{"session_id":"cli-A","cwd":"/tmp/a","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"
printf '{"session_id":"cli-B","cwd":"/tmp/b","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"
imgA="$(basename "$(pc_read_field "$ALERT_STATE_DIR/pending/cli-A.txt" image_path)")"
imgB="$(basename "$(pc_read_field "$ALERT_STATE_DIR/pending/cli-B.txt" image_path)")"
[ -n "$imgA" ] && [ -n "$imgB" ] && [ "$imgA" != "$imgB" ] \
  && ok distinct distinct "two capture-failed CLIs get distinct images ($imgA vs $imgB)" \
  || ok "same($imgA,$imgB)" distinct "two capture-failed CLIs get distinct images ($imgA vs $imgB)"

# 回歸（幽靈重現）：使用者剛關圖（ack 戳記存在且新鮮）→ 尾隨的 idle 事件不得重彈；
# 但新的 Stop（真事件）要清戳記並照常彈。
export ALERT_FAKE_WINLINE=$'0\t0'
printf '{"session_id":"ghost","cwd":"/tmp/g","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"
GPF="$ALERT_STATE_DIR/pending/ghost.txt"
[ -f "$GPF" ] && ok yes yes "ghost: initial stop popped" || ok no yes "ghost: initial stop popped"
rm -f "$GPF"; : > "$ALERT_STATE_DIR/acked-ghost.stamp"   # 模擬 renderer 關圖 + ack
printf '{"session_id":"ghost","cwd":"/tmp/g","hook_event_name":"Notification","message":"idle waiting"}' | bash "$HERE/../scripts/alert.sh"
[ -f "$GPF" ] && ok reappeared suppressed "ghost: trailing idle suppressed by fresh ack" || ok suppressed suppressed "ghost: trailing idle suppressed by fresh ack"
printf '{"session_id":"ghost","cwd":"/tmp/g","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"
[ -f "$GPF" ] && ok yes yes "ghost: new Stop still pops (clears ack)" || ok no yes "ghost: new Stop still pops (clears ack)"
[ -f "$ALERT_STATE_DIR/acked-ghost.stamp" ] && ok kept cleared "ghost: ack stamp cleared by new Stop" || ok cleared cleared "ghost: ack stamp cleared by new Stop"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
