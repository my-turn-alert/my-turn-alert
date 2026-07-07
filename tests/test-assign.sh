#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"
mkdir -p "$ALERT_IMAGE_DIR"
# 此測試專注於 legacy / default-image 退路；停用 autogen 以免它先攔截空資料夾。
export ALERT_DISABLE_AUTOGEN=1
# 製造三張圖（名稱故意亂序建立，驗證排序）
: > "$ALERT_IMAGE_DIR/b.png"; : > "$ALERT_IMAGE_DIR/a.png"; : > "$ALERT_IMAGE_DIR/c.png"

# 排序
got="$(pc_list_images | xargs -n1 basename | tr '\n' ',')"
ok "$got" "a.png,b.png,c.png," "list_images sorted"

# 佔座：三個 pid 取到 a,b,c
ok "$(basename "$(pc_assign_image 101)")" "a.png" "pid101 -> a"
ok "$(basename "$(pc_assign_image 102)")" "b.png" "pid102 -> b"
ok "$(basename "$(pc_assign_image 103)")" "c.png" "pid103 -> c"
# 穩定：pid101 再叫一次仍是 a
ok "$(basename "$(pc_assign_image 101)")" "a.png" "pid101 stable -> a"
# cycle：第四個 pid 回到 a
ok "$(basename "$(pc_assign_image 104)")" "a.png" "pid104 cycles -> a"

# 退路：清空資料夾、放舊單張
rm -f "$ALERT_IMAGE_DIR"/*.png
LEGACY="$SBX/legacy"; mkdir -p "$LEGACY"; : > "$LEGACY/alert-image.png"
export ALERT_LEGACY_IMAGE="$LEGACY/alert-image.png"
ok "$(basename "$(pc_assign_image 201)")" "alert-image.png" "legacy single fallback"

# 退路：連舊單張也沒有 → 內建預設
export ALERT_LEGACY_IMAGE="$SBX/nonexistent-legacy.png"   # hermetic: sandbox path, never exists
export ALERT_DEFAULT_IMAGE="$SBX/default-alert.png"; : > "$ALERT_DEFAULT_IMAGE"
ok "$(basename "$(pc_assign_image 202)")" "default-alert.png" "builtin default fallback"

# 全無 → 空字串
unset ALERT_DEFAULT_IMAGE
ok "$(pc_assign_image 203)" "" "no image -> empty"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
