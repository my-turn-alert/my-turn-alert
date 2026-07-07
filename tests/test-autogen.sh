#!/usr/bin/env bash
# test-autogen.sh — 空素材夾時自動生成 100 張編號圖，且不寫入使用者素材夾。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"; mkdir -p "$ALERT_STATE_DIR"
export ALERT_IMAGE_DIR="$SBX/imgs"; mkdir -p "$ALERT_IMAGE_DIR"

# 偵測是否能跑生成器（Windows 有 powershell；macOS/Linux 需要 python3）
CAN_GEN=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) command -v powershell.exe >/dev/null 2>&1 && CAN_GEN=1 || command -v powershell >/dev/null 2>&1 && CAN_GEN=1 ;;
  *) command -v python3 >/dev/null 2>&1 && python3 -c "import tkinter" 2>/dev/null && CAN_GEN=1 ;;
esac

# 快照使用者素材夾（事後驗證沒被寫）
USER_IMG_SNAP_BEFORE="$(find "$ALERT_IMAGE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

# SEED=100 → 全同步生成（確定性；背景補齊段不啟動）
export ALERT_AUTOGEN_SEED=100
pc_ensure_numbered_images

USER_IMG_SNAP_AFTER="$(find "$ALERT_IMAGE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
ok "$USER_IMG_SNAP_BEFORE" "$USER_IMG_SNAP_AFTER" "ALERT_IMAGE_DIR is read-only (file count unchanged)"

if [ "$CAN_GEN" = 1 ]; then
  AUTO_DIR="$(pc_auto_image_dir)"
  N="$(find "$AUTO_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.gif' \) 2>/dev/null | wc -l | tr -d ' ')"
  ok "$N" "100" "100 numbered images generated in auto-images/"
  # 第一張存在且非空
  if [ -f "$AUTO_DIR/001.png" ]; then
    sz="$(wc -c < "$AUTO_DIR/001.png" | tr -d ' ')"
    [ "$sz" -gt 0 ] && ok "yes" "yes" "001.png non-empty" || ok "no" "yes" "001.png non-empty"
  elif [ -f "$AUTO_DIR/001.gif" ]; then
    sz="$(wc -c < "$AUTO_DIR/001.gif" | tr -d ' ')"
    [ "$sz" -gt 0 ] && ok "yes" "yes" "001.gif non-empty" || ok "no" "yes" "001.gif non-empty"
  else
    ok "missing" "exists" "001.* exists"
  fi
  # Idempotency：再呼叫一次 count 不變
  pc_ensure_numbered_images
  N2="$(find "$AUTO_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.gif' \) 2>/dev/null | wc -l | tr -d ' ')"
  ok "$N2" "$N" "idempotent (count unchanged on second call)"
else
  echo "(skip autogen body: no powershell/python3+tkinter on this host)"
fi

# 種子模式：同步段只生 ALERT_AUTOGEN_SEED 張、背景補齊到 100（v1.4.5 冷啟動修正）
if [ "$CAN_GEN" = 1 ]; then
  rm -rf "$ALERT_STATE_DIR/auto-images"
  ALERT_AUTOGEN_SEED=3 pc_ensure_numbered_images
  AUTO_DIR="$(pc_auto_image_dir)"
  NS="$(find "$AUTO_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9].png' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$NS" -ge 3 ] && [ "$NS" -lt 100 ]; then SEEDOK="yes"; else SEEDOK="no"; fi
  ok "$SEEDOK" "yes" "seed mode generates only SEED images synchronously (got $NS)"
  # 背景補齊（獨立入口；alert.sh 於頂層呼叫）：最多等 90 秒補滿 100 張
  pc_topup_auto_images_async
  i=0; NBG="$NS"
  while [ "$i" -lt 90 ]; do
    NBG="$(find "$AUTO_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9].png' 2>/dev/null | wc -l | tr -d ' ')"
    [ "$NBG" -ge 100 ] && break
    sleep 1; i=$((i+1))
  done
  ok "$NBG" "100" "background top-up completes to 100"
fi

# Disable flag
rm -rf "$ALERT_STATE_DIR/auto-images"
ALERT_DISABLE_AUTOGEN=1 pc_ensure_numbered_images
[ -d "$ALERT_STATE_DIR/auto-images" ] && DIRX="exists" || DIRX="missing"
ok "$DIRX" "missing" "ALERT_DISABLE_AUTOGEN=1 prevents generation"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
