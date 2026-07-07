#!/usr/bin/env bash
# alert.sh — 多實例提醒：薄寫入器 + 跨平台分派。
# 由 Stop / StopFailure / Notification hook 呼叫。讀 stdin 事件 JSON，
# 抓本 CLI 終端機視窗，決定配圖，寫 pending 狀態檔，確保 renderer 在跑，立即 exit 0。
#
# 安全邊界（v1.4.0）：
#   - 所有 KEY 都經 pc_sanitize_key 後才用於檔名（防 ../ traversal）。
#   - 寫入只發生在 pc_state_dir 之下（pc_atomic_write 會 realpath-validate）。
#   - 自動生成的編號圖寫到 state_dir/auto-images（NOT 使用者素材夾）。
#   - 同時跳出上限 ALERT_MAX_POPUPS（預設 100）：先到先服務，
#     滿了之後的新 CLI 不服務（不寫 pending、不佔圖）；既有 CLI 更新照常。

# 讀掉並保存 stdin（避免阻塞）。只在 stdin 為 pipe/重導向時讀；
# 若 stdin 接到 TTY（手動執行/除錯），cat 會卡死等 EOF —— 用 [ -t 0 ] 防呆。
if [ -t 0 ]; then
  STDIN_JSON=""
else
  STDIN_JSON="$(cat 2>/dev/null || true)"
fi

# plugin 根目錄
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
. "$SCRIPTS_DIR/lib/popup-common.sh" || exit 0

# 讓退路找得到內建預設圖
export ALERT_DEFAULT_IMAGE="${ALERT_DEFAULT_IMAGE:-$PLUGIN_ROOT/assets/default-alert.png}"

# --- 從 JSON 取欄位（無 jq：抓 "key":"value"，順便砍掉值內的 CR/LF/NUL） ---
json_str() {
  printf '%s' "$STDIN_JSON" \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -n1 \
    | tr -d '\000\r\n'
}

SESSION_ID="$(json_str session_id)"
CWD="$(json_str cwd)"; [ -z "$CWD" ] && CWD="$PWD"
EVENT="$(json_str hook_event_name)"

# 事件 → reason
case "$EVENT" in
  Stop) REASON=stop ;;
  StopFailure) REASON=stop_failure ;;
  Notification)
    MSG="$(json_str message | tr 'A-Z' 'a-z')"
    case "$MSG" in
      *permission*) REASON=permission ;;
      *idle*|*waiting*) REASON=idle ;;
      *elicit*) REASON=elicitation ;;
      *) REASON=idle ;;
    esac ;;
  *) REASON=stop ;;
esac

# --- 抓本 CLI 視窗 hwnd 與 term_pid ---
WINLINE="${ALERT_FAKE_WINLINE:-}"
if [ -z "$WINLINE" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      PS=powershell; command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
      PS_GET="$SCRIPTS_DIR/get-window.ps1"
      command -v cygpath >/dev/null 2>&1 && PS_GET="$(cygpath -w "$PS_GET")"
      # 沿 MSYS /proc 祖先鏈收集多個候選 winpid（hook 的 bash $$ 是 MSYS pid；
      # Win32 ParentProcessId 常指向已結束的 forker → 一定要走 /proc）
      _cands=""
      _cur="$$"
      _i=0
      while [ "$_i" -lt 8 ] && [ -n "$_cur" ] && [ "$_cur" != "0" ] && [ "$_cur" != "1" ]; do
        _wp="$(cat "/proc/$_cur/winpid" 2>/dev/null)"
        [ -n "$_wp" ] && _cands="${_cands:+$_cands,}$_wp"
        _ppid="$(cat "/proc/$_cur/ppid" 2>/dev/null)"
        [ "$_ppid" = "$_cur" ] && break
        _cur="$_ppid"
        _i=$((_i + 1))
      done
      # timeout 保護：PowerShell 冷啟動偶發性極慢（防毒掃描、系統負載）。
      # 抓不到視窗只是降級（hwnd=0 → 關閉邏輯退回 process-name 比對），
      # 但整支 hook 被 timeout 殺掉 = pending 沒寫 = 完全不彈圖。寧可降級不可全滅。
      _TO=""
      command -v timeout >/dev/null 2>&1 && _TO="timeout ${ALERT_WINCAP_TIMEOUT:-6}"
      if [ -n "$_cands" ]; then
        WINLINE="$($_TO "$PS" -NoProfile -ExecutionPolicy Bypass -File "$PS_GET" -Pids "$_cands" 2>/dev/null | tr -d '\r' || true)"
      else
        WINLINE="$($_TO "$PS" -NoProfile -ExecutionPolicy Bypass -File "$PS_GET" -FromPid "$$" 2>/dev/null | tr -d '\r' || true)"
      fi
      [ -z "$WINLINE" ] && WINLINE="0	0"
      ;;
    Darwin) WINLINE=$'0\t0' ;;
    *) WINLINE=$'0\t0' ;;
  esac
fi
HWND="$(printf '%s' "$WINLINE" | cut -f1)"; [ -z "$HWND" ] && HWND=0
TERM_PID="$(printf '%s' "$WINLINE" | cut -f2)"; [ -z "$TERM_PID" ] && TERM_PID=0

# --- 決定主鍵：term_pid → session_id（sanitize 後）→ noctx-pid-seq（保證唯一）---
SESSION_KEY="$(pc_sanitize_key "$SESSION_ID")"
if [ "$TERM_PID" != "0" ]; then
  KEY="$TERM_PID"
elif [ -n "$SESSION_KEY" ]; then
  KEY="$SESSION_KEY"
else
  KEY="noctx-$$-$(pc_next_seq)"
fi
KEY="$(pc_sanitize_key "$KEY")"
[ -z "$KEY" ] && KEY="noctx-$$"   # 過 sanitize 後仍空 → 兜底

# --- 幽靈重現抑制：使用者剛關掉這個 CLI 的圖（點圖/回 CLI）後，Claude Code 常在
#     ~60 秒時對同一個 Stop 再補發一個 idle_prompt。那不是新事件，只是舊事件的回音。
#     renderer 關圖時會寫 acked-<KEY>.stamp；idle 事件若戳記夠新 → 略過不重彈。
#     非 idle 的新事件（stop/permission/...）代表真的有新狀況 → 清戳記、照常彈。 ---
ACK_STAMP="$(pc_state_dir)/acked-${KEY}.stamp"
if [ "$REASON" = "idle" ] && [ -f "$ACK_STAMP" ]; then
  _ack_mt="$(_pc_lock_mtime "$ACK_STAMP")"
  _now="$(date +%s)"
  if [ -n "$_ack_mt" ] && [ $(( _now - _ack_mt )) -le "${ALERT_ACK_SUPPRESS_SECS:-120}" ]; then
    exit 0
  fi
  rm -f "$ACK_STAMP" 2>/dev/null   # 戳記過期 → 視為新的 idle，照常提醒
fi
[ "$REASON" != "idle" ] && rm -f "$ACK_STAMP" 2>/dev/null

# --- 上限閘門：先到先服務。已滿且是新 CLI → 不服務（不寫 pending、不佔圖）。 ---
# 被拒時先清一輪孤兒 pending 再試一次（可能只是死 CLI 佔著位）；仍滿才放棄。
if ! pc_cap_allows_key "${ALERT_MAX_POPUPS:-100}" "$KEY"; then
  pc_cleanup_stale
  pc_cap_allows_key "${ALERT_MAX_POPUPS:-100}" "$KEY" || exit 0
fi

# --- 決定配圖 + 取序號 ---
# 以 KEY（唯一）而非 TERM_PID 佔座：視窗抓取失敗時多個 CLI 的 term_pid 同為 0，
# 用 term_pid 當鍵會讓它們共用同一行 assignment → 全部拿到同一張圖（v1.4.2 實際故障）。
IMAGE="$(pc_assign_image "$KEY")"
SEQ="$(pc_next_seq)"

# 防白屏 Layer 1：先用 POSIX 形式驗證圖檔【實際存在】，壞路徑退回內建 default；
# 再轉成 Windows 形式（不依賴 cygpath，缺席時純 bash fallback）。
IMAGE="$(pc_resolve_image "$IMAGE")"
IMAGE="$(pc_to_win_path "$IMAGE")"

# --- 寫 pending（最優先產出：就算之後任何步驟被 timeout 殺掉，圖已經有得畫）---
STATE_DIR="$(pc_state_dir)"
PENDING="$STATE_DIR/pending/${KEY}.txt"
pc_atomic_write "$PENDING" "key=${KEY}
session_id=${SESSION_ID}
image_path=${IMAGE}
hwnd=${HWND}
term_pid=${TERM_PID}
cwd=${CWD}
reason=${REASON}
seq=${SEQ}"

# --- 背景補齊 auto-images 到 100（僅首次安裝、素材夾空時有事做）。
#     必須在頂層呼叫（不能在上面 IMAGE="$(...)" 的命令替換內），
#     否則命令替換會等背景生成做完才返回，冷啟動直衝 hook timeout。 ---
pc_topup_auto_images_async

# --- 清孤兒（家務，排在產出之後；跳過自己剛寫的 KEY；renderer 每 2 秒也會自癒）---
pc_cleanup_stale "$KEY"

# --- 確保 renderer 在跑 ---
[ "${ALERT_NO_RENDERER:-0}" = "1" ] && exit 0

_ensure_renderer() {
  local pidf="$STATE_DIR/renderer.pid"
  if [ -f "$pidf" ]; then
    local rp; rp="$(cat "$pidf" 2>/dev/null)"
    pc_is_alive "$rp" && return 0
  fi
  case "$(uname -s)" in
    Darwin)
      bash "$SCRIPTS_DIR/show-popup.sh" >/dev/null 2>&1 &
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local PS=powershell; command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
      local PS_R="$SCRIPTS_DIR/show-popup.ps1"
      command -v cygpath >/dev/null 2>&1 && PS_R="$(cygpath -w "$PS_R")"
      "$PS" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PS_R" >/dev/null 2>&1 &
      ;;
  esac
}
pc_with_lock renderer _ensure_renderer

exit 0
