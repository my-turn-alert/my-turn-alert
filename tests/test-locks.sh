#!/usr/bin/env bash
# test-locks.sh — 孤兒鎖自癒的回歸測試。
#   故障根因（v1.4.0 實測）：持鎖 hook 被 timeout SIGKILL → 鎖目錄永久殘留 →
#   之後每次 pc_with_lock 各多等 2 秒 → hook 總時長超過 hooks.json timeout →
#   pending 沒寫成 → 不彈圖；且被殺時又留下新孤兒鎖（自我惡化螺旋）。
#   本測試鎖三件事：
#     1) 鎖齡超過 ALERT_LOCK_STALE_SECS 的孤兒鎖會被破鎖，臨界區照常執行且快速。
#     2) 新鮮的鎖不會被誤破（等滿 ~2 秒後無鎖執行，鎖仍在）。
#     3) 行程被 TERM 殺掉時,trap 會釋放持有中的鎖（不產生新孤兒）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"; mkdir -p "$ALERT_STATE_DIR"

# ── Case 1: 孤兒鎖(舊 mtime)→ 被破鎖,臨界區照常執行 ─────────────────
mkdir "$ALERT_STATE_DIR/old.lock"
touch -t 200001010000 "$ALERT_STATE_DIR/old.lock"
start="$(date +%s)"
out="$(pc_with_lock old echo ran)"
stale_elapsed=$(( $(date +%s) - start ))
ok "$out" "ran" "stale lock: critical section ran"
[ -d "$ALERT_STATE_DIR/old.lock" ] && ok exists gone "stale lock: released after run" || ok gone gone "stale lock: released after run"

# ── Case 2: 新鮮的鎖不被誤破(等滿後無鎖執行,鎖保留)──────────────────
mkdir "$ALERT_STATE_DIR/fresh.lock"
start="$(date +%s)"
out="$(ALERT_LOCK_STALE_SECS=9999 pc_with_lock fresh echo ran2)"
fresh_elapsed=$(( $(date +%s) - start ))
ok "$out" "ran2" "fresh lock: still executes (lockless fallback)"
[ -d "$ALERT_STATE_DIR/fresh.lock" ] && ok kept kept "fresh lock: NOT broken" || ok broken kept "fresh lock: NOT broken"
rmdir "$ALERT_STATE_DIR/fresh.lock"

# 破鎖必須跳過等待：用「新鮮鎖等滿 ~2 秒」當同機基準做相對比較，
# 不用絕對秒數門檻（Windows fork/exec 在高負載下單次可達 0.3+ 秒，絕對門檻會 flaky）。
[ "$stale_elapsed" -lt "$fresh_elapsed" ] \
  && ok fast fast "stale lock: broken without full wait (stale=${stale_elapsed}s < fresh=${fresh_elapsed}s)" \
  || ok "slow(stale=${stale_elapsed}s,fresh=${fresh_elapsed}s)" fast "stale lock: broken without full wait (stale=${stale_elapsed}s < fresh=${fresh_elapsed}s)"

# ── Case 3: 持鎖中被 TERM 殺 → trap 釋放鎖,無新孤兒 ─────────────────
bash -c '
  . "'"$HERE"'/../scripts/lib/popup-common.sh"
  export ALERT_STATE_DIR="'"$ALERT_STATE_DIR"'"
  pc_with_lock victim sleep 30
' &
BGPID=$!
# 等它真的拿到鎖
i=0
while [ ! -d "$ALERT_STATE_DIR/victim.lock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -d "$ALERT_STATE_DIR/victim.lock" ] && ok acquired acquired "victim acquired lock" || ok missing acquired "victim acquired lock"
kill -TERM "$BGPID" 2>/dev/null
wait "$BGPID" 2>/dev/null
# sleep 是前景子行程,TERM bash 後 trap 需要一點時間跑完
i=0
while [ -d "$ALERT_STATE_DIR/victim.lock" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
[ -d "$ALERT_STATE_DIR/victim.lock" ] && ok orphaned released "TERM'd holder releases lock via trap" || ok released released "TERM'd holder releases lock via trap"

# ── Case 4: 覆寫 ALERT_LOCK_STALE_SECS 生效(1 秒齡即破)──────────────
mkdir "$ALERT_STATE_DIR/tune.lock"
touch -t 200001010000 "$ALERT_STATE_DIR/tune.lock"
out="$(ALERT_LOCK_STALE_SECS=1 pc_with_lock tune echo ran3)"
ok "$out" "ran3" "ALERT_LOCK_STALE_SECS override works"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
