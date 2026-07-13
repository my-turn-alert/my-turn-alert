#!/usr/bin/env bash
# popup-common.sh — hook 與 renderer 共用的狀態夾操作（零外部依賴，不用 jq）。
# 由 alert.sh source。所有路徑可用 ALERT_STATE_DIR / ALERT_IMAGE_DIR 覆寫（測試用）。
#
# 安全邊界（v1.3.0）：
#   - 唯一可寫位置：$(pc_state_dir) 內（pending/、assignments.tsv、seq、各 .lock、auto-images/）。
#   - ALERT_IMAGE_DIR 為使用者素材夾，視為唯讀（auto-gen 寫到 state_dir 內的 auto-images）。
#   - pc_atomic_write 拒絕任何不在 state_dir 內、或含 ".." 段的目的路徑。
#   - 所有取自 stdin/JSON/檔案的 key 都必須先過 pc_sanitize_key。

# --- fork 預算（v1.5.1）---
# MSYS/Windows 的 fork 極貴（多 CLI 高負載時 ~0.3s/次），而「$( ) 指令替換」
# 本身就是一次 fork —— 即使裡面全是 builtin。熱路徑規則：
#   1. 庫內部互相取路徑用 _pc_*_v 變數版（零 fork），printf 版只留給
#      呼叫端相容與測試。
#   2. 平台判定用 $OSTYPE（bash 內建變數，零 fork）；罕見平台才退回 uname。
#   3. 能用 bash 參數展開/case/glob 就不用 tr/sed/cut/basename/find|wc。
case "$OSTYPE" in
  msys*|cygwin*) _PC_UNAME="MINGW64_NT" ;;   # 統一代表值；下游只比對 MINGW*/MSYS*/CYGWIN* 前綴
  darwin*)       _PC_UNAME="Darwin" ;;
  *)             _PC_UNAME="$(uname -s 2>/dev/null)" ;;
esac

_pc_state_dir_v() {
  # 設定 _PC_SD=state dir（零 fork）。mkdir 只在該目錄尚未備妥時付一次。
  _PC_SD="${ALERT_STATE_DIR:-$HOME/.claude/my-turn-alert}"
  if [ "$_PC_SD" != "${_PC_SD_READY:-}" ]; then
    if [ ! -d "$_PC_SD" ]; then
      _pc_migrate_legacy_state
    fi
    [ -d "$_PC_SD/pending" ] || mkdir -p "$_PC_SD/pending" 2>/dev/null
    _PC_SD_READY="$_PC_SD"
  fi
}

_pc_migrate_legacy_state() {
  # v1.6.0 一次性遷移：state 夾由 ~/.claude/alert-need-human 改名為
  # ~/.claude/my-turn-alert（跟上 v1.5.0 的套件改名）。整夾 mv 保留佔座、
  # ack 戳記、auto-images 等，再改寫 assignments.tsv 內指向舊夾的圖片路徑，
  # 讓 user-images 綁定不失效。
  # 安全邊界：預設舊夾只在「ALERT_STATE_DIR 未覆寫」時才視為遷移來源——
  # 測試沙箱自訂 ALERT_STATE_DIR 時絕不可搬動使用者的真實舊夾
  # （沙箱要測遷移須明確設 ALERT_LEGACY_STATE_DIR）。
  local legacy="${ALERT_LEGACY_STATE_DIR:-}"
  if [ -z "$legacy" ] && [ -z "${ALERT_STATE_DIR:-}" ]; then
    legacy="$HOME/.claude/alert-need-human"
  fi
  [ -n "$legacy" ] && [ -d "$legacy" ] || return 0
  # 併發防護：多個 CLI 的 hook 可能同時冷啟動。鎖必須放在 state 夾【外】
  # （target 夾一旦先被 mkdir，mv 會把舊夾巢狀搬進去）；搶不到鎖的等對方
  # 遷移完成後重新檢查，等滿放棄（外層 mkdir -p 兜底，只損失舊綁定）。
  local lock="${_PC_SD%/*}/.migrate-my-turn-alert.lock" i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge 20 ] && return 0
    sleep 0.1
  done
  if [ ! -d "$_PC_SD" ] && [ -d "$legacy" ]; then
    # renderer.pid 不能帶過去：舊 renderer 盯著舊路徑，pending 消失會自我結束；
    # pid 檔若搬過去，新 alert.sh 會誤判 renderer 已在跑而不啟動新的（圖不彈）。
    rm -f "$legacy/renderer.pid" 2>/dev/null
    if mv "$legacy" "$_PC_SD" 2>/dev/null && [ -f "$_PC_SD/assignments.tsv" ]; then
      local out="" line
      while IFS= read -r line || [ -n "$line" ]; do
        out="${out}${line//"$legacy"/"$_PC_SD"}"$'\n'
      done < "$_PC_SD/assignments.tsv"
      printf '%s' "$out" > "$_PC_SD/assignments.tsv"
    fi
  fi
  rmdir "$lock" 2>/dev/null
}

pc_state_dir() {
  _pc_state_dir_v
  printf '%s' "$_PC_SD"
}

pc_image_dir() {
  printf '%s' "${ALERT_IMAGE_DIR:-$HOME/.claude/alert-images}"
}

pc_auto_image_dir() {
  # auto-gen 永遠寫到 state_dir 內，不污染使用者素材夾。
  _pc_state_dir_v
  printf '%s' "$_PC_SD/auto-images"
}

pc_user_image_dir() {
  # 使用者專屬素材夾（v1.5.0）：state_dir/user-images，自動建立方便使用者找到。
  # 與 ALERT_IMAGE_DIR（外部素材夾）並列為「使用者圖」來源；配圖時使用者圖恆優先。
  local d; _pc_state_dir_v; d="$_PC_SD/user-images"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

pc_sanitize_key_v() {
  # 將任意輸入正規化為「可安全當檔名」的 key，結果放 _PC_KEY（零 fork）：
  #   - 不在 [A-Za-z0-9_.-] 的字元（含 / \ 控制字元 ..）一律換成 _（與舊版 tr -c 同義）。
  #   - 砍掉開頭的點（避免 .. / .hidden 攻擊）。
  #   - 限長 128 字。
  #   - 空字串回傳空，呼叫端要自行帶 fallback（如 noctx-pid-seq）。
  # 純 bash 實作：舊版 tr|tr|sed|cut 四段管線 = 4 個 fork，本函式每次 hook
  # 會被叫 2~3 次，MSYS 高負載時光這裡就吃掉秒級預算（v1.5.1 效能修正）。
  # 語意與舊管線一致：控制字元（0x00-0x1F）刪除、其餘非法字元換 _、
  # 去頭點、再截 128 字。
  local raw="$1" cleaned="" ch i
  for (( i=0; i<${#raw}; i++ )); do
    ch="${raw:$i:1}"
    case "$ch" in
      [A-Za-z0-9_.-]) cleaned+="$ch" ;;
      [$'\001'-$'\037']) : ;;         # 控制字元：刪（NUL 本就進不了 bash 變數）
      *) cleaned+="_" ;;
    esac
  done
  while [ "${cleaned#.}" != "$cleaned" ]; do cleaned="${cleaned#.}"; done
  _PC_KEY="${cleaned:0:128}"
}

pc_sanitize_key() {
  # stdout 版（相容舊呼叫端與測試）；熱路徑請用 pc_sanitize_key_v。
  pc_sanitize_key_v "$1"
  printf '%s' "$_PC_KEY"
}

pc_safe_grep_pattern() {
  # 對 ERE metas 做反斜線轉義：][\\.*^$+?(){}|/
  printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'
}

pc_path_in_state_dir() {
  # $1=絕對路徑；回 0 表示在 state_dir 之下或相等，且不含 .. 段。
  local p="$1" sd; _pc_state_dir_v; sd="$_PC_SD"
  case "$p" in
    *"/.."|*"/../"*|*"/..\\"*) return 1 ;;
  esac
  case "$p" in
    "$sd"|"$sd"/*) return 0 ;;
    *) return 1 ;;
  esac
}

pc_to_win_path_v() {
  # $1=路徑 → _PC_WPATH=Windows 形式（C:\...）；非 Windows 平台原樣。
  # 關鍵：不可依賴 cygpath。Claude Code 跑 hook 的 bash，其 PATH 不保證含 cygpath；
  # 一旦缺席而把 MSYS 路徑（/c/Users/...）原樣寫進 pending，PowerShell 的
  # [Image]::FromFile 會開不了 → 被 renderer 的 try/catch 靜默吞掉 → 白屏。
  # 轉換全程純 bash（零 fork；v1.5.1 前這裡是 cygpath 或 2×sed+tr 管線）。
  # MSYS 形式 /c/... 是機械對應 → 純 bash 轉換與 cygpath 結果一致。
  local p="$1"
  _PC_WPATH="$p"
  [ -z "$p" ] && return 0
  case "$_PC_UNAME" in
    MINGW*|MSYS*|CYGWIN*) : ;;   # 僅在類 Windows 平台轉換
    *) return 0 ;;               # 其他平台原樣（renderer 用 POSIX 路徑）
  esac
  # 已是 Windows 形式（含碟符冒號或反斜線）→ 原樣返回
  case "$p" in
    [A-Za-z]:*|*\\*) return 0 ;;
  esac
  case "$p" in
    /[A-Za-z]/*)
      # /c/... 是機械對應 → 純 bash 轉換與 cygpath 結果一致（零 fork）。
      # 這是實際熱路徑：state_dir 預設在 $HOME（/c/Users/...）之下。
      _pc_win_fallback_v "$p" ;;
    *)
      # 非碟符形式（/tmp、/usr/... 等 MSYS 虛擬掛載點）必須交給 cygpath
      # 解析真實對應（例如 /tmp → C:\...\Temp）；缺席才退回機械轉換。
      if command -v cygpath >/dev/null 2>&1; then
        _PC_WPATH="$(cygpath -w "$p" 2>/dev/null)"
        [ -n "$_PC_WPATH" ] && return 0
      fi
      _pc_win_fallback_v "$p" ;;
  esac
}

_pc_win_fallback_v() {
  # 純 bash 的 MSYS→Windows 轉換：/c/rest → C:\rest（碟符轉大寫，/ 轉 \）。
  # 結果放 _PC_WPATH。v1.5.1 前這裡是 2×sed+tr 管線（3 個 fork）。
  local p="$1"
  case "$p" in
    /[A-Za-z]/*)
      local drive rest
      drive="${p:1:1}"; drive="${drive^^}"   # 碟符轉大寫
      rest="${p:3}"; rest="${rest//\//\\}"   # / 轉 \
      _PC_WPATH="${drive}:\\${rest}" ;;
    /*)
      _PC_WPATH="${p//\//\\}" ;;
    *)
      _PC_WPATH="$p" ;;
  esac
}

_pc_win_fallback() {
  # stdout 版（相容測試）；熱路徑請用 _pc_win_fallback_v。
  _pc_win_fallback_v "$1"
  printf '%s' "$_PC_WPATH"
}

pc_to_win_path() {
  # stdout 版（相容舊呼叫端與測試）；熱路徑請用 pc_to_win_path_v。
  pc_to_win_path_v "$1"
  printf '%s' "$_PC_WPATH"
}

pc_resolve_image_v() {
  # $1=圖片路徑 → _PC_IMG=驗證後路徑（零 fork 版）；不存在或為空則退回
  # ALERT_DEFAULT_IMAGE。防禦：含 .. 段的路徑直接丟棄，避免 traversal。
  local p="$1"
  case "$p" in *"/.."|*"/../"*|*"\\..\\"*|*"\\.."|*"\\..\\"*) p="" ;; esac
  if [ -n "$p" ] && [ -f "$p" ]; then _PC_IMG="$p"; return 0; fi
  local def="${ALERT_DEFAULT_IMAGE:-}"
  if [ -n "$def" ] && [ -f "$def" ]; then _PC_IMG="$def"; return 0; fi
  _PC_IMG=""
}

pc_resolve_image() {
  # stdout 版（相容舊呼叫端與測試）；熱路徑請用 pc_resolve_image_v。
  pc_resolve_image_v "$1"
  printf '%s' "$_PC_IMG"
}

_pc_count_glob() {
  # $1=dir $2=glob → _PC_N=第一層符合 glob 的檔案數。純 bash（零 fork）：
  # 舊版 find|wc|tr 三段管線 = 3 個 fork，且熱路徑會呼叫多次（v1.5.1 效能修正）。
  local dir="$1" pat="$2" f n=0
  if [ -d "$dir" ]; then
    for f in "$dir"/$pat; do
      [ -f "$f" ] && n=$((n+1))
    done
  fi
  _PC_N=$n
}

pc_atomic_write() {
  # $1=dest $2=content；dest 必須是 pc_state_dir 之下且不含 .. 段。
  # tmp 名用 PID+RANDOM（零 fork）而非 mktemp（1 fork）：dest 檔名已含 KEY，
  # 只有同 KEY 的 hook 會撞同一 dest，PID 就足以消歧；mv 才是原子性的來源。
  local dest="$1" content="$2" tmp
  if ! pc_path_in_state_dir "$dest"; then
    return 1
  fi
  tmp="${dest}.tmp.$$.$RANDOM"
  printf '%s' "$content" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$dest" 2>/dev/null
}

_PC_HELD_LOCKS=""

_pc_lock_mtime() {
  # $1=path → mtime 的 epoch 秒；GNU stat（Git Bash）→ BSD stat（macOS）依序嘗試。
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

_pc_lock_is_stale() {
  # $1=lock dir。鎖齡超過 ALERT_LOCK_STALE_SECS（預設 30 秒）視為孤兒。
  # 孤兒鎖的成因：持鎖行程被 SIGKILL（trap 來不及跑），例如 hook 超時被殺。
  # 30 秒遠大於所有合法臨界區（cap/assign/seq 皆 <1 秒；autogen 首次生成約數秒），
  # 不會誤破活鎖。
  local lock="$1" mt now
  mt="$(_pc_lock_mtime "$lock")"
  [ -z "$mt" ] && return 1
  now="$(date +%s)"
  [ $(( now - mt )) -gt "${ALERT_LOCK_STALE_SECS:-30}" ]
}

_pc_release_held_locks() {
  # 釋放本行程持有中的所有鎖（trap 用；正常路徑逐一釋放後此處為空）。
  [ -z "${_PC_HELD_LOCKS:-}" ] && return 0
  local oldIFS="$IFS" l
  IFS='
'
  for l in $_PC_HELD_LOCKS; do rmdir "$l" 2>/dev/null; done
  IFS="$oldIFS"
  _PC_HELD_LOCKS=""
}

pc_with_lock() {
  # $1=lockname 其餘=要執行的命令。以 mkdir 為原子鎖；最多等 ~2 秒。
  # 自癒：
  #   - 等待中若發現鎖齡超過 ALERT_LOCK_STALE_SECS → 破鎖重搶（孤兒鎖不再永久堵路）。
  #   - 取得鎖即掛 trap；被 TERM/INT/HUP 殺或正常退出時保證釋放（防止自己變孤兒）。
  #   - 等滿仍搶不到 → 照舊無鎖執行（可用性優先；不動別人的鎖）。
  local name="$1"; shift
  local lock; _pc_state_dir_v; lock="$_PC_SD/${name}.lock"
  local i=0 acquired=0
  while true; do
    if mkdir "$lock" 2>/dev/null; then acquired=1; break; fi
    if _pc_lock_is_stale "$lock"; then
      rmdir "$lock" 2>/dev/null   # 破鎖後下一輪重搶（不直接視為己有，避免與同時破鎖者相撞）
    fi
    i=$((i+1)); [ "$i" -ge 20 ] && break
    sleep 0.1
  done
  if [ "$acquired" = 1 ]; then
    _PC_HELD_LOCKS="${_PC_HELD_LOCKS:+$_PC_HELD_LOCKS
}$lock"
    trap '_pc_release_held_locks' EXIT
    trap '_pc_release_held_locks; exit 143' HUP INT TERM
  fi
  "$@"; local rc=$?
  if [ "$acquired" = 1 ]; then
    rmdir "$lock" 2>/dev/null
    local rest="" l oldIFS="$IFS"
    IFS='
'
    for l in ${_PC_HELD_LOCKS:-}; do
      [ "$l" = "$lock" ] || rest="${rest:+$rest
}$l"
    done
    IFS="$oldIFS"
    _PC_HELD_LOCKS="$rest"
  fi
  return $rc
}

_pc_ps_snapshot() {
  # Windows：一次 `ps -W` 快照（~0.16s；tasklist 每叫一次 ~0.5s）。
  # 輸出含 MSYS PID（$1）與 Windows WINPID（$4）兩欄，兩種 pid 都查得到。
  ps -W 2>/dev/null
}

_pc_snap_has_pid() {
  # $1=快照 $2=pid → pid 出現在 PID 或 WINPID 欄即回 0。
  printf '%s\n' "$1" | awk -v p="$2" 'NR>1 && ($1==p || $4==p){f=1} END{exit !f}'
}

pc_is_alive() {
  # $1=pid；存活回 0。Windows 上同時接受 Windows PID 與 MSYS PID。
  # 走單次 ps -W 快照；ps 整個失效時才退回 tasklist（慢但可靠）。
  local pid="$1"
  [ -z "$pid" ] && return 1
  [ "$pid" = "0" ] && return 1
  case "$_PC_UNAME" in
    MINGW*|MSYS*|CYGWIN*)
      local snap; snap="$(_pc_ps_snapshot)"
      if [ -n "$snap" ]; then
        _pc_snap_has_pid "$snap" "$pid" && return 0 || return 1
      fi
      tasklist //FI "PID eq $pid" //FO CSV //NH 2>/dev/null | grep -q "\"$pid\"" && return 0
      return 1 ;;
    *) kill -0 "$pid" 2>/dev/null && return 0 || return 1 ;;
  esac
}

pc_read_field_v() {
  # $1=file $2=key → _PC_FIELD=該行 = 之後的原文（零 fork 版）。
  local f="$1" k="$2" line
  _PC_FIELD=""
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$k="*) _PC_FIELD="${line#*=}"; return 0 ;;
    esac
  done < "$f"
}

pc_read_field() {
  # $1=file $2=key → echo 該行 = 之後的原文
  local f="$1" k="$2" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$k="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$f"
}

_pc_epoch_v() {
  # 現在 epoch 秒 → _PC_EPOCH。bash ≥4.2 用 printf '%(%s)T'（builtin、零 fork）；
  # 舊 bash（macOS 內建 3.2）不支援該格式 → 退回 date（1 fork，僅冷平台付）。
  _PC_EPOCH=""
  printf -v _PC_EPOCH '%(%s)T' -1 2>/dev/null || :
  case "$_PC_EPOCH" in (''|*[!0-9]*) _PC_EPOCH="$(date +%s)" ;; esac
}

pc_next_seq_v() {
  # 遞增 seq，結果放 _PC_SEQ（零 fork 版；read 是 builtin、不 fork cat）。
  _pc_bump_seq() {
    local f s=""; _pc_state_dir_v; f="$_PC_SD/seq"
    # 注意：seq 檔無結尾換行，read 會回非 0 但 s 已被填值 —— 不可用 `|| s=""`
    # 把讀到的值洗掉；失敗與否交由下面的數字驗證判定。
    if [ -f "$f" ]; then IFS= read -r s < "$f" || :; fi
    case "$s" in (*[!0-9]*|'') s=0 ;; esac
    s=$((s+1)); printf '%s' "$s" > "$f"
    _PC_SEQ="$s"
  }
  _PC_SEQ=0
  pc_with_lock seq _pc_bump_seq
}

pc_next_seq() {
  # stdout 版（相容舊呼叫端與測試）；熱路徑請用 pc_next_seq_v。
  pc_next_seq_v
  printf '%s' "$_PC_SEQ"
}

pc_release_assign() {
  # $1=key 從 assignments.tsv 移除該行（加鎖）。
  # awk 字串相等比對（不經 regex）→ 不需 escape、無 injection 面；
  # 順便省掉舊版 pc_safe_grep_pattern 的 sed fork（v1.5.1 效能修正）。
  _pc_rel() {
    local pid="$1" f; _pc_state_dir_v; f="$_PC_SD/assignments.tsv"
    [ -f "$f" ] || return 0
    awk -F'\t' -v k="$pid" '$1 != k' "$f" > "$f.tmp" 2>/dev/null
    mv -f "$f.tmp" "$f" 2>/dev/null
  }
  pc_with_lock assign _pc_rel "$1"
}

pc_cleanup_stale() {
  # $1（可選）=要跳過的 key：呼叫端剛寫入的 pending 絕不能被自己這輪清掉
  # （其 term_pid 可能因 ps 快照時差、或測試的假 pid 而誤判為死）。
  # Windows 上先取一次 ps 快照，所有 pending 共用（原本每檔各叫一次 tasklist，
  # N 張 pending = N×0.5s，是 hook 超時預算的大宗）。
  local skip="${1:-}"
  local d; _pc_state_dir_v; d="$_PC_SD"
  local f tpid alive is_win=0 snap=""
  case "$_PC_UNAME" in MINGW*|MSYS*|CYGWIN*) is_win=1; snap="$(_pc_ps_snapshot)" ;; esac
  local base
  for f in "$d"/pending/*.txt; do
    [ -e "$f" ] || continue
    base="${f##*/}"   # 純 bash 取檔名，不 fork basename
    [ -n "$skip" ] && [ "$base" = "${skip}.txt" ] && continue
    pc_read_field_v "$f" term_pid; tpid="$_PC_FIELD"
    [ -z "$tpid" ] && continue
    [ "$tpid" = "0" ] && continue
    if [ "$is_win" = 1 ] && [ -n "$snap" ]; then
      _pc_snap_has_pid "$snap" "$tpid" && alive=0 || alive=1
    else
      pc_is_alive "$tpid" && alive=0 || alive=1
    fi
    if [ "$alive" = 1 ]; then
      # 佔座以 session_id 為鍵（v1.5.0）；再試 pending 檔名 base 與 term_pid
      # 清舊版遺留行。session key 須先 sanitize（值來自 pending 檔內容）。
      local sid
      pc_read_field_v "$f" session_id
      pc_sanitize_key_v "$_PC_FIELD"; sid="$_PC_KEY"
      rm -f "$f" 2>/dev/null
      [ -n "$sid" ] && pc_release_assign "$sid"
      pc_release_assign "${base%.txt}"
      pc_release_assign "$tpid"
    fi
  done
}

_pc_is_image_name() {
  # $1=檔名或路徑 → 副檔名是圖檔即回 0。純 case 比對（大小寫不拘），
  # 零子程序 —— 不可用 printf|tr 小寫化：每檔 2 個 fork，100 張 = 200 個
  # 子程序，是 v1.5.1 hook 超時故障的共犯（詳見 _pc_least_used 註解）。
  case "$1" in
    *.[Pp][Nn][Gg]|*.[Jj][Pp][Gg]|*.[Jj][Pp][Ee][Gg]|*.[Gg][Ii][Ff]|*.[Bb][Mm][Pp]) return 0 ;;
    *) return 1 ;;
  esac
}

_pc_list_dir_images() {
  # $1=dir → 列出該夾第一層的圖檔（不排序；呼叫端自行 sort）。
  local dir="$1" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    _pc_is_image_name "$f" && printf '%s\n' "$f"
  done
}

pc_list_images() {
  # 使用者圖來源（v1.5.0 起兩處合併）：
  #   ALERT_IMAGE_DIR（外部素材夾，唯讀）+ state_dir/user-images（專屬資料夾）。
  _pc_state_dir_v
  [ -d "$_PC_SD/user-images" ] || mkdir -p "$_PC_SD/user-images" 2>/dev/null
  { _pc_list_dir_images "${ALERT_IMAGE_DIR:-$HOME/.claude/alert-images}"; _pc_list_dir_images "$_PC_SD/user-images"; } \
    | LC_ALL=C sort -f
}

pc_list_auto_images() {
  _pc_state_dir_v
  _pc_list_dir_images "$_PC_SD/auto-images" | LC_ALL=C sort -f
}

pc_migrate_user_images() {
  # auto-images 內「非 autogen 編號檔（NNN.png）」的圖檔視為使用者誤放 →
  # 搬到 user-images，並改寫 assignments.tsv 中指向舊路徑的行（既有綁定不破）。
  # 非圖檔一律不動。與 assign 共用同一把鎖，避免搬移途中被選圖。
  _pc_migrate() {
    local auto udir af f base dest tmp
    _pc_state_dir_v
    auto="$_PC_SD/auto-images"
    udir="$_PC_SD/user-images"
    [ -d "$udir" ] || mkdir -p "$udir" 2>/dev/null
    af="$_PC_SD/assignments.tsv"
    [ -d "$auto" ] || return 0
    for f in "$auto"/*; do
      [ -f "$f" ] || continue
      base="${f##*/}"   # 不用 basename：每檔一個 fork，100 張純 autogen 檔也要付 100 個子程序
      case "$base" in [0-9][0-9][0-9].png) continue ;; esac
      _pc_is_image_name "$base" || continue
      dest="$udir/$base"
      [ -e "$dest" ] && dest="$udir/user-$base"   # 撞名避讓
      mv -f "$f" "$dest" 2>/dev/null || continue
      if [ -f "$af" ]; then
        tmp="$af.tmp"
        awk -v old="$f" -v new="$dest" -F'\t' 'BEGIN{OFS="\t"} $2==old{$2=new} {print}' \
          "$af" > "$tmp" 2>/dev/null && mv -f "$tmp" "$af" 2>/dev/null
      fi
    done
    return 0
  }
  pc_with_lock assign _pc_migrate
}

_pc_gen_images() {
  # $1=out dir $2=生成張數上限（001..$2）。呼叫底層生成器；stdout/stderr 全吞。
  local dir="$1" n="$2"
  local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case "$_PC_UNAME" in
    MINGW*|MSYS*|CYGWIN*)
      local PS=powershell
      command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
      local GS="$lib_dir/gen-auto-images.ps1"
      local GS_W="$GS" DIR_W="$dir"
      if command -v cygpath >/dev/null 2>&1; then
        GS_W="$(cygpath -w "$GS")"
        DIR_W="$(cygpath -w "$dir")"
      fi
      "$PS" -NoProfile -ExecutionPolicy Bypass -File "$GS_W" -OutDir "$DIR_W" -Count "$n" >/dev/null 2>&1
      ;;
    *)
      if command -v python3 >/dev/null 2>&1; then
        python3 "$lib_dir/gen_auto_images.py" "$dir" "$n" >/dev/null 2>&1
      fi
      ;;
  esac
  return 0
}

pc_ensure_numbered_images() {
  # 若使用者素材夾為空、auto-gen 未停用，且 auto-images 還沒有齊備 100 張，
  # 則於 pc_state_dir/auto-images 內生成 001.png..100.png。
  # 寫入位置永遠在 state_dir 內，遵守安全邊界。
  #
  # 冷啟動預算（v1.4.5）：一次同步生滿 100 張在慢機器上超過 hook 的 30 秒
  # timeout —— hook 被殺 = pending 沒寫 = 首次安裝後永遠不彈（實際故障）。
  # 故拆兩段：
  #   同步：只生前 ALERT_AUTOGEN_SEED 張（預設 8，約 1~2 秒），當下夠分即可；
  #   背景：detach 一支補齊到 100 的行程，不佔 hook 預算。
  #   生成器 per-PID tmp + 原子 rename + 已存在即跳過 → 種子與補齊並行也安全。
  # 測試/舊行為可設 ALERT_AUTOGEN_SEED=100（全同步、無背景段）。
  [ "${ALERT_DISABLE_AUTOGEN:-0}" = "1" ] && return 1
  local seed="${ALERT_AUTOGEN_SEED:-8}"
  case "$seed" in (*[!0-9]*|'') seed=8 ;; esac
  [ "$seed" -lt 1 ] && seed=1
  [ "$seed" -gt 100 ] && seed=100
  _pc_gen_seed() {
    local dir; _pc_state_dir_v; dir="$_PC_SD/auto-images"
    mkdir -p "$dir" 2>/dev/null
    local count
    _pc_count_glob "$dir" '[0-9][0-9][0-9].png'; count=$_PC_N
    [ "$count" -ge "$1" ] && return 0
    _pc_gen_images "$dir" "$1"
  }
  pc_with_lock autogen _pc_gen_seed "$seed"
  if [ "$seed" -ge 100 ]; then
    return 0
  fi
  # 補齊到 100 的背景段【不可】在這裡直接 spawn：本函式常被
  # IMAGE="$(pc_assign_image ...)" 的命令替換呼叫，背景子行程會繼承命令替換的
  # 管線寫端 → 呼叫端等到補齊做完才返回，seed 的省時全數泡湯（實測 24 秒）。
  # 呼叫端（alert.sh）需自行在【頂層】呼叫 pc_topup_auto_images_async。
  return 0
}

pc_topup_auto_images_async() {
  # 背景補齊 auto-images 到 100 張。必須從「非命令替換」的頂層呼叫。
  # stdin/stdout/stderr 全接 /dev/null，避免任何呼叫端等待管線 EOF。
  [ "${ALERT_DISABLE_AUTOGEN:-0}" = "1" ] && return 0
  local dir; _pc_state_dir_v; dir="$_PC_SD/auto-images"
  local total
  _pc_count_glob "$dir" '[0-9][0-9][0-9].png'; total=$_PC_N
  # 還沒種子過 = 目前沒有溢位需求（使用者圖夠分）→ 不補。
  # 一旦 assign 的溢位路徑種了前幾張，這裡才接手補滿到 100。
  [ "$total" -eq 0 ] && return 0
  [ "$total" -ge 100 ] && return 0
  ( _pc_gen_images "$dir" 100 ) </dev/null >/dev/null 2>&1 &
  return 0
}

pc_pending_count() {
  local d; _pc_state_dir_v; d="$_PC_SD/pending"
  [ -d "$d" ] || { printf '0'; return 0; }
  local n
  _pc_count_glob "$d" '*.txt'; n=$_PC_N
  printf '%s' "$n"
}

pc_cap_allows_key() {
  # $1=cap（預設 100） $2=new_key（即將寫入的 key）
  # 先到先服務：回 0 = 放行、回 1 = 拒絕（呼叫端應直接放棄，不寫 pending）。
  #   - new_key 已存在於 pending → 放行（既有 CLI 的更新，不算新增）。
  #   - 否則 pending 數量 >= cap → 拒絕：第 cap+1 個以後的新 CLI 不服務。
  # 舊 pending 關閉後數量降回 cap 以下，之後的新 CLI 自然被放行。
  local cap="${1:-100}" new_key="$2"
  _pc_cap_check() {
    local cap="$1" new_key="$2" d
    _pc_state_dir_v; d="$_PC_SD/pending"
    [ -n "$new_key" ] && [ -f "$d/${new_key}.txt" ] && return 0
    local count
    _pc_count_glob "$d" '*.txt'; count=$_PC_N
    [ "$count" -lt "$cap" ] && return 0
    return 1
  }
  pc_with_lock cap _pc_cap_check "$cap" "$new_key"
}

_pc_least_used() {
  # $1=assignments.tsv 路徑；stdin=候選清單（依優先序）。
  # 取「目前被佔用次數最少」的一張，同次數時取清單較前者 → stdout "cnt<TAB>path"。
  # 不能用「行數 % 總數」的盲循環：座位釋放（CLI 死亡清除）後行數會回退，
  # 新 CLI 的 index 會撞上仍在使用中的圖 → 兩個 CLI 同一張（v1.4.2 實際故障）。
  # 最少使用法保證：CLI 數 ≤ 圖數時人人不同張；超過時均勻循環重複。
  #
  # 效能（v1.5.1 實際故障）：不可對每張候選各 spawn 一次 grep —— 溢位路徑
  # 104 張候選 = 104 個子程序，MSYS 的 fork 昂貴、多 CLI 高負載時每次 >0.5s，
  # 累計衝破 hook 的 60s timeout → pending 沒寫 → 完全不彈圖。
  # 改為單一 awk：先讀 tsv 建「圖片→佔用次數」表，再掃 stdin 候選挑最少者。
  # 全程 1 個子程序；比對是字串相等（非 regex），不需 escape。
  local af="$1" src
  src="$af"; [ -f "$src" ] || src=/dev/null
  awk -F'\t' '
    FILENAME != "-" { if (NF >= 2) cnt[$2]++; next }
    {
      if ($0 == "") next
      c = ($0 in cnt) ? cnt[$0] : 0
      if (best < 0 || c < best) {
        best = c; pick = $0
        if (c == 0) exit   # 0 次已是最小，提前收工（END 仍會執行）
      }
    }
    END { if (pick != "") printf "%d\t%s", best, pick }
  ' best=-1 pick="" "$src" - 2>/dev/null
}

_pc_touch_assign_row() {
  # $1=af $2=key $3=path $4=現有時間戳（可空）。把該 key 的行改寫為
  # 「key<TAB>path<TAB>now」——3 欄行續期、舊 2 欄行升級。呼叫端必須已持 assign 鎖。
  # 節流：戳記齡 < 600 秒不重寫（省 1 個 mv fork；TTL 預設 86400，誤差可忽略）。
  local af="$1" key="$2" path="$3" ts="$4"
  _pc_epoch_v
  if [ -n "$ts" ]; then
    case "$ts" in
      *[!0-9]*) : ;;   # 非數字戳記 → 視同無戳記，重寫升級
      *) [ $(( _PC_EPOCH - ts )) -lt 600 ] && return 0 ;;
    esac
  fi
  local out="" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key	"*) out="${out}${key}	${path}	${_PC_EPOCH}"$'\n' ;;
      '') : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done < "$af"
  printf '%s' "$out" > "$af.tmp.$$" 2>/dev/null && mv -f "$af.tmp.$$" "$af" 2>/dev/null
}

_pc_gc_assignments() {
  # $1=assignments.tsv。回收死綁定（v1.7.0）。呼叫端必須已持 assign 鎖。
  # 一行「活著」的條件（任一即可）：
  #   a. key 出現在活的 pending（sanitized session_id 或檔名 base）——CLI 還掛著圖。
  #   b. 第 3 欄 last_used 距今 ≤ ALERT_ASSIGN_TTL_SECS（預設 86400 = 24h）。
  # 其餘（含無時間戳的舊 2 欄行）= 幽靈 → 整行回收，釋出使用者圖。
  # 沒有這步，綁定只增不減：點掉彈窗後 pending 消失，該 session 的佔座永遠留在
  # tsv，使用者圖全被幽靈佔滿 → 每個新 session 被推去 auto-images 拿新編號
  # （實際故障：重裝後「image 從 004 開始算」）。
  # 只在配新圖的 slow path 呼叫 —— 幽靈行只有在挑新圖時才會灌水佔用計數。
  local af="$1"
  [ -f "$af" ] || return 0
  local d live="" f base
  _pc_state_dir_v; d="$_PC_SD/pending"
  for f in "$d"/*.txt; do
    [ -f "$f" ] || continue
    base="${f##*/}"; base="${base%.txt}"
    live="${live}${base}"$'\n'
    pc_read_field_v "$f" session_id
    if [ -n "$_PC_FIELD" ]; then
      pc_sanitize_key_v "$_PC_FIELD"
      [ -n "$_PC_KEY" ] && live="${live}${_PC_KEY}"$'\n'
    fi
  done
  local ttl="${ALERT_ASSIGN_TTL_SECS:-86400}"
  case "$ttl" in (*[!0-9]*|'') ttl=86400 ;; esac
  _pc_epoch_v
  # 活鍵走 stdin（key 已 sanitize，無 TAB/換行）；字串相等比對，不經 regex。
  printf '%s' "$live" | awk -F'\t' -v now="$_PC_EPOCH" -v ttl="$ttl" '
    FILENAME == "-" { if ($0 != "") live[$0] = 1; next }
    {
      if ($1 in live) { print; next }
      if (NF >= 3 && $3 ~ /^[0-9]+$/ && (now - $3) <= ttl) { print; next }
    }
  ' - "$af" > "$af.tmp" 2>/dev/null && mv -f "$af.tmp" "$af" 2>/dev/null
}

pc_assign_image() {
  # $1=assignment key（alert.sh 給的是 sanitize 後的 session_id；無 session 時退回
  # KEY。必唯一且跨事件穩定 —— 一個 session 永遠同一張圖）→ echo 圖片路徑。
  # 優先序（v1.5.0；v1.7.0 加入佔座回收）：
  #   1. 既有 assignments.tsv 佔座（穩定綁定，命中即續期 last_used；
  #      圖檔消失才重配並清舊行）
  #   2. 使用者圖：ALERT_IMAGE_DIR（外部、唯讀）+ state_dir/user-images（合併按檔名序）
  #      —— 配新圖前先 _pc_gc_assignments 回收死綁定，幽靈行不佔座
  #   3. 使用者圖全數被佔用（溢位）→ auto-images（ALERT_DISABLE_AUTOGEN!=1 才用）
  #   4. ALERT_LEGACY_IMAGE 舊單張
  #   5. ALERT_DEFAULT_IMAGE 內建預設
  #   6. 空字串
  local pid="$1"
  _pc_assign() {
    local pid="$1"
    local af; _pc_state_dir_v; af="$_PC_SD/assignments.tsv"
    if [ -f "$af" ]; then
      # 既有佔座查找：純 bash 逐行比對（tsv 行數 = CLI 數，通常個位數）。
      # 舊版 grep|head|cut 管線 = 3 個 fork，這是每次 hook 必經的快路徑，
      # 高負載時省下的秒數就是 timeout 內外的差別（v1.5.1 效能修正）。
      # 行格式 key<TAB>path[<TAB>last_used]；第 3 欄可缺（舊版 2 欄行）。
      local rest="" existing="" ets="" line
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "$pid	"*) rest="${line#*	}"; break ;;
        esac
      done < "$af"
      if [ -n "$rest" ]; then
        existing="${rest%%	*}"
        ets="${rest#*	}"; [ "$ets" = "$rest" ] && ets=""
        if [ -f "$existing" ]; then
          _pc_touch_assign_row "$af" "$pid" "$existing" "$ets"
          printf '%s' "$existing"; return 0
        fi
        # 佔座的圖檔已消失 → 先清掉此 key 的舊行再重配（一 key 一行，不疊行）。
        # 不可呼叫 pc_release_assign：它會再搶同一把 assign 鎖（已被本函式持有）。
        # 罕見路徑，用單一 awk 重寫檔案（字串相等比對，不經 regex）。
        awk -F'\t' -v k="$pid" '$1 != k' "$af" > "$af.tmp" 2>/dev/null
        mv -f "$af.tmp" "$af" 2>/dev/null
      fi
    fi
    # slow path（要挑新圖）→ 先回收死綁定，否則幽靈行灌水佔用計數。
    _pc_gc_assignments "$af"
    local user_imgs sel best_count=""
    user_imgs="$(pc_list_images)"
    sel=""
    if [ -n "$user_imgs" ]; then
      sel="$(_pc_least_used "$af" <<EOF
$user_imgs
EOF
)"
      best_count="${sel%%	*}"
    fi
    # 溢位判定：沒有使用者圖，或每張使用者圖都已被佔用 ≥1 次 → 動用 auto-images。
    if { [ -z "$sel" ] || [ "$best_count" != "0" ]; } && [ "${ALERT_DISABLE_AUTOGEN:-0}" != "1" ]; then
      pc_ensure_numbered_images
      local auto_imgs; auto_imgs="$(pc_list_auto_images)"
      if [ -n "$auto_imgs" ]; then
        local combined="$user_imgs"
        combined="${combined:+$combined
}$auto_imgs"
        sel="$(_pc_least_used "$af" <<EOF
$combined
EOF
)"
      fi
    fi
    if [ -n "$sel" ]; then
      local pick="${sel#*	}"
      _pc_epoch_v
      printf '%s	%s	%s\n' "$pid" "$pick" "$_PC_EPOCH" >> "$af"
      printf '%s' "$pick"; return 0
    fi
    local legacy="${ALERT_LEGACY_IMAGE:-$HOME/.claude/alert-image.png}"
    if [ -f "$legacy" ]; then printf '%s' "$legacy"; return 0; fi
    local def="${ALERT_DEFAULT_IMAGE:-}"
    if [ -n "$def" ] && [ -f "$def" ]; then printf '%s' "$def"; return 0; fi
    printf '%s' ''
  }
  pc_with_lock assign _pc_assign "$pid"
}
