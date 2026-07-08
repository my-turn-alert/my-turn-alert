#!/usr/bin/env bash
# test-user-priority.sh — 使用者圖片優先、auto-images 只補溢位（v1.5.0）。
#   - state_dir/user-images 為使用者專屬資料夾（自動建立、易於找到）。
#   - 配圖順位：user 圖（ALERT_IMAGE_DIR + user-images）全部佔用後，才用 auto-images。
#   - 使用者誤丟進 auto-images 的非編號檔會被遷移到 user-images。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/ext-images"   # 外部使用者夾（先不建立）
unset ALERT_LEGACY_IMAGE; export ALERT_LEGACY_IMAGE="$SBX/no-legacy.png"
unset ALERT_DEFAULT_IMAGE

# Case 1：user-images 專屬資料夾位於 state_dir 下且自動建立
U="$(pc_user_image_dir)"
ok "$(basename "$U")" "user-images" "user image dir named user-images"
case "$U" in "$(pc_state_dir)"/*) ok yes yes "user-images inside state_dir" ;; *) ok no yes "user-images inside state_dir" ;; esac
[ -d "$U" ] && ok yes yes "user-images auto-created" || ok no yes "user-images auto-created"

# 佈景：user 2 張、auto 3 張（預建編號檔 + SEED=3 → ensure 視為已齊，不啟動生成器，hermetic）
: > "$U/u1.png"; : > "$U/u2.png"
AUTO="$(pc_auto_image_dir)"; mkdir -p "$AUTO"
: > "$AUTO/001.png"; : > "$AUTO/002.png"; : > "$AUTO/003.png"
export ALERT_AUTOGEN_SEED=3

# Case 2：前 2 個 session 依序拿 user 圖
ok "$(basename "$(pc_assign_image s1)")" "u1.png" "session1 -> user u1"
ok "$(basename "$(pc_assign_image s2)")" "u2.png" "session2 -> user u2"

# Case 3：user 圖用完 → 溢位改用 auto-images
ok "$(basename "$(pc_assign_image s3)")" "001.png" "session3 overflow -> auto 001"
ok "$(basename "$(pc_assign_image s4)")" "002.png" "session4 overflow -> auto 002"

# Case 4：既有佔座穩定
ok "$(basename "$(pc_assign_image s1)")" "u1.png" "session1 stable -> u1"

# Case 5：ALERT_IMAGE_DIR 也是 user 圖來源，優先於 auto（即使 auto 還有 0 次的 003）
mkdir -p "$ALERT_IMAGE_DIR"; : > "$ALERT_IMAGE_DIR/ext.png"
ok "$(basename "$(pc_assign_image s5)")" "ext.png" "external ALERT_IMAGE_DIR beats remaining autos"

# Case 6：全部用過一輪後，循環仍以 user 圖優先（最少使用、user 排前）
ok "$(basename "$(pc_assign_image s6)")" "003.png" "session6 -> last auto 003"
ok "$(basename "$(pc_assign_image s7)")" "ext.png" "session7 cycles back to user images first"

# Case 7：遷移 — auto-images 內「非 NNN.png 編號檔」視為使用者誤放 → 移到 user-images
: > "$AUTO/mycat.jpg"; : > "$AUTO/0001.jpg"; : > "$AUTO/notes.txt"
TAB="$(printf '\t')"
printf 'sMig%s%s/mycat.jpg\n' "$TAB" "$AUTO" >> "$ALERT_STATE_DIR/assignments.tsv"   # 既有綁定指向舊路徑
pc_migrate_user_images
[ -f "$U/mycat.jpg" ]  && ok yes yes "misplaced mycat.jpg migrated to user-images"  || ok no yes "misplaced mycat.jpg migrated to user-images"
[ -f "$U/0001.jpg" ]   && ok yes yes "misplaced 0001.jpg migrated to user-images"   || ok no yes "misplaced 0001.jpg migrated to user-images"
[ -f "$AUTO/mycat.jpg" ] && ok kept gone "migrated file removed from auto-images" || ok gone gone "migrated file removed from auto-images"
[ -f "$AUTO/001.png" ]   && ok yes yes "numbered autogen 001.png stays"           || ok no yes "numbered autogen 001.png stays"
[ -f "$AUTO/notes.txt" ] && ok yes yes "non-image file left alone"                || ok no yes "non-image file left alone"
# 7b：assignments.tsv 內指向被遷移檔的行要改寫成新路徑（既有 session 綁定不破）
ok "$(basename "$(pc_assign_image sMig)")" "mycat.jpg" "existing binding survives migration (tsv rewritten)"
grep -qF "$AUTO/mycat.jpg" "$ALERT_STATE_DIR/assignments.tsv" && ok stale clean "no stale auto path left in tsv" || ok clean clean "no stale auto path left in tsv"

# Case 8：遷移後新 session 應優先拿到剛遷移的 user 圖（0001.jpg 檔名序在最前）
ok "$(basename "$(pc_assign_image s8)")" "0001.jpg" "migrated user image assigned before autos"

# Case 9：既有佔座的圖檔消失 → 重新配圖時不得留下重複行（一 key 一行）
: > "$U/gone.png"
printf 's9%s%s/gone.png\n' "$TAB" "$U" >> "$ALERT_STATE_DIR/assignments.tsv"
rm -f "$U/gone.png"
pc_assign_image s9 >/dev/null
n9="$(grep -c "^s9${TAB}" "$ALERT_STATE_DIR/assignments.tsv")"
ok "$n9" "1" "reassign after image loss keeps exactly one row per key"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
