#!/usr/bin/env bash
# test-image-dir-override.sh — ALERT_IMAGE_DIR 設定 / 空 / 不存在 的優先序行為。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_DISABLE_AUTOGEN=1   # 此測試專注於目錄優先序，不依賴生成器
unset ALERT_LEGACY_IMAGE; export ALERT_LEGACY_IMAGE="$SBX/no-legacy.png"
unset ALERT_DEFAULT_IMAGE

# Case 1：populated dir → 用裡面的圖
export ALERT_IMAGE_DIR="$SBX/imgs1"; mkdir -p "$ALERT_IMAGE_DIR"
: > "$ALERT_IMAGE_DIR/user.png"
ok "$(basename "$(pc_assign_image 11)")" "user.png" "case1: populated dir wins"

# Case 2：empty dir + disable autogen → 空字串
rm -f "$ALERT_STATE_DIR/assignments.tsv"   # 重置佔座
export ALERT_IMAGE_DIR="$SBX/imgs2"; mkdir -p "$ALERT_IMAGE_DIR"
ok "$(pc_assign_image 22)" "" "case2: empty + disable_autogen → empty"

# Case 3：empty dir, autogen ON → 應 fallback 到 auto-images（依平台）
rm -f "$ALERT_STATE_DIR/assignments.tsv"
unset ALERT_DISABLE_AUTOGEN
CAN_GEN=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) command -v powershell.exe >/dev/null 2>&1 && CAN_GEN=1 || command -v powershell >/dev/null 2>&1 && CAN_GEN=1 ;;
  *) command -v python3 >/dev/null 2>&1 && python3 -c "import tkinter" 2>/dev/null && CAN_GEN=1 ;;
esac
if [ "$CAN_GEN" = 1 ]; then
  pick="$(pc_assign_image 33)"
  case "$pick" in
    *"/auto-images/"*) ok "yes" "yes" "case3: assigned image lives in auto-images/" ;;
    *) ok "no" "yes" "case3: assigned image lives in auto-images/ (got [$pick])" ;;
  esac
else
  echo "(skip case3 body: no generator runtime)"
fi

# Case 4：ALERT_IMAGE_DIR 不存在 → 等同 empty
rm -f "$ALERT_STATE_DIR/assignments.tsv"
rm -rf "$ALERT_STATE_DIR/auto-images"
export ALERT_DISABLE_AUTOGEN=1
export ALERT_IMAGE_DIR="$SBX/ghost-dir-does-not-exist"
ok "$(pc_assign_image 44)" "" "case4: nonexistent dir + disable_autogen → empty"

# Case 5：使用者素材夾的所有原檔在此測試結束時都沒有被改動
BEFORE="$(find "$SBX/imgs1" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
ok "$BEFORE" "1" "case5: ALERT_IMAGE_DIR not modified by plugin"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
