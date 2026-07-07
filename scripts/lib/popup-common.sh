#!/usr/bin/env bash
# popup-common.sh — hook 與 renderer 共用的狀態夾操作（零外部依賴，不用 jq）。
# 由 alert.sh source。所有路徑可用 ALERT_STATE_DIR / ALERT_IMAGE_DIR 覆寫（測試用）。
#
# 安全邊界（v1.3.0）：
#   - 唯一可寫位置：$(pc_state_dir) 內（pending/、assignments.tsv、seq、各 .lock、auto-images/）。
#   - ALERT_IMAGE_DIR 為使用者素材夾，視為唯讀（auto-gen 寫到 state_dir 內的 auto-images）。
#   - pc_atomic_write 拒絕任何不在 state_dir 內、或含 ".." 段的目的路徑。
#   - 所有取自 stdin/JSON/檔案的 key 都必須先過 pc_sanitize_key。

pc_state_dir() {
  local d="${ALERT_STATE_DIR:-$HOME/.claude/alert-need-human}"
  mkdir -p "$d/pending" 2>/dev/null
  printf '%s' "$d"
}

pc_image_dir() {
  printf '%s' "${ALERT_IMAGE_DIR:-$HOME/.claude/alert-images}"
}

pc_auto_image_dir() {
  # auto-gen 永遠寫到 state_dir 內，不污染使用者素材夾。
  printf '%s' "$(pc_state_dir)/auto-images"
}

pc_sanitize_key() {
  # 將任意輸入正規化為「可安全當檔名」的 key：
  #   - 砍掉所有不在 [A-Za-z0-9_.-] 的字元（含 / \ NUL ..）。
  #   - 砍掉開頭的點（避免 .. / .hidden 攻擊）。
  #   - 限長 128 字。
  #   - 空字串回傳空，呼叫端要自行帶 fallback（如 noctx-pid-seq）。
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr -d '\000-\037' | tr -c 'A-Za-z0-9_.-' '_' | sed 's/^\.*//' | cut -c1-128)"
  printf '%s' "$cleaned"
}

pc_safe_grep_pattern() {
  # 對 ERE metas 做反斜線轉義：][\\.*^$+?(){}|/
  printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'
}

pc_path_in_state_dir() {
  # $1=絕對路徑；回 0 表示在 state_dir 之下或相等，且不含 .. 段。
  local p="$1" sd; sd="$(pc_state_dir)"
  case "$p" in
    *"/.."|*"/../"*|*"/..\\"*) return 1 ;;
  esac
  case "$p" in
    "$sd"|"$sd"/*) return 0 ;;
    *) return 1 ;;
  esac
}

pc_to_win_path() {
  # $1=路徑 → 在類 Windows 平台輸出 Windows 形式（C:\...）。
  # 關鍵：不可依賴 cygpath。Claude Code 跑 hook 的 bash，其 PATH 不保證含 cygpath；
  # 一旦缺席而把 MSYS 路徑（/c/Users/...）原樣寫進 pending，PowerShell 的
  # [Image]::FromFile 會開不了 → 被 renderer 的 try/catch 靜默吞掉 → 白屏。
  # 故 cygpath 在就用（最準），不在就用純 sed 轉換做 fallback。
  local p="$1"
  [ -z "$p" ] && return 0
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) : ;;       # 僅在類 Windows 平台轉換
    *) printf '%s' "$p"; return 0 ;; # 其他平台原樣（renderer 用 POSIX 路徑）
  esac
  # 已是 Windows 形式（含碟符冒號或反斜線）→ 原樣返回
  case "$p" in
    [A-Za-z]:*|*\\*) printf '%s' "$p"; return 0 ;;
  esac
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p" 2>/dev/null && return 0
  fi
  _pc_win_fallback "$p"
}

_pc_win_fallback() {
  # cygpath 缺席時的純 bash 轉換：/c/rest → C:\rest（碟符轉大寫，/ 轉 \）。
  local p="$1"
  case "$p" in
    /[A-Za-z]/*)
      local drive rest
      drive="$(printf '%s' "$p" | sed -n 's#^/\([A-Za-z]\)/.*#\1#p' | tr 'a-z' 'A-Z')"
      rest="$(printf '%s' "$p" | sed 's#^/[A-Za-z]/##; s#/#\\#g')"
      printf '%s:\\%s' "$drive" "$rest" ;;
    /*)
      printf '%s' "$p" | sed 's#/#\\#g' ;;
    *) printf '%s' "$p" ;;
  esac
}

pc_resolve_image() {
  # $1=圖片路徑 → 驗證實際存在；不存在或為空則退回 ALERT_DEFAULT_IMAGE。
  # 防禦：含 .. 段的路徑直接丟棄，避免被當作 traversal 跳板。
  local p="$1"
  case "$p" in *"/.."|*"/../"*|*"\\..\\"*|*"\\.."|*"\\..\\"*) p="" ;; esac
  if [ -n "$p" ] && [ -f "$p" ]; then printf '%s' "$p"; return 0; fi
  local def="${ALERT_DEFAULT_IMAGE:-}"
  if [ -n "$def" ] && [ -f "$def" ]; then printf '%s' "$def"; return 0; fi
  printf '%s' ''
}

pc_atomic_write() {
  # $1=dest $2=content；dest 必須是 pc_state_dir 之下且不含 .. 段。
  local dest="$1" content="$2" tmp
  if ! pc_path_in_state_dir "$dest"; then
    return 1
  fi
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || tmp="${dest}.tmp.$$"
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
  local lock; lock="$(pc_state_dir)/${name}.lock"
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
  case "$(uname -s)" in
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

pc_next_seq() {
  _pc_bump_seq() {
    local f s; f="$(pc_state_dir)/seq"
    s="$(cat "$f" 2>/dev/null)"; [ -z "$s" ] && s=0
    s=$((s+1)); printf '%s' "$s" > "$f"
    printf '%s' "$s"
  }
  pc_with_lock seq _pc_bump_seq
}

pc_release_assign() {
  # $1=term_pid 從 assignments.tsv 移除該行（加鎖）。escape regex metas 避免 injection。
  _pc_rel() {
    local f="$(pc_state_dir)/assignments.tsv" pid="$1"
    [ -f "$f" ] || return 0
    local pat
    pat="$(pc_safe_grep_pattern "$pid")"
    grep -v -E "^${pat}	" "$f" > "$f.tmp" 2>/dev/null
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
  local d; d="$(pc_state_dir)"
  local f tpid alive is_win=0 snap=""
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) is_win=1; snap="$(_pc_ps_snapshot)" ;; esac
  for f in "$d"/pending/*.txt; do
    [ -e "$f" ] || continue
    [ -n "$skip" ] && [ "$(basename "$f")" = "${skip}.txt" ] && continue
    tpid="$(pc_read_field "$f" term_pid)"
    [ -z "$tpid" ] && continue
    [ "$tpid" = "0" ] && continue
    if [ "$is_win" = 1 ] && [ -n "$snap" ]; then
      _pc_snap_has_pid "$snap" "$tpid" && alive=0 || alive=1
    else
      pc_is_alive "$tpid" && alive=0 || alive=1
    fi
    if [ "$alive" = 1 ]; then
      rm -f "$f" 2>/dev/null
      # 佔座以 KEY 為鍵（= pending 檔名 base）；同時也試 term_pid 清舊版遺留行。
      pc_release_assign "$(basename "$f" .txt)"
      pc_release_assign "$tpid"
    fi
  done
}

pc_list_images() {
  local dir; dir="$(pc_image_dir)"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
      *.png|*.jpg|*.jpeg|*.gif|*.bmp) printf '%s\n' "$f" ;;
    esac
  done | LC_ALL=C sort -f
}

pc_list_auto_images() {
  local dir; dir="$(pc_auto_image_dir)"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
      *.png|*.jpg|*.jpeg|*.gif|*.bmp) printf '%s\n' "$f" ;;
    esac
  done | LC_ALL=C sort -f
}

_pc_gen_images() {
  # $1=out dir $2=生成張數上限（001..$2）。呼叫底層生成器；stdout/stderr 全吞。
  local dir="$1" n="$2"
  local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case "$(uname -s)" in
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
    local dir; dir="$(pc_auto_image_dir)"
    mkdir -p "$dir" 2>/dev/null
    local count
    count="$(find "$dir" -maxdepth 1 -type f -name '[0-9][0-9][0-9].png' 2>/dev/null | wc -l | tr -d ' ')"
    [ -z "$count" ] && count=0
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
  local dir; dir="$(pc_auto_image_dir)"
  # 使用者素材夾有圖 → 根本不會用到 auto-images，不補
  [ -n "$(pc_list_images)" ] && return 0
  local total
  total="$(find "$dir" -maxdepth 1 -type f -name '[0-9][0-9][0-9].png' 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "$total" ] && total=0
  [ "$total" -ge 100 ] && return 0
  ( _pc_gen_images "$dir" 100 ) </dev/null >/dev/null 2>&1 &
  return 0
}

pc_pending_count() {
  local d; d="$(pc_state_dir)/pending"
  [ -d "$d" ] || { printf '0'; return 0; }
  local n
  n="$(find "$d" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "$n" ] && n=0
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
    d="$(pc_state_dir)/pending"
    [ -n "$new_key" ] && [ -f "$d/${new_key}.txt" ] && return 0
    local count
    count="$(find "$d" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')"
    [ -z "$count" ] && count=0
    [ "$count" -lt "$cap" ] && return 0
    return 1
  }
  pc_with_lock cap _pc_cap_check "$cap" "$new_key"
}

pc_assign_image() {
  # $1=assignment key（alert.sh 的 KEY；必唯一。歷史上曾用 term_pid，但視窗抓取
  # 失敗時多 CLI 的 term_pid 同為 0 會共用一行 → 全部同一張圖）→ echo 圖片路徑。
  # 優先序：
  #   1. 既有 assignments.tsv 佔座（穩定）
  #   2. 使用者素材夾 ALERT_IMAGE_DIR（按檔名循環）
  #   3. 自動生成的 auto-images（state_dir 內；ALERT_DISABLE_AUTOGEN!=1 才用）
  #   4. ALERT_LEGACY_IMAGE 舊單張
  #   5. ALERT_DEFAULT_IMAGE 內建預設
  #   6. 空字串
  local pid="$1"
  _pc_assign() {
    local pid="$1"
    local af; af="$(pc_state_dir)/assignments.tsv"
    if [ -f "$af" ]; then
      local existing
      existing="$(grep -E "^${pid}	" "$af" 2>/dev/null | head -n1 | cut -f2-)"
      if [ -n "$existing" ] && [ -f "$existing" ]; then printf '%s' "$existing"; return 0; fi
    fi
    local imgs; imgs="$(pc_list_images)"
    if [ -z "$imgs" ] && [ "${ALERT_DISABLE_AUTOGEN:-0}" != "1" ]; then
      pc_ensure_numbered_images
      imgs="$(pc_list_auto_images)"
    fi
    if [ -n "$imgs" ]; then
      # 取「目前被佔用次數最少」的第一張（按檔名序）。
      # 不能用「行數 % 總數」的盲循環：座位釋放（CLI 死亡清除）後行數會回退，
      # 新 CLI 的 index 會撞上仍在使用中的圖 → 兩個 CLI 同一張（v1.4.2 實際故障）。
      # 最少使用法保證：CLI 數 ≤ 圖數時人人不同張；超過時均勻循環重複。
      local pick="" best_count=-1 img cnt pat
      while IFS= read -r img; do
        [ -n "$img" ] || continue
        cnt=0
        if [ -f "$af" ]; then
          pat="$(pc_safe_grep_pattern "$img")"
          cnt="$(grep -c -E "	${pat}\$" "$af" 2>/dev/null)" || cnt=0
        fi
        if [ "$best_count" -lt 0 ] || [ "$cnt" -lt "$best_count" ]; then
          best_count="$cnt"; pick="$img"
          [ "$cnt" = "0" ] && break   # 0 次已是最小，提前收工
        fi
      done <<EOF
$imgs
EOF
      printf '%s	%s\n' "$pid" "$pick" >> "$af"
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
