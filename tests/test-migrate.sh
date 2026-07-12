#!/usr/bin/env bash
# test-migrate.sh — v1.6.0 state 夾改名遷移（alert-need-human → my-turn-alert）。
# 沙箱化：以 ALERT_STATE_DIR 指向新路徑、ALERT_LEGACY_STATE_DIR 指向沙箱內的假舊夾。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

# --- Case 1：舊夾存在、新夾不存在 → 整夾搬過去 + assignments 路徑改寫 ---
SBX="$(mktemp -d)"
LEGACY="$SBX/alert-need-human"
NEW="$SBX/my-turn-alert"
mkdir -p "$LEGACY/pending" "$LEGACY/user-images" "$LEGACY/auto-images"
printf 'fake-png' > "$LEGACY/user-images/mine.png"
printf 'key=123\nterm_pid=123\n' > "$LEGACY/pending/123.txt"
printf '1' > "$LEGACY/acked-123.stamp"
printf '99999' > "$LEGACY/renderer.pid"
TAB="$(printf '\t')"
printf 'sess-a%s%s/user-images/mine.png\nsess-b%s/somewhere/else.png\n' "$TAB" "$LEGACY" "$TAB" > "$LEGACY/assignments.tsv"

(
  export ALERT_STATE_DIR="$NEW"
  export ALERT_LEGACY_STATE_DIR="$LEGACY"
  . "$HERE/../scripts/lib/popup-common.sh"
  pc_state_dir >/dev/null
)

[ -d "$NEW" ] && ok yes yes "new state dir exists" || ok no yes "new state dir exists"
[ -d "$LEGACY" ] && ok exists gone "legacy dir moved away" || ok gone gone "legacy dir moved away"
[ -f "$NEW/pending/123.txt" ] && ok yes yes "pending migrated" || ok no yes "pending migrated"
[ -f "$NEW/acked-123.stamp" ] && ok yes yes "ack stamp migrated" || ok no yes "ack stamp migrated"
[ -f "$NEW/user-images/mine.png" ] && ok yes yes "user image migrated" || ok no yes "user image migrated"
[ -f "$NEW/renderer.pid" ] && ok exists dropped "renderer.pid NOT migrated" || ok dropped dropped "renderer.pid NOT migrated"
grep -q "^sess-a${TAB}${NEW}/user-images/mine.png$" "$NEW/assignments.tsv" && ok yes yes "assignments path rewritten to new dir" || ok no yes "assignments path rewritten to new dir"
grep -q "^sess-b${TAB}/somewhere/else.png$" "$NEW/assignments.tsv" && ok yes yes "non-legacy assignment untouched" || ok no yes "non-legacy assignment untouched"
[ -d "$SBX/.migrate-my-turn-alert.lock" ] && ok held released "migrate lock released" || ok released released "migrate lock released"
rm -rf "$SBX"

# --- Case 2：新夾已存在 → 不搬、舊夾原樣（重複遷移防護）---
SBX="$(mktemp -d)"
LEGACY="$SBX/alert-need-human"
NEW="$SBX/my-turn-alert"
mkdir -p "$LEGACY" "$NEW/pending"
printf 'old' > "$LEGACY/seq"
printf 'new' > "$NEW/seq"
(
  export ALERT_STATE_DIR="$NEW"
  export ALERT_LEGACY_STATE_DIR="$LEGACY"
  . "$HERE/../scripts/lib/popup-common.sh"
  pc_state_dir >/dev/null
)
[ -d "$LEGACY" ] && ok kept kept "legacy kept when new dir already exists" || ok moved kept "legacy kept when new dir already exists"
ok "$(cat "$NEW/seq")" "new" "existing new-dir content untouched"
rm -rf "$SBX"

# --- Case 3：無舊夾 → 正常建新夾,不出錯 ---
SBX="$(mktemp -d)"
NEW="$SBX/my-turn-alert"
(
  export ALERT_STATE_DIR="$NEW"
  export ALERT_LEGACY_STATE_DIR="$SBX/no-such-dir"
  . "$HERE/../scripts/lib/popup-common.sh"
  pc_state_dir >/dev/null
)
[ -d "$NEW/pending" ] && ok yes yes "fresh install creates new dir" || ok no yes "fresh install creates new dir"
rm -rf "$SBX"

# --- Case 4：沙箱自訂 ALERT_STATE_DIR 且未指定 LEGACY → 絕不碰真實舊夾 ---
# （用一個「存在的哨兵舊夾」驗證:未設 ALERT_LEGACY_STATE_DIR 時它必須原樣留下）
SBX="$(mktemp -d)"
SENTINEL="$SBX/alert-need-human"
mkdir -p "$SENTINEL"
NEW="$SBX/my-turn-alert"
(
  export ALERT_STATE_DIR="$NEW"
  unset ALERT_LEGACY_STATE_DIR
  export HOME="$SBX/fake-home"   # 防禦:就算實作誤用 $HOME 也只會找到空位置
  . "$HERE/../scripts/lib/popup-common.sh"
  pc_state_dir >/dev/null
)
[ -d "$SENTINEL" ] && ok kept kept "custom ALERT_STATE_DIR never migrates implicit legacy" || ok moved kept "custom ALERT_STATE_DIR never migrates implicit legacy"
rm -rf "$SBX"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
