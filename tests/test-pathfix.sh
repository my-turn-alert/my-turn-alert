#!/usr/bin/env bash
# test-pathfix.sh — 白屏根因的回歸測試（Layer 1：寫入端）。
#   白屏成因：寫進 pending 的 image_path 是 PowerShell 開不了的路徑（MSYS /c/...），
#   或指向不存在的檔；renderer 的 Image::FromFile 失敗被靜默吞掉 → 白底彈窗。
# 這支測試鎖兩件事，且【不依賴 cygpath】（hook 環境的 PATH 不保證有它）：
#   1) pc_to_win_path：在類 Windows 平台把 MSYS/絕對路徑轉成 Windows 形式，cygpath 缺席也要對。
#   2) pc_resolve_image：配到的圖不存在時，退回內建 default-alert.png（絕不回傳壞路徑）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/popup-common.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"; mkdir -p "$ALERT_IMAGE_DIR"

IS_WIN=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; esac

# ── Layer 1a: cygpath 缺席時的純 bash 轉換（_pc_win_fallback 是其真實程式碼路徑）──
# 直接測 fallback 函式，不動 PATH（砍 PATH 會連帶讓 MSYS 的 uname 因缺 DLL 無法載入）。
# /c/Users/x/a.png → C:\Users\x\a.png
ok "$(_pc_win_fallback '/c/Users/ts/a.png')" 'C:\Users\ts\a.png' "fallback /c -> C:\ (no cygpath)"
# 含空白的路徑要原樣保留空白
ok "$(_pc_win_fallback '/d/My Pics/x.jpg')" 'D:\My Pics\x.jpg' "fallback keeps spaces (no cygpath)"
# 碟符一律轉大寫
ok "$(_pc_win_fallback '/e/foo/bar.gif')" 'E:\foo\bar.gif' "fallback uppercases drive letter"

# pc_to_win_path 的平台/直通行為（cygpath 在場時走它，不在則走 fallback，結果一致）
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    ok "$(pc_to_win_path '/c/Users/ts/a.png')" 'C:\Users\ts\a.png' "to_win_path converts /c to drive"
    # 已是 Windows 路徑 → 原樣返回（不重複轉換）
    ok "$(pc_to_win_path 'C:\already\win.png')" 'C:\already\win.png' "to_win_path passes through win path"
    ;;
  *)
    # 非 Windows：路徑不變（renderer 用 POSIX 路徑）
    ok "$(pc_to_win_path '/home/u/a.png')" '/home/u/a.png' "to_win_path noop on POSIX"
    ;;
esac

# ── Layer 1b: pc_resolve_image 對不存在的圖要退回 default ─────────────────
: > "$ALERT_IMAGE_DIR/real.png"
export ALERT_DEFAULT_IMAGE="$SBX/default-alert.png"; : > "$ALERT_DEFAULT_IMAGE"

# 存在的圖 → 原樣返回
ok "$(basename "$(pc_resolve_image "$ALERT_IMAGE_DIR/real.png")")" "real.png" "resolve keeps existing image"
# 不存在的圖 → 退回 default
ok "$(basename "$(pc_resolve_image "$SBX/images/GHOST.png")")" "default-alert.png" "resolve falls back to default when missing"
# 空字串 → 退回 default
ok "$(basename "$(pc_resolve_image "")")" "default-alert.png" "resolve falls back to default when empty"
# 連 default 都不存在 → 回傳空（renderer 端再處理，不可回傳壞路徑）
export ALERT_DEFAULT_IMAGE="$SBX/no-such-default.png"
ok "$(pc_resolve_image "$SBX/images/GHOST.png")" "" "resolve returns empty when nothing valid"

# ── Layer 1c: 端到端——alert.sh 寫進 pending 的 image_path 必須存在且為 Windows 形式 ──
export ALERT_FAKE_WINLINE=$'4242\t777'
export ALERT_NO_RENDERER=1
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
export ALERT_DEFAULT_IMAGE="$CLAUDE_PLUGIN_ROOT/assets/default-alert.png"
# 圖夾裡放一張真圖
rm -f "$ALERT_IMAGE_DIR"/*; : > "$ALERT_IMAGE_DIR/pic.png"
printf '{"session_id":"s","cwd":"/tmp","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"
IP="$(. "$HERE/../scripts/lib/popup-common.sh"; pc_read_field "$ALERT_STATE_DIR/pending/777.txt" image_path)"
if [ "$IS_WIN" = 1 ]; then
  # 必須是 Windows 形式（開頭不得是 MSYS 的 /c/...）
  if [ "${IP#/}" != "$IP" ]; then
    ok "msys-leak" "win-path" "alert.sh writes Windows path (not MSYS)"
  else
    ok "win-path" "win-path" "alert.sh writes Windows path (not MSYS)"
  fi
  # 轉回 POSIX 後該檔必須存在
  WB="$(printf '%s' "$IP" | sed -e 's#\\#/#g' -e 's#^\([A-Za-z]\):#/\L\1#')"
  [ -f "$WB" ] && ok exists exists "pending image_path exists on disk" || ok missing exists "pending image_path exists on disk"
else
  [ -f "$IP" ] && ok exists exists "pending image_path exists on disk" || ok missing exists "pending image_path exists on disk"
fi

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
