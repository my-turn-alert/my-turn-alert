#!/usr/bin/env bash
# test-assign-gc.sh — 佔座回收（v1.7.0）：assignments.tsv 的死綁定不再永久霸佔使用者圖。
#
# 背景（實際故障）：綁定行只增不減 —— 點掉彈窗後 pending 消失，該 session 的
# 佔座就永遠留在 tsv（cleanup_stale 只清「pending 還在且 term_pid 已死」的行）。
# 長期下來使用者圖全被幽靈綁定佔滿，每個新 session 都被推去 auto-images 拿新編號
# （重裝後「image 從 004 開始算」的根因）。
#
# 規格：
#   - tsv 第 3 欄 = last_used epoch。配圖命中既有綁定 → 續期（舊 2 欄行升級 3 欄）。
#   - 佔座「活著」= pending 檔還在（session_id 或檔名 base 對得上），
#     或 時間戳齡 ≤ ALERT_ASSIGN_TTL_SECS（預設 86400 = 24h）。
#   - 配新圖（slow path）前先 GC：死行整行回收，佔用計數不被幽靈行灌水。
#   - 舊 2 欄行（無時間戳）視為已過期 —— 但既有綁定的 fast path 仍尊重它
#     （session 回來就續用同一張並升級 3 欄）；別的 session 配新圖時它不佔座。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/ext-images"   # 不建立：user 圖只來自 user-images
unset ALERT_LEGACY_IMAGE; export ALERT_LEGACY_IMAGE="$SBX/no-legacy.png"
unset ALERT_DEFAULT_IMAGE

# 佈景：user 2 張、auto 3 張（預建編號檔 + SEED=3 → hermetic，不真跑生成器）
U="$(pc_user_image_dir)"
: > "$U/u1.png"; : > "$U/u2.png"
AUTO="$(pc_auto_image_dir)"; mkdir -p "$AUTO"
: > "$AUTO/001.png"; : > "$AUTO/002.png"; : > "$AUTO/003.png"
export ALERT_AUTOGEN_SEED=3

AF="$(pc_state_dir)/assignments.tsv"
TAB="$(printf '\t')"
NOW="$(date +%s)"

# --- Case 1：過期的 3 欄幽靈行佔滿 user 圖 → 新 session 仍拿 user 圖，幽靈行被回收 ---
printf 'sess-dead1\t%s/u1.png\t%s\nsess-dead2\t%s/u2.png\t%s\n' \
  "$U" "$((NOW - 90000))" "$U" "$((NOW - 90000))" > "$AF"
ok "$(basename "$(pc_assign_image s-new)")" "u1.png" "case1: expired ghosts reclaimed -> new session gets user image"
grep -q "^sess-dead1${TAB}" "$AF" && ok kept gone "case1: ghost row sess-dead1 removed" || ok gone gone "case1: ghost row sess-dead1 removed"
grep -q "^sess-dead2${TAB}" "$AF" && ok kept gone "case1: ghost row sess-dead2 removed" || ok gone gone "case1: ghost row sess-dead2 removed"
# 新行必須帶數字時間戳（3 欄）
ts_new="$(awk -F'\t' '$1=="s-new"{print $3}' "$AF")"
case "$ts_new" in (''|*[!0-9]*) ok "bad[$ts_new]" "numeric" "case1: new row has numeric epoch col3" ;; (*) ok numeric numeric "case1: new row has numeric epoch col3" ;; esac

# --- Case 2：新鮮的 3 欄行照常佔座 → 溢位行為不變（回歸保護）---
printf 'sess-live1\t%s/u1.png\t%s\nsess-live2\t%s/u2.png\t%s\n' \
  "$U" "$NOW" "$U" "$NOW" > "$AF"
ok "$(basename "$(pc_assign_image s-ovf)")" "001.png" "case2: fresh rows still occupy -> overflow to auto"

# --- Case 3：過期但 pending 還在（session_id 對得上）→ 仍算佔座、不被回收 ---
rm -f "$ALERT_STATE_DIR"/pending/*.txt 2>/dev/null
printf 'sess-pend\t%s/u1.png\t%s\n' "$U" "$((NOW - 90000))" > "$AF"
printf 'key=777\nsession_id=sess-pend\nterm_pid=0\n' > "$ALERT_STATE_DIR/pending/777.txt"
ok "$(basename "$(pc_assign_image s-p)")" "u2.png" "case3: expired-but-pending row still occupies u1"
grep -q "^sess-pend${TAB}" "$AF" && ok kept kept "case3: pending-live row survives GC" || ok gone kept "case3: pending-live row survives GC"

# --- Case 3b：pending 檔名 base 直接等於 tsv key（無 session_id 的舊式綁定）也算活 ---
rm -f "$ALERT_STATE_DIR"/pending/*.txt "$AF"
printf 'k-base\t%s/u1.png\t%s\n' "$U" "$((NOW - 90000))" > "$AF"
printf 'key=k-base\nterm_pid=0\n' > "$ALERT_STATE_DIR/pending/k-base.txt"
ok "$(basename "$(pc_assign_image s-b)")" "u2.png" "case3b: pending filename base keeps row alive"
grep -q "^k-base${TAB}" "$AF" && ok kept kept "case3b: base-keyed row survives GC" || ok gone kept "case3b: base-keyed row survives GC"

# --- Case 4：舊 2 欄行：既有綁定 fast path 仍尊重 + 升級成 3 欄（續期）---
rm -f "$ALERT_STATE_DIR"/pending/*.txt "$AF"
printf 'sess-old\t%s/u2.png\n' "$U" > "$AF"
ok "$(basename "$(pc_assign_image sess-old)")" "u2.png" "case4: legacy 2-col binding honored"
ts_old="$(awk -F'\t' '$1=="sess-old"{print $3}' "$AF")"
case "$ts_old" in (''|*[!0-9]*) ok "bad[$ts_old]" "numeric" "case4: legacy row upgraded to 3-col" ;; (*) ok numeric numeric "case4: legacy row upgraded to 3-col" ;; esac

# --- Case 5：舊 2 欄行、session 已死（無 pending）→ 不佔座，配新圖時被回收 ---
rm -f "$ALERT_STATE_DIR"/pending/*.txt "$AF"
printf 'sess-ghost\t%s/u1.png\n' "$U" > "$AF"
ok "$(basename "$(pc_assign_image s-x)")" "u1.png" "case5: legacy ghost does not occupy"
grep -q "^sess-ghost${TAB}" "$AF" && ok kept gone "case5: legacy ghost row reclaimed" || ok gone gone "case5: legacy ghost row reclaimed"

# --- Case 6：ALERT_ASSIGN_TTL_SECS 覆寫 ---
rm -f "$AF"
printf 'sess-100\t%s/u1.png\t%s\nsess-10\t%s/u2.png\t%s\n' \
  "$U" "$((NOW - 100))" "$U" "$((NOW - 10))" > "$AF"
pick_ttl="$(ALERT_ASSIGN_TTL_SECS=50 pc_assign_image s-t)"
ok "$(basename "$pick_ttl")" "u1.png" "case6: TTL override — 100s-old row expired at ttl=50"
grep -q "^sess-100${TAB}" "$AF" && ok kept gone "case6: over-ttl row reclaimed" || ok gone gone "case6: over-ttl row reclaimed"
grep -q "^sess-10${TAB}" "$AF" && ok kept kept "case6: under-ttl row kept" || ok gone kept "case6: under-ttl row kept"

# --- Case 7：TTL 內綁定穩定：別人觸發 GC 不影響新鮮綁定，session 回來仍同一張 ---
rm -f "$AF"
printf 'sess-keep\t%s/u1.png\t%s\n' "$U" "$((NOW - 3000))" > "$AF"
pc_assign_image s-y >/dev/null   # 觸發一次 GC（配新圖 slow path）
ok "$(basename "$(pc_assign_image sess-keep)")" "u1.png" "case7: fresh binding survives others' GC, stays stable"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
