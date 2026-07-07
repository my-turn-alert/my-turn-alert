#!/usr/bin/env bash
# 在 Git Bash 執行。以臨時目錄沙箱化，不碰真實 ~/.claude。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"

PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"

# state dir 建立
d="$(pc_state_dir)"
ok "$(basename "$d")" "state" "pc_state_dir basename"
[ -d "$d/pending" ] && ok yes yes "pending subdir created" || ok no yes "pending subdir created"

# 原子寫 + 讀欄位
pc_atomic_write "$d/x.txt" $'a=1\nimage_path=/p/q r.png\nb=2'
ok "$(pc_read_field "$d/x.txt" image_path)" "/p/q r.png" "read_field with spaces"
ok "$(pc_read_field "$d/x.txt" b)" "2" "read_field b"

# seq 遞增
s1="$(pc_next_seq)"; s2="$(pc_next_seq)"
ok "$((s2 - s1))" "1" "seq increments by 1"

# 存活判定：自己一定活著、PID 99999999 視為死
pc_is_alive $$ && ok alive alive "self alive" || ok dead alive "self alive"
pc_is_alive 99999999 && ok alive dead "huge pid dead" || ok dead dead "huge pid dead"

# release_assign 必須以「真實 TAB」比對：若實作誤用字面 \t，下面的行不會被刪 → 斷言失敗。
# 同時驗證 ^ 錨定：12345 不可因 1234 被誤刪（前綴子字串）。
TAB="$(printf '\t')"
printf '1234%s/img/a.png\n12345%s/img/b.png\n' "$TAB" "$TAB" > "$d/assignments.tsv"
pc_release_assign 1234
grep -q "^1234${TAB}" "$d/assignments.tsv" 2>/dev/null && ok kept removed "release_assign drops real-TAB line" || ok removed removed "release_assign drops real-TAB line"
grep -q "^12345${TAB}" "$d/assignments.tsv" 2>/dev/null && ok kept kept "release_assign keeps non-matching (^ anchored)" || ok removed kept "release_assign keeps non-matching (^ anchored)"

# 清理 stale：寫一個 term_pid 已死的 pending，應被清掉
printf 'key=99999999\nterm_pid=99999999\n' > "$d/pending/99999999.txt"
printf '99999999\t/img/a.png\n' > "$d/assignments.tsv"
pc_cleanup_stale
[ -f "$d/pending/99999999.txt" ] && ok exists gone "stale pending removed" || ok gone gone "stale pending removed"
grep -q 99999999 "$d/assignments.tsv" 2>/dev/null && ok kept removed "stale assign removed" || ok removed removed "stale assign removed"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
