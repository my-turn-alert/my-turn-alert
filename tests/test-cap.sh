#!/usr/bin/env bash
# test-cap.sh — producer-side 先到先服務上限閘門與 regex-injection 防護。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"; mkdir -p "$ALERT_STATE_DIR/pending"
export ALERT_IMAGE_DIR="$SBX/imgs"; mkdir -p "$ALERT_IMAGE_DIR"; : > "$ALERT_IMAGE_DIR/a.png"

# Case 1：滿 100 個 pending，新 key 應被拒（不服務、不淘汰任何人）
i=1
while [ "$i" -le 100 ]; do
  k="k$(printf '%04d' "$i")"
  printf 'key=%s\nseq=%d\nterm_pid=0\n' "$k" "$i" > "$ALERT_STATE_DIR/pending/$k.txt"
  i=$((i+1))
done
ok "$(pc_pending_count)" "100" "seeded 100 pending"
if pc_cap_allows_key 100 "newkey"; then ok "allowed" "denied" "new key at cap should be denied"; else ok "denied" "denied" "new key at cap should be denied"; fi
ok "$(pc_pending_count)" "100" "denial evicts nobody"
[ -f "$ALERT_STATE_DIR/pending/k0001.txt" ] && ok "yes" "yes" "oldest survives (k0001)" || ok "no" "yes" "oldest survives (k0001)"

# Case 2：update 既有 key 應放行
if pc_cap_allows_key 100 "k0050"; then ok "allowed" "allowed" "existing key at cap is allowed"; else ok "denied" "allowed" "existing key at cap is allowed"; fi

# Case 3：釋出一個空位後，新 key 應放行
rm -f "$ALERT_STATE_DIR/pending/k0001.txt"
if pc_cap_allows_key 100 "newkey"; then ok "allowed" "allowed" "slot freed → new key allowed"; else ok "denied" "allowed" "slot freed → new key allowed"; fi

# Case 4：ALERT_MAX_POPUPS=5 覆寫
rm -f "$ALERT_STATE_DIR/pending"/*.txt
i=1
while [ "$i" -le 5 ]; do
  printf 'key=c%d\nseq=%d\nterm_pid=0\n' "$i" "$i" > "$ALERT_STATE_DIR/pending/c$i.txt"
  i=$((i+1))
done
if pc_cap_allows_key 5 "newone"; then ok "allowed" "denied" "cap=5 honored (6th CLI denied)"; else ok "denied" "denied" "cap=5 honored (6th CLI denied)"; fi
ok "$(pc_pending_count)" "5" "cap=5: nothing evicted"

# Case 5：cap 未滿放行
rm -f "$ALERT_STATE_DIR/pending/c5.txt"
if pc_cap_allows_key 5 "newone"; then ok "allowed" "allowed" "below cap → allowed"; else ok "denied" "allowed" "below cap → allowed"; fi

# Case 6：regex-injection 防護
TAB="$(printf '\t')"
printf '1234%s/img/a.png\n2345%s/img/b.png\n3456%s/img/c.png\n' "$TAB" "$TAB" "$TAB" > "$ALERT_STATE_DIR/assignments.tsv"
pc_release_assign '1234|.*'   # 含 regex meta；應被 escape 後不匹配任何行
n="$(wc -l < "$ALERT_STATE_DIR/assignments.tsv" | tr -d ' ')"
ok "$n" "3" "regex injection: malicious pid did not delete anything"
pc_release_assign '1234'      # 真實 pid 應正常刪除
n="$(wc -l < "$ALERT_STATE_DIR/assignments.tsv" | tr -d ' ')"
ok "$n" "2" "literal pid still works"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
