#!/usr/bin/env bash
# test-assign-perf.sh — 配圖路徑的「程序 spawn 預算」測試。
#
# 背景（v1.5.1 實際故障）：_pc_least_used 對每張候選圖 spawn 一次 sed+grep、
# _pc_list_dir_images / pc_migrate_user_images 對每個檔案 spawn printf|tr（與 basename），
# 溢位路徑（使用者圖全被佔用 → 動用 100 張 auto-images）單次 pc_assign_image
# 會 spawn 200+ 個子程序。MSYS/Windows 的 fork 昂貴（高負載時 >0.5s/次），
# 直接衝破 hook 的 60s timeout → pending 沒寫 → 完全不彈圖。
#
# 測法：把常用外部工具（grep/sed/tr/sort/find/...）換成「記數再轉呼真品」的
# PATH shim，數 pc_assign_image / pc_migrate_user_images 實際 spawn 幾次。
# 用 spawn 次數而非秒數：確定性、不受機器負載影響。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }
ok_le(){ if [ "$1" -le "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want <= [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"
mkdir -p "$ALERT_IMAGE_DIR"

# 4 張使用者圖（外部素材夾）
for i in 1 2 3 4; do : > "$ALERT_IMAGE_DIR/u$i.png"; done

# 預先鋪滿 100 張 auto-images（讓 pc_ensure_numbered_images 走「已齊備」快路徑，
# 不真的呼叫 PowerShell/python 生成器）
AUTO="$(pc_auto_image_dir)"
mkdir -p "$AUTO"
i=1
while [ "$i" -le 100 ]; do
  : > "$AUTO/$(printf '%03d' "$i").png"
  i=$((i+1))
done

# 佔用情境：4 張使用者圖 + 前 50 張 auto 都已被別的 session 綁走 →
# 新 session 必走溢位路徑，掃描 4+100 張候選。
AF="$(pc_state_dir)/assignments.tsv"
{
  for i in 1 2 3 4; do printf 'sess-u%s\t%s/u%s.png\n' "$i" "$ALERT_IMAGE_DIR" "$i"; done
  i=1
  while [ "$i" -le 50 ]; do
    printf 'sess-a%s\t%s/%s.png\n' "$i" "$AUTO" "$(printf '%03d' "$i")"
    i=$((i+1))
  done
} > "$AF"

# --- spawn 計數 shim：記一筆再 exec 真品 ---
SHIM="$SBX/shim"; mkdir -p "$SHIM"
CNT="$SBX/spawncount"
for u in grep sed tr sort find basename cut head awk wc xargs; do
  real="$(command -v "$u" 2>/dev/null)" || continue
  [ -n "$real" ] || continue
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s" >> "%s"\n' "$u" "$CNT"
    printf 'exec "%s" "$@"\n' "$real"
  } > "$SHIM/$u"
  chmod +x "$SHIM/$u"
done

# --- 1) 溢位配圖：正確性 + spawn 預算 ---
: > "$CNT"
OLDPATH="$PATH"
PATH="$SHIM:$PATH"
img="$(pc_assign_image brand-new-session)"
PATH="$OLDPATH"
spawns="$(wc -l < "$CNT" | tr -d ' ')"

ok "$(basename "$img")" "051.png" "overflow pick = first unused auto image"
ok "$(grep -c "^brand-new-session	" "$AF")" "1" "binding row appended"
ok_le "$spawns" 30 "assign overflow spawn budget (was 200+ before fix)"

# --- 2) 既有綁定快路徑：spawn 要更少 ---
: > "$CNT"
PATH="$SHIM:$PATH"
img2="$(pc_assign_image brand-new-session)"
PATH="$OLDPATH"
spawns2="$(wc -l < "$CNT" | tr -d ' ')"

ok "$(basename "$img2")" "051.png" "existing binding stable"
ok_le "$spawns2" 12 "existing-binding fast path spawn budget"

# --- 3) pc_migrate_user_images 對 100 張純 autogen 檔（無事可做）不得逐檔 spawn ---
: > "$CNT"
PATH="$SHIM:$PATH"
pc_migrate_user_images
PATH="$OLDPATH"
spawns3="$(wc -l < "$CNT" | tr -d ' ')"

ok_le "$spawns3" 10 "migrate no-op spawn budget (was 200+ before fix)"

# --- 4) 大小寫混合副檔名仍要被列入（改寫列檔邏輯的回歸保護）---
: > "$ALERT_IMAGE_DIR/MiXeD.PnG"
: > "$ALERT_IMAGE_DIR/upper.JPEG"
got="$(pc_list_images | xargs -n1 basename | tr '\n' ',')"
case "$got" in
  *MiXeD.PnG*) PASS=$((PASS+1));;
  *) FAIL=$((FAIL+1)); echo "FAIL: mixed-case .PnG not listed — got [$got]";;
esac
case "$got" in
  *upper.JPEG*) PASS=$((PASS+1));;
  *) FAIL=$((FAIL+1)); echo "FAIL: upper-case .JPEG not listed — got [$got]";;
esac

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
