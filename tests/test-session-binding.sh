#!/usr/bin/env bash
# test-session-binding.sh — 一個 Claude Code session 永遠綁同一張圖（v1.5.0）。
#   配圖鍵 = session_id（sanitize 後），不是 term_pid、不是完成順序。
#   pending 檔名（視窗對應）照舊走 term_pid → session → noctx，但 image_path 必須穩定。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"; mkdir -p "$ALERT_IMAGE_DIR"
: > "$ALERT_IMAGE_DIR/a.png"; : > "$ALERT_IMAGE_DIR/b.png"; : > "$ALERT_IMAGE_DIR/c.png"
export ALERT_NO_RENDERER=1
export ALERT_DISABLE_AUTOGEN=1
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"

fire(){ # $1=session $2=winline $3=event
  ALERT_FAKE_WINLINE="$2" printf '{"session_id":"%s","cwd":"/tmp/x","hook_event_name":"%s"}' "$1" "$3" \
    | ALERT_FAKE_WINLINE="$2" bash "$HERE/../scripts/alert.sh"
}
img_of(){ basename "$(pc_read_field "$ALERT_STATE_DIR/pending/$1.txt" image_path)"; }

# Case 1：同一 session、term_pid 改變（新視窗/抓取差異）→ 圖不變
fire sess-A $'0\t111' Stop
A1="$(img_of 111)"
rm -f "$ALERT_STATE_DIR/pending/111.txt"
fire sess-A $'0\t222' Stop
A2="$(img_of 222)"
ok "$A2" "$A1" "same session, different term_pid -> same image"

# Case 2：同一 session、term_pid 抓取失敗（0）→ 圖仍不變
rm -f "$ALERT_STATE_DIR/pending/222.txt"
fire sess-A $'0\t0' Stop
A3="$(img_of sess-A)"
ok "$A3" "$A1" "same session, capture failed -> same image"

# Case 3：不同 session 拿不同圖（不受完成順序影響：後發先至也各自穩定）
fire sess-B $'0\t333' Stop
B1="$(img_of 333)"
[ -n "$B1" ] && [ "$B1" != "$A1" ] && ok distinct distinct "different sessions -> distinct images" \
  || ok "same($A1,$B1)" distinct "different sessions -> distinct images"

# Case 4：sess-B 再以另一 term_pid 回來，仍是 B 自己的圖（不是按順序輪下一張）
rm -f "$ALERT_STATE_DIR/pending/333.txt"
fire sess-B $'0\t444' Notification
B2="$(img_of 444)"
ok "$B2" "$B1" "session B stable across events/order"

# Case 5：assignments.tsv 以 session key 佔座，term_pid 換了不新增行（不吃掉圖池）
TAB="$(printf '\t')"
n_rows="$(grep -c "^sess-A${TAB}" "$ALERT_STATE_DIR/assignments.tsv" 2>/dev/null || echo 0)"
ok "$n_rows" "1" "one assignment row per session (no dup rows across term_pids)"

# Case 6：沒有 session_id 時退回 term_pid 佔座（仍可運作）
fire "" $'0\t555' Stop
N1="$(img_of 555)"
[ -n "$N1" ] && ok yes yes "no session_id still gets an image" || ok no yes "no session_id still gets an image"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
