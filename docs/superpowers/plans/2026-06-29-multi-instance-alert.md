# 多實例提醒彈窗（alert-need-human v1.2.0）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把單張、定時消失的提醒彈窗，改寫成「一直顯示、多實例、每個 CLI 對應一張圖、點圖切回對應 CLI、自適應網格版面」的提醒系統。

**Architecture:** 單一長駐 renderer + 檔案系統狀態資料夾。各 hook 事件呼叫薄寫入器 `alert.sh`，它抓取本 CLI 的終端機視窗 handle/pid、決定配哪張圖、寫一個 pending 狀態檔，並確保 renderer 正在跑。長駐 renderer（Windows: PowerShell+WinForms；macOS: Python+Tkinter）輪詢狀態夾、把所有 pending 圖排成自適應網格、處理點擊（切回對應 CLI）與「回到對應 CLI 即關」偵測，pending 空了就自我結束。

**Tech Stack:** Bash（Git Bash on Windows）、PowerShell + WinForms + Win32 P/Invoke、Python3 + Tkinter + osascript（macOS）。**無新增第三方依賴。**

## Global Constraints

逐條來自 spec，每個 task 都隱含適用：

- **版本**：`plugin.json` 與 `marketplace.json` 的 `version` 一律 `1.2.0`（兩處同步）。
- **絕不阻塞 Claude**：`alert.sh` 全程吞錯、背景啟動 renderer、**無論如何 `exit 0`**。
- **無計時器自動消失**：renderer **不得**有任何「顯示 N 秒後關」「最長上限」「離開再切回 + 連續確認」邏輯。圖只在「被點擊」或「回到其對應 CLI（前景視窗==該 hwnd / 該 term_pid）」時消失。
- **不搶焦點**：renderer 視窗以 Windows `WS_EX_NOACTIVATE` 顯示（macOS 以對應方式避免奪焦）。硬性要求。
- **零外部依賴**：bash 端不得用 `jq`；狀態檔用 `key=value` 文字 / TSV（避免 jq 與 Windows 反斜線跳脫問題）。Windows 僅需 Git Bash + PowerShell；macOS 僅需 python3 + osascript。
- **狀態資料夾**：預設 `~/.claude/alert-need-human/`，可由環境變數 `ALERT_STATE_DIR` 覆寫（測試用）。圖片資料夾預設 `~/.claude/alert-images/`，可由 `ALERT_IMAGE_DIR` 覆寫。
- **圖片來源優先序**：資料夾有圖 → 舊單張 `~/.claude/alert-image.png` → 內建 `assets/default-alert.png` → 安靜不顯示。
- **終端機行程名清單**（小寫，不含 .exe）：Windows `windowsterminal,wt,powershell,pwsh,cmd,conhost,code,alacritty,wezterm`；macOS `terminal,iterm,iterm2,code,warp,alacritty,wezterm,kitty,hyper`。
- **監聽事件**：`Stop`、`StopFailure`、`Notification`(`permission_prompt|idle_prompt|elicitation_dialog`)。**不監聽** `SubagentStop`。
- **網格規則**：`cols = (n≤MaxPerRow) ? n : min(MaxPerRow, ceil(√n))`；`rows = ceil(n/cols)`；`MaxPerRow` 預設 3。圖片等比縮放、完整顯示不裁切。

## 狀態檔格式（所有 task 共用契約）

**`pending/<key>.txt`**（每行 `欄位=值`，值為該行 `=` 之後的全部原文，不跳脫）：
```
key=<term_pid 或 session_id>
session_id=<sid 或空>
image_path=<圖片絕對路徑>
hwnd=<終端機視窗 handle 整數；macOS 為 0>
term_pid=<終端機程序 pid 整數；取不到為 0>
cwd=<工作目錄>
reason=<stop|stop_failure|permission|idle|elicitation>
seq=<整數>
```

**`assignments.tsv`**（佔座記錄，每行 `term_pid<TAB>image_path`）

**`seq`**（單一整數的文字檔，全域遞增）、**`renderer.pid`**（renderer 的 PID）、**`renderer.lock`/`*.lock`**（以 `mkdir` 為原子鎖的目錄）。

---

### Task 1: 視窗擷取探針（GATE — 阻擋下游視窗綁定實作）

**目的：** 在你實際以 cmd/PowerShell 跑 Claude Code 的環境，確認「從 hook 程序往上爬，能不能、以及如何抓到 CLI 終端機視窗」。此 task 的產出（`probe.txt` 內容）決定 Task 4 的 handle 擷取策略與終端機名稱清單微調。

**Files:**
- Create: `scripts/probe-window.ps1`

**Interfaces:**
- Produces: `~/.claude/alert-need-human/probe.txt`（人讀；列出 GetConsoleWindow 結果 + 完整 parent 程序樹，每層 ProcessName/PID/MainWindowHandle/Title，並標出第一個符合終端機清單且有可見視窗的祖先）。

- [ ] **Step 1: 建立探針腳本**

建立 `scripts/probe-window.ps1`：

```powershell
# probe-window.ps1 — 診斷：從指定 PID 往上爬程序樹，找出 CLI 終端機視窗。
# 用法（從 Claude Code 所在的 CLI 手動執行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-window.ps1
# 或由 alert.sh 暫時帶入 hook 的 bash PID：
#   powershell ... -File scripts\probe-window.ps1 -FromPid <pid>
param([int]$FromPid = $PID)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class P {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

$termNames = @('windowsterminal','wt','powershell','pwsh','cmd','conhost','code','alacritty','wezterm')

$stateDir = Join-Path $env:USERPROFILE '.claude\alert-need-human'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$out = Join-Path $stateDir 'probe.txt'

$lines = @()
$lines += "=== probe @ FromPid=$FromPid ==="
$cw = [P]::GetConsoleWindow()
$lines += ("GetConsoleWindow() = {0}  visible={1}" -f $cw, ([P]::IsWindowVisible($cw)))

$lines += "--- parent chain (from FromPid upward) ---"
$cur = $FromPid
for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur"
    if (-not $p) { break }
    $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
    $mh = if ($proc) { $proc.MainWindowHandle } else { 0 }
    $title = if ($proc) { $proc.MainWindowTitle } else { '' }
    $name = ($p.Name -replace '\.exe$','').ToLower()
    $isTerm = $termNames -contains $name
    $mark = if ($isTerm -and $mh -ne 0) { '  <== TERMINAL+WINDOW' } elseif ($isTerm) { '  <== terminal (no MainWindowHandle)' } else { '' }
    $lines += ("[{0}] pid={1} name={2} mainHwnd={3} title='{4}'{5}" -f $i, $cur, $name, $mh, $title, $mark)
    $cur = [int]$p.ParentProcessId
}
$lines | Tee-Object -FilePath $out
Write-Host "`n--> 已寫入 $out"
```

- [ ] **Step 2: 由使用者執行並回貼結果**

請使用者在實際跑 Claude Code 的 CLI（cmd 或 PowerShell 視窗）中執行：

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-window.ps1`
Expected: 終端機印出 GetConsoleWindow 值與一串 parent chain，且 `~/.claude/alert-need-human/probe.txt` 產生。**使用者把 probe.txt 內容回貼。**

額外驗證「從 bash hook 往上爬」的真實情境（模擬 hook）：

Run: `bash -c 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts/probe-window.ps1 -FromPid $$'`
Expected: 印出從 bash 程序往上的 chain；確認其中**有**一層被標記為 `<== TERMINAL+WINDOW`（理想），或記下實際層級樣貌。

- [ ] **Step 3: 鎖定策略並記錄**

依回貼的 `probe.txt` 判定下游 Task 4 採用哪條路徑，並在本檔末「探針結論」區記下：
- 是否 `GetConsoleWindow()` 直接可用（非 0 且 visible）。
- parent chain 中 CLI 終端機是第幾層、ProcessName 為何、是否需要把某個未列入的行程名加進清單。
- 若兩者皆無可見視窗（best-effort 情境），標記 Task 4 走「視窗標題比對 / 最近作用終端機」退路。

- [ ] **Step 4: Commit**

```bash
git add scripts/probe-window.ps1 docs/superpowers/plans/2026-06-29-multi-instance-alert.md
git commit -m "feat: add window-capture probe (gates window binding)"
```

> **GATE：** 在 subagent-driven 模式下，此處為人為檢查點——需使用者回貼 `probe.txt` 並確認策略後，才進入 Task 4。Task 2、3（純 bash 邏輯）不依賴探針，可先行。

---

### Task 2: `popup-common.sh` 基礎（路徑 / 原子寫 / 鎖 / 存活判定 / 清理）

**Files:**
- Create: `scripts/lib/popup-common.sh`
- Create: `tests/test-popup-common.sh`
- Create: `tests/run-tests.sh`

**Interfaces:**
- Produces（供 Task 3、5 source）：
  - `pc_state_dir` → echo 狀態夾路徑（不存在則建立，含 `pending/`）。
  - `pc_image_dir` → echo 圖片夾路徑。
  - `pc_atomic_write <dest> <content>` → 原子寫入（temp + mv）。
  - `pc_with_lock <lockname> <cmd...>` → 以 `mkdir` 取得具名鎖、執行 cmd、釋放；逾時（~2s）放棄仍執行。
  - `pc_is_alive <pid>` → return 0 表示存活（Windows 用 `tasklist`，其餘用 `kill -0`）。
  - `pc_next_seq` → echo 遞增後的 seq 整數（加鎖）。
  - `pc_cleanup_stale` → 移除 `term_pid` 已死的 pending 檔，並從 `assignments.tsv` 移除該 pid。
  - `pc_read_field <file> <key>` → echo 指定欄位值（讀 `key=value`）。

- [ ] **Step 1: 寫失敗測試**

建立 `tests/test-popup-common.sh`：

```bash
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

# 清理 stale：寫一個 term_pid 已死的 pending，應被清掉
printf 'key=99999999\nterm_pid=99999999\n' > "$d/pending/99999999.txt"
printf '99999999\t/img/a.png\n' > "$d/assignments.tsv"
pc_cleanup_stale
[ -f "$d/pending/99999999.txt" ] && ok exists gone "stale pending removed" || ok gone gone "stale pending removed"
grep -q 99999999 "$d/assignments.tsv" 2>/dev/null && ok kept removed "stale assign removed" || ok removed removed "stale assign removed"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

建立 `tests/run-tests.sh`：

```bash
#!/usr/bin/env bash
# 跑所有可在本機自動化的測試；缺執行檔的測試會略過並提示。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "== bash: test-popup-common =="; bash "$HERE/test-popup-common.sh" || rc=1
echo "== bash: test-assign =="; [ -f "$HERE/test-assign.sh" ] && { bash "$HERE/test-assign.sh" || rc=1; }
if command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
  PS=powershell; command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
  echo "== pwsh: test-grid =="; [ -f "$HERE/test-grid.ps1" ] && { "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/test-grid.ps1" 2>/dev/null || echo "$HERE/test-grid.ps1")" || rc=1; }
else echo "(skip pwsh grid test: powershell not found)"; fi
if command -v python3 >/dev/null 2>&1; then
  echo "== py: test-grid =="; [ -f "$HERE/test-grid.py" ] && { python3 "$HERE/test-grid.py" || rc=1; }
else echo "(skip py grid test: python3 not found)"; fi
exit $rc
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-popup-common.sh`
Expected: FAIL — `popup-common.sh` 不存在 / 函式未定義（`pc_state_dir: command not found` 之類），結尾非 0。

- [ ] **Step 3: 實作 `popup-common.sh` 基礎**

建立 `scripts/lib/popup-common.sh`：

```bash
#!/usr/bin/env bash
# popup-common.sh — hook 與 renderer 共用的狀態夾操作（零外部依賴，不用 jq）。
# 由 alert.sh source。所有路徑可用 ALERT_STATE_DIR / ALERT_IMAGE_DIR 覆寫（測試用）。

pc_state_dir() {
  local d="${ALERT_STATE_DIR:-$HOME/.claude/alert-need-human}"
  mkdir -p "$d/pending" 2>/dev/null
  printf '%s' "$d"
}

pc_image_dir() {
  printf '%s' "${ALERT_IMAGE_DIR:-$HOME/.claude/alert-images}"
}

pc_atomic_write() {
  # $1=dest $2=content
  local dest="$1" content="$2" tmp
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || tmp="${dest}.tmp.$$"
  printf '%s' "$content" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$dest" 2>/dev/null
}

pc_with_lock() {
  # $1=lockname 其餘=要執行的命令。以 mkdir 為原子鎖；最多等 ~2 秒。
  local name="$1"; shift
  local lock; lock="$(pc_state_dir)/${name}.lock"
  local i=0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge 20 ] && break
    sleep 0.1
  done
  "$@"; local rc=$?
  rmdir "$lock" 2>/dev/null
  return $rc
}

pc_is_alive() {
  # $1=pid；存活回 0
  local pid="$1"
  [ -z "$pid" ] && return 1
  [ "$pid" = "0" ] && return 1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      tasklist //FI "PID eq $pid" 2>/dev/null | grep -q "$pid" && return 0 || return 1 ;;
    *) kill -0 "$pid" 2>/dev/null && return 0 || return 1 ;;
  esac
}

pc_read_field() {
  # $1=file $2=key → echo 該行 = 之後的原文
  local f="$1" k="$2" line
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
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
  # $1=term_pid 從 assignments.tsv 移除該行（加鎖）
  _pc_rel() {
    local f="$(pc_state_dir)/assignments.tsv" pid="$1"
    [ -f "$f" ] || return 0
    grep -v -E "^${pid}	" "$f" > "$f.tmp" 2>/dev/null
    mv -f "$f.tmp" "$f" 2>/dev/null
  }
  pc_with_lock assign _pc_rel "$1"
}

pc_cleanup_stale() {
  local d; d="$(pc_state_dir)"
  local f tpid
  for f in "$d"/pending/*.txt; do
    [ -e "$f" ] || continue
    tpid="$(pc_read_field "$f" term_pid)"
    if ! pc_is_alive "$tpid"; then
      rm -f "$f" 2>/dev/null
      [ -n "$tpid" ] && [ "$tpid" != "0" ] && pc_release_assign "$tpid"
    fi
  done
}
```

> 註：`pc_release_assign` 內以字面 TAB 比對（`^pid<TAB>`）。在腳本中該 TAB 必須是真實 tab 字元。

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-popup-common.sh`
Expected: `PASS=N FAIL=0`，退出碼 0。

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/popup-common.sh tests/test-popup-common.sh tests/run-tests.sh
git commit -m "feat: state-folder primitives (paths, lock, atomic write, stale cleanup) + tests"
```

---

### Task 3: 圖片探索與佔座分配（claim / cycle / 退路）

**Files:**
- Modify: `scripts/lib/popup-common.sh`（新增函式）
- Create: `tests/test-assign.sh`

**Interfaces:**
- Consumes: Task 2 的 `pc_state_dir`、`pc_image_dir`、`pc_with_lock`、`pc_read_field`。
- Produces:
  - `pc_list_images` → 依檔名（不分大小寫）排序 echo 圖片絕對路徑，一行一個；無圖則無輸出。支援副檔名 png/jpg/jpeg/gif/bmp。
  - `pc_assign_image <term_pid>` → echo 該 pid 應顯示的圖片絕對路徑。首次依「未占用且序最前」佔座並寫入 `assignments.tsv`；之後沿用；圖數不足時 cycle；資料夾無圖時退路到舊單張 → 內建預設 → 空字串。內部加 `assign` 鎖。

- [ ] **Step 1: 寫失敗測試**

建立 `tests/test-assign.sh`：

```bash
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
unset ALERT_LEGACY_IMAGE
export ALERT_DEFAULT_IMAGE="$SBX/default-alert.png"; : > "$ALERT_DEFAULT_IMAGE"
ok "$(basename "$(pc_assign_image 202)")" "default-alert.png" "builtin default fallback"

# 全無 → 空字串
unset ALERT_DEFAULT_IMAGE
ok "$(pc_assign_image 203)" "" "no image -> empty"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-assign.sh`
Expected: FAIL — `pc_list_images` / `pc_assign_image` 未定義。

- [ ] **Step 3: 實作分配邏輯**

在 `scripts/lib/popup-common.sh` 末尾新增：

```bash
pc_list_images() {
  local dir; dir="$(pc_image_dir)"
  [ -d "$dir" ] || return 0
  # 依檔名不分大小寫排序；只取常見圖片副檔名
  local f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
      *.png|*.jpg|*.jpeg|*.gif|*.bmp) printf '%s\n' "$f" ;;
    esac
  done | LC_ALL=C sort -f
}

pc_assign_image() {
  # $1=term_pid → echo 圖片路徑
  local pid="$1"
  _pc_assign() {
    local pid="$1"
    local af; af="$(pc_state_dir)/assignments.tsv"
    # 既有佔座 → 沿用
    if [ -f "$af" ]; then
      local existing
      existing="$(grep -E "^${pid}	" "$af" 2>/dev/null | head -n1 | cut -f2-)"
      if [ -n "$existing" ] && [ -f "$existing" ]; then printf '%s' "$existing"; return 0; fi
    fi
    # 取得排序圖清單
    local imgs; imgs="$(pc_list_images)"
    if [ -n "$imgs" ]; then
      local total used_count idx pick i=0
      total="$(printf '%s\n' "$imgs" | grep -c .)"
      # 已占用數（行數）決定下一個索引；cycle 用 mod
      used_count=0; [ -f "$af" ] && used_count="$(grep -c . "$af" 2>/dev/null)"
      idx=$(( used_count % total ))
      pick="$(printf '%s\n' "$imgs" | sed -n "$((idx+1))p")"
      printf '%s	%s\n' "$pid" "$pick" >> "$af"
      printf '%s' "$pick"; return 0
    fi
    # 退路 1：舊單張
    local legacy="${ALERT_LEGACY_IMAGE:-$HOME/.claude/alert-image.png}"
    if [ -f "$legacy" ]; then printf '%s' "$legacy"; return 0; fi
    # 退路 2：內建預設
    local def="${ALERT_DEFAULT_IMAGE:-}"
    if [ -n "$def" ] && [ -f "$def" ]; then printf '%s' "$def"; return 0; fi
    # 全無
    printf '%s' ''
  }
  pc_with_lock assign _pc_assign "$pid"
}
```

> 設計註：`idx = used_count % total` 讓「第 N 個首次佔座的 CLI」取第 `N mod total` 張，達成 spec 的 cycle 行為；既有 pid 直接沿用前次結果，達成「每個 CLI 固定一張」。`ALERT_DEFAULT_IMAGE` 由 `alert.sh` 設為 `assets/default-alert.png` 的實際路徑。

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-assign.sh`
Expected: `PASS=N FAIL=0`，退出碼 0。

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/popup-common.sh tests/test-assign.sh
git commit -m "feat: image discovery + per-CLI claim/cycle assignment with fallback chain + tests"
```

---

### Task 4: Windows 視窗擷取 `get-window.ps1`（依 Task 1 探針結果）

**Files:**
- Create: `scripts/get-window.ps1`

**Interfaces:**
- Consumes: Task 1 探針結論（哪條路徑可行、終端機名稱清單是否需增補）。
- Produces: stdout 一行 `<hwnd>\t<term_pid>`（tab 分隔，整數；找不到輸出 `0\t0`）。供 `alert.sh` 擷取本 CLI 視窗。

- [ ] **Step 1: 實作擷取腳本**

建立 `scripts/get-window.ps1`（實作 §6 後備鏈：先 parent-tree 走訪、再 GetConsoleWindow）：

```powershell
# get-window.ps1 — 輸出當前 CLI 終端機視窗的 "hwnd<TAB>pid"。
# 用法：powershell ... -File get-window.ps1 -FromPid <hook 的 bash PID>
param([int]$FromPid = $PID)
$ErrorActionPreference = 'SilentlyContinue'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class GW {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@

$termNames = @('windowsterminal','wt','powershell','pwsh','cmd','conhost','code','alacritty','wezterm')

function Emit([long]$hwnd,[int]$pid) { Write-Output ("{0}`t{1}" -f $hwnd, $pid); exit 0 }

# 策略 1：從 FromPid 往上爬，找第一個「終端機名稱 + 有可見主視窗」的祖先
$cur = $FromPid
for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur"
    if (-not $p) { break }
    $name = ($p.Name -replace '\.exe$','').ToLower()
    if ($termNames -contains $name) {
        $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne 0 -and [GW]::IsWindowVisible($proc.MainWindowHandle)) {
            Emit ([long]$proc.MainWindowHandle) ([int]$cur)
        }
    }
    $cur = [int]$p.ParentProcessId
}

# 策略 2：GetConsoleWindow（黑窗常可直接取得），用視窗取得擁有它的 pid
$cw = [GW]::GetConsoleWindow()
if ($cw -ne [IntPtr]::Zero -and [GW]::IsWindowVisible($cw)) {
    $opid = 0; [void][GW]::GetWindowThreadProcessId($cw, [ref]$opid)
    Emit ([long]$cw) ([int]$opid)
}

# 皆失敗
Emit 0 0
```

> 若 Task 1 探針顯示某環境需把額外行程名（例如自訂終端）加入，於此處 `$termNames` 增補；若顯示走「視窗標題比對」退路，則在此追加策略 3（依標題關鍵字找視窗）——以探針結論為準。

- [ ] **Step 2: 手動驗證（擷取正確視窗）**

從實際跑 Claude Code 的 CLI 執行（模擬 hook 從 bash 往上爬）：

Run: `bash -c 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts/get-window.ps1 -FromPid $$'`
Expected: 輸出單行 `<非零 hwnd><TAB><pid>`；`pid` 對應你的終端機程序（可用工作管理員核對）。若輸出 `0	0`，回到 Task 1 依探針調整策略/清單。

- [ ] **Step 3: 手動驗證（hwnd 確實可聚焦該視窗）**

把上一步拿到的 hwnd 餵給一個聚焦測試：

Run（將 `<HWND>` 換成實得值）:
```
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type 'using System;using System.Runtime.InteropServices;public class F{[DllImport(\"user32.dll\")]public static extern bool SetForegroundWindow(IntPtr h);[DllImport(\"user32.dll\")]public static extern bool ShowWindow(IntPtr h,int n);}'; [F]::ShowWindow([IntPtr]<HWND>,9); [F]::SetForegroundWindow([IntPtr]<HWND>)"
```
Expected: 對應的終端機視窗被帶到前景（`ShowWindow ...,9` = SW_RESTORE）。確認聚焦的是「那一個」CLI。

- [ ] **Step 4: Commit**

```bash
git add scripts/get-window.ps1
git commit -m "feat: capture current CLI terminal window handle + pid (parent-tree walk, console fallback)"
```

---

### Task 5: 重寫 `alert.sh`（薄寫入器 + 跨平台分派）

**Files:**
- Modify: `scripts/alert.sh`（整支重寫）

**Interfaces:**
- Consumes: `popup-common.sh` 全部函式；Windows 的 `get-window.ps1`；Task 6 的 `show-popup.ps1`、Task 9 的 `show-popup.sh`。
- Produces: 每次事件寫好 `pending/<key>.txt` 並確保 renderer 在跑。
- 測試注入點（env）：`ALERT_FAKE_WINLINE`（直接給 `hwnd<TAB>pid`，跳過 PowerShell 擷取）、`ALERT_NO_RENDERER=1`（不啟動 renderer，僅寫狀態）。

- [ ] **Step 1: 寫整合測試（可在 Windows bash 自動跑）**

建立 `tests/test-alert.sh`：

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 — got [$1] want [$2]"; fi; }

SBX="$(mktemp -d)"
export ALERT_STATE_DIR="$SBX/state"
export ALERT_IMAGE_DIR="$SBX/images"; mkdir -p "$ALERT_IMAGE_DIR"; : > "$ALERT_IMAGE_DIR/a.png"
export ALERT_FAKE_WINLINE=$'4242\t777'   # 假 hwnd=4242 term_pid=777
export ALERT_NO_RENDERER=1
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"

# 餵一個 Stop 事件的 JSON 給 alert.sh
printf '{"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"Stop"}' | bash "$HERE/../scripts/alert.sh"

PF="$ALERT_STATE_DIR/pending/777.txt"
[ -f "$PF" ] && ok yes yes "pending file by term_pid created" || ok no yes "pending file by term_pid created"
. "$HERE/../scripts/lib/popup-common.sh"
ok "$(pc_read_field "$PF" hwnd)" "4242" "hwnd recorded"
ok "$(pc_read_field "$PF" term_pid)" "777" "term_pid recorded"
ok "$(pc_read_field "$PF" session_id)" "sess-1" "session_id recorded"
ok "$(basename "$(pc_read_field "$PF" image_path)")" "a.png" "image assigned"
ok "$(pc_read_field "$PF" reason)" "stop" "reason mapped from Stop"

# 同一 term_pid 再來一次 Notification → 覆寫、仍一個檔
printf '{"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"Notification","message":"permission needed"}' | bash "$HERE/../scripts/alert.sh"
n="$(ls "$ALERT_STATE_DIR/pending" | wc -l | tr -d ' ')"
ok "$n" "1" "same term_pid overwrites (no stacking)"
ok "$(pc_read_field "$PF" reason)" "permission" "reason updated to permission"

rm -rf "$SBX"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

並在 `tests/run-tests.sh` 的 bash 區塊加一行：`echo "== bash: test-alert =="; [ -f "$HERE/test-alert.sh" ] && { bash "$HERE/test-alert.sh" || rc=1; }`

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-alert.sh`
Expected: FAIL — 舊 `alert.sh` 不寫 pending 檔，找不到 `777.txt`。

- [ ] **Step 3: 重寫 `alert.sh`**

整支替換 `scripts/alert.sh`：

```bash
#!/usr/bin/env bash
# alert.sh — 多實例提醒：薄寫入器 + 跨平台分派。
# 由 Stop / StopFailure / Notification hook 呼叫。讀 stdin 事件 JSON，
# 抓本 CLI 終端機視窗，決定配圖，寫 pending 狀態檔，確保 renderer 在跑，立即 exit 0。

# 讀掉並保存 stdin（避免阻塞）
STDIN_JSON="$(cat 2>/dev/null || true)"

# plugin 根目錄
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
. "$SCRIPTS_DIR/lib/popup-common.sh"

# 讓退路找得到內建預設圖
export ALERT_DEFAULT_IMAGE="${ALERT_DEFAULT_IMAGE:-$PLUGIN_ROOT/assets/default-alert.png}"

# --- 從 JSON 取欄位（無 jq：抓 "key":"value" 或 "key":value）---
json_str() { printf '%s' "$STDIN_JSON" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1; }

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
      WINLINE="$("$PS" -NoProfile -ExecutionPolicy Bypass -File "$PS_GET" -FromPid "$$" 2>/dev/null | tr -d '\r')"
      ;;
    Darwin) WINLINE=$'0\t0' ;;   # macOS 無視窗 handle，term_pid 由 renderer 端 best-effort
    *) WINLINE=$'0\t0' ;;
  esac
fi
HWND="$(printf '%s' "$WINLINE" | cut -f1)"; [ -z "$HWND" ] && HWND=0
TERM_PID="$(printf '%s' "$WINLINE" | cut -f2)"; [ -z "$TERM_PID" ] && TERM_PID=0

# --- 決定主鍵：優先 term_pid，否則 session_id ---
if [ "$TERM_PID" != "0" ]; then KEY="$TERM_PID"; else KEY="${SESSION_ID:-unknown}"; fi

# --- 先清孤兒，再決定配圖 ---
pc_cleanup_stale
IMAGE="$(pc_assign_image "$TERM_PID")"
SEQ="$(pc_next_seq)"

# --- 寫 pending ---
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
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-alert.sh`
Expected: `PASS=N FAIL=0`，退出碼 0。

- [ ] **Step 5: 回歸——確認其他測試仍綠**

Run: `bash tests/run-tests.sh`
Expected: bash 測試全 PASS（grid 測試此時尚未建立會被略過或於後續 task 補上）。

- [ ] **Step 6: Commit**

```bash
git add scripts/alert.sh tests/test-alert.sh tests/run-tests.sh
git commit -m "feat: rewrite alert.sh as thin multi-instance state writer + dispatcher"
```

---

### Task 6: `show-popup.ps1` renderer — 視窗外殼 + 輪詢 + 空則自我結束

**Files:**
- Modify: `scripts/show-popup.ps1`（整支重寫，分 Task 6/7/8 漸進完成；本 task 完成可顯示單張、刪檔即消失、空則退出）

**Interfaces:**
- Consumes: `pending/<key>.txt`（Task 5 格式）。
- Produces（供 Task 7、8 延伸）：全域 `$Items`（hashtable: key → @{Path,Hwnd,TermPid,Seq,Box}）、函式 `Sync-Pending`、`Read-Pending`、視窗 `$form`、`$timer`。

- [ ] **Step 1: 重寫 renderer（外殼 + 輪詢 + 自結束）**

整支替換 `scripts/show-popup.ps1`：

```powershell
# show-popup.ps1 — 長駐 renderer（單一實例）。輪詢狀態夾，把所有 pending 圖
# 排成自適應網格顯示於螢幕右下角；不搶焦點；無任何計時自動關閉。
# 圖只在「被點擊」或「回到其對應 CLI」時消失；pending 空了自我結束。

# 可調參數
$MaxPerRow           = 3
$MaxLayoutWidthRatio = 0.40
$GapPx               = 12
$MarginPx            = 20
$PollMs              = 300
$TerminalProcessNames = @('windowsterminal','wt','powershell','pwsh','cmd','conhost','code','alacritty','wezterm')

$ErrorActionPreference = 'Stop'

# 狀態夾（與 popup-common.sh 一致；允許 ALERT_STATE_DIR 覆寫）
$StateDir = if ($env:ALERT_STATE_DIR) { $env:ALERT_STATE_DIR } else { Join-Path $env:USERPROFILE '.claude\alert-need-human' }
$PendingDir = Join-Path $StateDir 'pending'
New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
$PidFile = Join-Path $StateDir 'renderer.pid'

# 單一實例：關掉舊 renderer
if (Test-Path -LiteralPath $PidFile) {
  try {
    $oldPid = [int](Get-Content -LiteralPath $PidFile -ErrorAction Stop | Select-Object -First 1)
    $op = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($op -and $op.ProcessName -match '^(powershell|pwsh)$' -and $oldPid -ne $PID) {
      Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
Set-Content -LiteralPath $PidFile -Value $PID -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
}
'@

# 不搶焦點的視窗
$WS_EX_NOACTIVATE = 0x08000000
$WS_EX_TOOLWINDOW = 0x00000080
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.BackColor = [System.Drawing.Color]::White
# 不奪焦的完整套用（WS_EX_NOACTIVATE）於 Task 8 以 SetWindowLong 落實
$script:Items = @{}

function Read-Pending {
  # 回傳 hashtable: key -> @{Path;Hwnd;TermPid;Seq}
  $result = @{}
  Get-ChildItem -LiteralPath $PendingDir -Filter *.txt -ErrorAction SilentlyContinue | ForEach-Object {
    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)) {
      $idx = $line.IndexOf('=')
      if ($idx -gt 0) { $h[$line.Substring(0,$idx)] = $line.Substring($idx+1) }
    }
    if ($h.ContainsKey('key')) {
      $result[$h['key']] = @{
        Path = $h['image_path']; Hwnd = [int64]($h['hwnd']); TermPid = [int]($h['term_pid']); Seq = [int]($h['seq'])
      }
    }
  }
  return $result
}

function Layout-And-Render {
  # 由 $script:Items 重畫網格（Task 7 實作完整版；此處先單欄堆疊佔位）
  $form.Controls.Clear()
  $keys = $script:Items.Keys | Sort-Object { $script:Items[$_].Seq }
  $n = $keys.Count
  if ($n -eq 0) { return }
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $cell = 200
  $y = 0
  foreach ($k in $keys) {
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pb.Width = $cell; $pb.Height = $cell; $pb.Top = $y; $pb.Left = 0
    try { $pb.Image = [System.Drawing.Image]::FromFile($script:Items[$k].Path) } catch {}
    $form.Controls.Add($pb)
    $y += $cell + $GapPx
  }
  $form.Width = $cell
  $form.Height = $y
  $form.Left = $area.X + $area.Width - $form.Width - $MarginPx
  $form.Top  = $area.Y + $area.Height - $form.Height - $MarginPx
}

function Sync-Pending {
  $latest = Read-Pending
  # 自癒：term_pid 已死的，刪其 pending 檔（renderer 端也做一層）
  foreach ($k in @($latest.Keys)) {
    $tp = $latest[$k].TermPid
    if ($tp -ne 0) {
      $alive = $null -ne (Get-Process -Id $tp -ErrorAction SilentlyContinue)
      if (-not $alive) {
        Remove-Item -LiteralPath (Join-Path $PendingDir "$k.txt") -ErrorAction SilentlyContinue
        $latest.Remove($k); continue
      }
    }
  }
  # 比較差異
  $changed = $false
  if ($latest.Count -ne $script:Items.Count) { $changed = $true }
  else { foreach ($k in $latest.Keys) { if (-not $script:Items.ContainsKey($k)) { $changed = $true; break } } }
  $script:Items = $latest
  if ($latest.Count -eq 0) {
    # pending 空 → 自我結束
    try { if ((Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1) -eq "$PID") { Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue } } catch {}
    $timer.Stop(); $form.Close(); return
  }
  if ($changed) { Layout-And-Render }
  if (-not $form.Visible) { $form.Show() }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollMs
$timer.Add_Tick({ try { Sync-Pending } catch {} })

# 先做一次，再啟動輪詢
$form.Add_Shown({ $timer.Start() })
$form.Add_Load({ try { Sync-Pending } catch {} })

[void]$form.ShowDialog()
```

> 註：本 task 的 `Layout-And-Render` 為單欄佔位，Task 7 會換成真正的自適應網格；點擊/聚焦於 Task 8 加入。`WS_EX_NOACTIVATE` 的完整套用於 Task 8 用 P/Invoke `SetWindowLong` 落實（此處先以 `TopMost + ShowInTaskbar=$false` 起步）。

- [ ] **Step 2: 手動驗證——單張顯示與刪檔即消失**

先確保有一張測試圖（用內建預設圖即可）。手動寫一個 pending 檔，啟動 renderer：

Run:
```
mkdir -p ~/.claude/alert-need-human/pending
printf 'key=1\nsession_id=s\nimage_path=%s\nhwnd=0\nterm_pid=%s\ncwd=/tmp\nreason=stop\nseq=1\n' "$(cygpath -w "$PWD/assets/default-alert.png")" "$$" > ~/.claude/alert-need-human/pending/1.txt
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File scripts/show-popup.ps1 &
```
Expected: 螢幕右下角出現一張預設提醒圖（單張）。

接著刪檔：

Run: `rm ~/.claude/alert-need-human/pending/1.txt`
Expected: 約 0.3 秒內圖消失、renderer 程序自動結束（`~/.claude/alert-need-human/renderer.pid` 被清除）。

> 註：上面 pending 檔的 `term_pid` 用 `$$`（你的 bash PID，存活中）以避免被自癒誤刪；驗證重點是「刪 pending 檔 → 圖消失 + 自我結束」。

- [ ] **Step 3: Commit**

```bash
git add scripts/show-popup.ps1
git commit -m "feat: Windows renderer shell — poll state, show image bottom-right, self-exit when empty"
```

---

### Task 7: `show-popup.ps1` — 自適應網格版面（含 grid 數學自動測試）

**Files:**
- Create: `scripts/lib/grid.ps1`（共用 grid 數學；renderer 與測試都 dot-source 它，避免重複/漂移）
- Modify: `scripts/show-popup.ps1`（dot-source `grid.ps1` + 替換 `Layout-And-Render`）
- Create: `tests/test-grid.ps1`

**Interfaces:**
- Consumes: Task 6 的 `$script:Items`、`$form`、參數。
- Produces: `scripts/lib/grid.ps1` 內 `Get-GridCols([int]$n,[int]$M)` → 欄數；`Get-GridRows([int]$n,[int]$c)` → 列數。測試與 renderer 共用同一份。

- [ ] **Step 1: 建立共用 grid 模組**

建立 `scripts/lib/grid.ps1`（唯一一份 grid 數學定義；無副作用，可被安全 dot-source）：

```powershell
# grid.ps1 — 共用的自適應網格數學。renderer 與測試都 dot-source 此檔，
# 確保「規格」只有一份、不會漂移。無副作用（僅定義函式）。
function Get-GridCols([int]$n, [int]$M = 3) {
  if ($n -le 0) { return 0 }
  if ($n -le $M) { return $n }
  return [Math]::Min($M, [int][Math]::Ceiling([Math]::Sqrt($n)))
}
function Get-GridRows([int]$n, [int]$c) {
  if ($c -le 0) { return 0 }
  return [int][Math]::Ceiling($n / [double]$c)
}
```

- [ ] **Step 2: 寫 grid 數學失敗測試（dot-source 真正的模組）**

建立 `tests/test-grid.ps1`：

```powershell
# dot-source 與 renderer「完全同一份」grid 數學，故測試驗證的就是 renderer 跑的程式。
. "$PSScriptRoot/../scripts/lib/grid.ps1"

$cases = @(
  @{n=0;c=0;r=0}, @{n=1;c=1;r=1}, @{n=2;c=2;r=1}, @{n=3;c=3;r=1},
  @{n=4;c=2;r=2}, @{n=5;c=3;r=2}, @{n=6;c=3;r=2}, @{n=7;c=3;r=3}, @{n=9;c=3;r=3}
)
$fail = 0
foreach($x in $cases){
  $c = Get-GridCols $x.n 3; $r = Get-GridRows $x.n $c
  if($c -ne $x.c -or $r -ne $x.r){ $fail++; Write-Host ("FAIL n={0}: got {1}x{2} want {3}x{4}" -f $x.n,$r,$c,$x.r,$x.c) }
}
if($fail -eq 0){ Write-Host "grid: PASS"; exit 0 } else { Write-Host "grid: FAIL=$fail"; exit 1 }
```

- [ ] **Step 3: 跑測試確認失敗 → 建立模組後通過**

先確認測試在模組未建立時失敗（若先做 Step 1 則直接驗證通過）：

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-grid.ps1`
Expected: 模組齊備後印出 `grid: PASS`（dot-source 失敗會報錯，代表路徑/模組有問題）。

- [ ] **Step 4: renderer dot-source 模組並重寫 `Layout-And-Render`**

在 `scripts/show-popup.ps1` 參數區之後加入 dot-source（取代 Task 6 內任何 inline 定義）：

```powershell
# 共用 grid 數學（與測試同一份）
. "$PSScriptRoot/lib/grid.ps1"
```

並用下列完整版替換 Task 6 的 `Layout-And-Render`（`Get-GridCols`/`Get-GridRows` 來自上面 dot-source 的模組，**不**在此重新定義）：

```powershell
function Layout-And-Render {
  $form.Controls.Clear()
  $keys = $script:Items.Keys | Sort-Object { $script:Items[$_].Seq }
  $n = $keys.Count
  if ($n -eq 0) { return }

  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $cols = Get-GridCols $n $MaxPerRow
  $rows = Get-GridRows $n $cols

  # 總版面寬上限 → 每格邊長（正方格）
  $maxLayoutW = [int]($area.Width * $MaxLayoutWidthRatio)
  $cell = [int](($maxLayoutW - ($cols + 1) * $GapPx) / $cols)
  if ($cell -lt 80) { $cell = 80 }
  # 高度若超出工作區，回頭縮小格子
  $needH = $rows * $cell + ($rows + 1) * $GapPx
  $maxH = [int]($area.Height * 0.9)
  if ($needH -gt $maxH) {
    $cell = [int](($maxH - ($rows + 1) * $GapPx) / $rows)
    if ($cell -lt 80) { $cell = 80 }
  }

  $layoutW = $cols * $cell + ($cols + 1) * $GapPx
  $layoutH = $rows * $cell + ($rows + 1) * $GapPx
  $form.Width = $layoutW
  $form.Height = $layoutH
  $form.Left = $area.X + $area.Width  - $layoutW - $MarginPx
  $form.Top  = $area.Y + $area.Height - $layoutH - $MarginPx

  for ($i = 0; $i -lt $n; $i++) {
    $k = $keys[$i]
    $rowI = [int][Math]::Floor($i / $cols)
    $colI = $i % $cols
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom   # 等比、不裁切
    $pb.Width = $cell; $pb.Height = $cell
    $pb.Left = $GapPx + $colI * ($cell + $GapPx)
    $pb.Top  = $GapPx + $rowI * ($cell + $GapPx)
    $pb.BackColor = [System.Drawing.Color]::White
    try { $pb.Image = [System.Drawing.Image]::FromFile($script:Items[$k].Path) } catch {}
    $pb.Tag = $k
    $form.Controls.Add($pb)
    $script:Items[$k].Box = $pb
  }
}
```

- [ ] **Step 5: 手動視覺驗證——1/2/3/4/6 張排列**

依序寫入 1→2→3→4→6 個 pending 檔（term_pid 用存活的 `$$` 避免自癒），每次觀察版面（可寫個小迴圈）：

Run（示意，逐張增加後啟動/觀察 renderer）:
```
D=~/.claude/alert-need-human/pending; mkdir -p "$D"; IMG="$(cygpath -w "$PWD/assets/default-alert.png")"
for i in 1 2 3 4 6; do
  rm -f "$D"/*.txt
  for k in $(seq 1 $i); do printf 'key=%s\nimage_path=%s\nhwnd=0\nterm_pid=%s\nreason=stop\nseq=%s\n' "$k" "$IMG" "$$" "$k" > "$D/$k.txt"; done
  echo "顯示 $i 張，按 Enter 看下一組"; read _
done
```
（過程中於另一個視窗啟動 `powershell ... -File scripts/show-popup.ps1 &`）
Expected: 1→單張；2→並排；3→一排三張；4→**2×2**；6→**3×2**。每張等比完整顯示、不裁切，整體貼右下角、不超出螢幕。

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/grid.ps1 scripts/show-popup.ps1 tests/test-grid.ps1
git commit -m "feat: adaptive grid layout (1/2/3 row, 4->2x2, 5/6->3x2) via shared grid.ps1 + test"
```

---

### Task 8: `show-popup.ps1` — 點圖切回 CLI + 回到對應 CLI 即關 + 不搶焦點

**Files:**
- Modify: `scripts/show-popup.ps1`（擴充 P/Invoke、加點擊事件、tick 內前景偵測、NOACTIVATE）

**Interfaces:**
- Consumes: Task 7 的 `$script:Items`（含 `.Box`、`.Hwnd`、`.TermPid`）、`Sync-Pending`、`$timer`。
- Produces: `Remove-Item-Pending <key>`（刪 pending 檔，觸發下次 Sync 移除）、`Focus-Window <hwnd>`。

- [ ] **Step 1: 擴充 P/Invoke 與焦點/移除函式**

把 Task 6 的 `Add-Type @'... class Fg ...'@` 區塊替換為（新增 NOACTIVATE 所需 API 與 thread-attach）：

```powershell
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
}
'@

function Focus-Window([int64]$hwnd) {
  if ($hwnd -eq 0) { return }
  $h = [IntPtr]$hwnd
  [void][Fg]::ShowWindow($h, 9)   # SW_RESTORE
  # 處理 Windows 前景限制：attach 到目前前景視窗的執行緒再 SetForegroundWindow
  $fg = [Fg]::GetForegroundWindow()
  $tFg = 0; [void][Fg]::GetWindowThreadProcessId($fg, [ref]$tFg)
  $tMe = [Fg]::GetCurrentThreadId()
  [void][Fg]::AttachThreadInput($tMe, $tFg, $true)
  [void][Fg]::SetForegroundWindow($h)
  [void][Fg]::AttachThreadInput($tMe, $tFg, $false)
}

function Remove-Item-Pending([string]$key) {
  Remove-Item -LiteralPath (Join-Path $PendingDir "$key.txt") -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: 套用 NOACTIVATE（視窗不奪焦）**

在 `$form.Add_Load` 之前加入：把視窗的擴充樣式加上 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`：

```powershell
$GWL_EXSTYLE = -20
$form.Add_HandleCreated({
  try {
    $ex = [Fg]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
    [void][Fg]::SetWindowLong($form.Handle, $GWL_EXSTYLE, $ex -bor 0x08000000 -bor 0x00000080)
  } catch {}
})
```

- [ ] **Step 3: 在 `Layout-And-Render` 的每張圖加上點擊事件**

在 Task 7 的 `Layout-And-Render` 迴圈內、`$form.Controls.Add($pb)` 之後加入：

```powershell
    $pb.Add_Click({
      param($sender, $e)
      $k = $sender.Tag
      if ($script:Items.ContainsKey($k)) {
        Focus-Window $script:Items[$k].Hwnd   # 切到對應 CLI
        Remove-Item-Pending $k                # 該圖消失（下次 Sync 移除）
      }
    }.GetNewClosure())
```

- [ ] **Step 4: 在 tick 內加「回到對應 CLI 即關」偵測**

把 `$timer.Add_Tick` 改為先做前景偵測、再 Sync：

```powershell
$timer.Add_Tick({
  try {
    # 回到對應 CLI：若目前前景視窗 == 某圖的 hwnd，或前景程序 pid == 某圖 term_pid → 刪該圖
    $fg = [Fg]::GetForegroundWindow()
    $fgPid = 0; [void][Fg]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    foreach ($k in @($script:Items.Keys)) {
      $it = $script:Items[$k]
      if (($it.Hwnd -ne 0 -and [int64]$fg -eq $it.Hwnd) -or ($it.TermPid -ne 0 -and $fgPid -eq $it.TermPid)) {
        Remove-Item-Pending $k
      }
    }
    Sync-Pending
  } catch {}
})
```

> 註：彈窗自身不在終端機清單、且其 hwnd 不等於任何 CLI 的 hwnd，故不會誤判自己為「回到 CLI」。不搶焦點（NOACTIVATE）也確保彈窗顯示時不會把自己變前景。

- [ ] **Step 5: 手動驗證——兩個 CLI 的精準切換與關閉**

需要兩個真實終端機視窗（A、B），各自取得其 hwnd 與 pid（用 Task 4 的 `get-window.ps1` 在各視窗跑一次），分別寫成兩個 pending 檔：

Run（在視窗 A 執行取得 A 的 `hwndA termpidA`，視窗 B 同理；然後）:
```
D=~/.claude/alert-need-human/pending; mkdir -p "$D"; IMG="$(cygpath -w "$PWD/assets/default-alert.png")"
printf 'key=%s\nimage_path=%s\nhwnd=%s\nterm_pid=%s\nreason=stop\nseq=1\n' "$termpidA" "$IMG" "$hwndA" "$termpidA" > "$D/$termpidA.txt"
printf 'key=%s\nimage_path=%s\nhwnd=%s\nterm_pid=%s\nreason=stop\nseq=2\n' "$termpidB" "$IMG" "$hwndB" "$termpidB" > "$D/$termpidB.txt"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File scripts/show-popup.ps1 &
```
Expected:
1. 右下角出現兩張圖（1×2）。
2. **點左圖** → 視窗 A 被帶到前景，且左圖消失、右圖仍在。
3. 用滑鼠點一下視窗 B（切到 B）→ 右圖在約 0.3 秒內自動消失（回到對應 CLI 即關），renderer 隨之結束。
4. 全程在某 CLI 打字時彈窗跳出不奪走鍵盤焦點（可在出現前先持續打字測試）。

- [ ] **Step 6: Commit**

```bash
git add scripts/show-popup.ps1
git commit -m "feat: click-to-focus target CLI, return-to-CLI auto-close, no-activate window"
```

---

### Task 9: macOS renderer `show-popup.sh`（盡力而為 + grid 數學測試）

**Files:**
- Create: `scripts/lib/grid.py`（共用 grid 數學；renderer 與測試都 import 它，與 Windows 的 `grid.ps1` 對應）
- Modify: `scripts/show-popup.sh`（整支重寫為長駐輪詢 renderer，import `grid.py`）
- Create: `tests/test-grid.py`

**Interfaces:**
- Consumes: `pending/<key>.txt`（同格式）；`scripts/lib/grid.py`。
- Produces: `scripts/lib/grid.py` 內 `grid_cols(n, m=3)` / `grid_rows(n, c)`。renderer 與測試共用同一份（與 Windows `grid.ps1` 規格一致）。

> **平台限制（誠實標示）：** 本 task 的 GUI / 視窗聚焦行為**無法在本機（Windows）驗證**，需在 macOS 手動測試；此處先以與 Windows 一致的邏輯實作，並用 `test-grid.py` 自動驗證可在任一有 python3 的機器跑的純數學部分。

- [ ] **Step 1: 建立共用 grid 模組**

建立 `scripts/lib/grid.py`（唯一一份；無副作用，可被 import）：

```python
"""grid.py — 共用的自適應網格數學（與 grid.ps1 規格一致）。renderer 與測試都 import 此檔。"""
import math


def grid_cols(n, m=3):
    if n <= 0:
        return 0
    if n <= m:
        return n
    return min(m, math.ceil(math.sqrt(n)))


def grid_rows(n, c):
    return 0 if c <= 0 else math.ceil(n / c)
```

- [ ] **Step 2: 寫 grid 數學測試（import 真正的模組）**

建立 `tests/test-grid.py`：

```python
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))
from grid import grid_cols, grid_rows  # 與 renderer 同一份

cases = [(0,0,0),(1,1,1),(2,2,1),(3,3,1),(4,2,2),(5,3,2),(6,3,2),(7,3,3),(9,3,3)]
fail = 0
for n, c, r in cases:
    gc = grid_cols(n); gr = grid_rows(n, gc)
    if gc != c or gr != r:
        fail += 1; print(f"FAIL n={n}: got {gr}x{gc} want {r}x{c}")
print("grid: PASS" if fail == 0 else f"grid: FAIL={fail}")
sys.exit(0 if fail == 0 else 1)
```

- [ ] **Step 3: 跑測試確認通過（規格基準）**

Run: `python3 tests/test-grid.py`（若本機無 python3，記錄為「待 macOS/有 python3 環境執行」）
Expected: `grid: PASS`。

- [ ] **Step 4: 重寫 `show-popup.sh` 為長駐輪詢 renderer**

整支替換 `scripts/show-popup.sh`：

```bash
#!/usr/bin/env bash
# show-popup.sh — macOS 長駐 renderer（盡力而為）。輪詢狀態夾，把所有 pending 圖
# 排成自適應網格（Tkinter）顯示於右下角；不搶焦點；無計時自動關閉。
# 圖只在「被點擊」或「回到對應終端機」時消失；pending 空了自我結束。
# 點圖以 AppleScript 盡力把對應終端機帶到前景（無法精準到分頁時僅叫出 App）。

STATE_DIR="${ALERT_STATE_DIR:-$HOME/.claude/alert-need-human}"
PENDING_DIR="$STATE_DIR/pending"
mkdir -p "$PENDING_DIR"
PID_FILE="$STATE_DIR/renderer.pid"

# 單一實例
if [ -f "$PID_FILE" ]; then
  OLD="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then kill "$OLD" 2>/dev/null; fi
fi
echo "$$" > "$PID_FILE" 2>/dev/null
trap '[ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE" 2>/dev/null' EXIT

command -v python3 >/dev/null 2>&1 || exit 0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

python3 - "$PENDING_DIR" "$PID_FILE" "$LIB_DIR" <<'PYEOF' 2>/dev/null
import os, sys, math, glob, subprocess
try:
    import tkinter as tk
except Exception:
    sys.exit(0)

PENDING_DIR, PID_FILE, LIB_DIR = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, LIB_DIR)
from grid import grid_cols, grid_rows   # 與測試、Windows 規格同一份

MAX_PER_ROW = 3
MAX_LAYOUT_WIDTH_RATIO = 0.40
GAP = 12
MARGIN = 20
POLL_MS = 300
TERMINAL_APPS = ["terminal","iterm","iterm2","code","warp","alacritty","wezterm","kitty","hyper"]

def read_pending():
    items = {}
    for f in glob.glob(os.path.join(PENDING_DIR, "*.txt")):
        h = {}
        try:
            for line in open(f, encoding="utf-8", errors="ignore"):
                line = line.rstrip("\n")
                i = line.find("=")
                if i > 0: h[line[:i]] = line[i+1:]
        except Exception:
            continue
        if "key" in h:
            items[h["key"]] = {
                "path": h.get("image_path",""),
                "hwnd": h.get("hwnd","0"),
                "term_pid": int(h.get("term_pid","0") or 0),
                "seq": int(h.get("seq","0") or 0),
                "cwd": h.get("cwd",""),
            }
    return items

def frontmost_app():
    try:
        out = subprocess.check_output(
            ["osascript","-e",'tell application "System Events" to get name of first application process whose frontmost is true'],
            stderr=subprocess.DEVNULL, timeout=1.0)
        return out.decode("utf-8","ignore").strip().lower()
    except Exception:
        return ""

def focus_terminal(item):
    # 盡力而為：把終端機 App 帶到前景（無法精準分頁）
    for app in ["Terminal","iTerm","Warp","Code"]:
        try:
            subprocess.run(["osascript","-e",f'tell application "{app}" to activate'],
                           stderr=subprocess.DEVNULL, timeout=1.0)
            return
        except Exception:
            continue

root = tk.Tk()
root.overrideredirect(True)
root.attributes("-topmost", True)
try: root.attributes("-type", "splash")
except Exception: pass

state = {"items": {}, "boxes": {}}

def remove_pending(key):
    try: os.remove(os.path.join(PENDING_DIR, key + ".txt"))
    except Exception: pass

def render():
    for w in list(state["boxes"].values()):
        w.destroy()
    state["boxes"].clear()
    items = state["items"]
    keys = sorted(items.keys(), key=lambda k: items[k]["seq"])
    n = len(keys)
    if n == 0: return
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    cols = grid_cols(n, MAX_PER_ROW)
    rows = grid_rows(n, cols)
    max_w = int(sw * MAX_LAYOUT_WIDTH_RATIO)
    cell = int((max_w - (cols + 1) * GAP) / cols)
    if cell < 80: cell = 80
    need_h = rows * cell + (rows + 1) * GAP
    if need_h > sh * 0.9:
        cell = max(80, int((sh * 0.9 - (rows + 1) * GAP) / rows))
    layout_w = cols * cell + (cols + 1) * GAP
    layout_h = rows * cell + (rows + 1) * GAP
    root.geometry(f"{layout_w}x{layout_h}+{sw - layout_w - MARGIN}+{sh - layout_h - MARGIN}")
    for i, k in enumerate(keys):
        ri, ci = divmod(i, cols)
        try:
            img = tk.PhotoImage(file=items[k]["path"])
        except Exception:
            img = None
        lbl = tk.Label(root, image=img, bg="white", width=cell, height=cell)
        lbl.image = img
        lbl.place(x=GAP + ci * (cell + GAP), y=GAP + ri * (cell + GAP), width=cell, height=cell)
        lbl.bind("<Button-1>", lambda e, key=k: (focus_terminal(state["items"].get(key, {})), remove_pending(key)))
        state["boxes"][k] = lbl

def tick():
    # 回到對應終端機即關（macOS 僅能粗略以「前景為終端機 App」近似）
    fg = frontmost_app()
    if any(name in fg for name in TERMINAL_APPS):
        for k in list(state["items"].keys()):
            remove_pending(k)
    latest = read_pending()
    # 自癒：term_pid 已死者移除
    for k in list(latest.keys()):
        tp = latest[k]["term_pid"]
        if tp and not _alive(tp):
            remove_pending(k); latest.pop(k, None)
    changed = set(latest.keys()) != set(state["items"].keys())
    state["items"] = latest
    if not latest:
        try:
            if open(PID_FILE).read().strip() == str(os.getpid()): os.remove(PID_FILE)
        except Exception: pass
        root.destroy(); return
    if changed: render()
    root.after(POLL_MS, tick)

def _alive(pid):
    try: os.kill(pid, 0); return True
    except Exception: return False

render()
root.after(POLL_MS, tick)
root.mainloop()
PYEOF
exit 0
```

> 移除舊版的 osascript 純文字 fallback（與「一直顯示、多圖、點圖切 CLI」模型不相容）。若 python3/Tkinter 不可用，renderer 安靜結束（hook 端仍已寫好狀態，無副作用）。

- [ ] **Step 5: 驗證（grid 數學自動 + GUI 待 macOS 手動）**

Run: `python3 tests/test-grid.py`
Expected: `grid: PASS`（本機無 python3 則標記待 macOS 執行）。

GUI/聚焦行為：標記為 **macOS 手動驗證項**（無法在 Windows 自動化），於 Task 12 的跨平台清單追蹤。

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/grid.py scripts/show-popup.sh tests/test-grid.py
git commit -m "feat: macOS renderer parity (poll, grid via shared grid.py, click best-effort focus, no timers) + test"
```

---

### Task 10: 更新 `hooks/hooks.json`（Stop + StopFailure + Notification）

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 1: 寫入新事件集**

整支替換 `hooks/hooks.json`：

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ] }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/alert.sh\"", "timeout": 10 } ]
      }
    ]
  }
}
```

- [ ] **Step 2: 驗證 JSON 合法**

Run: `python3 -c "import json;json.load(open('hooks/hooks.json'));print('ok')"` 或 `node -e "require('./hooks/hooks.json');console.log('ok')"`
Expected: 印出 `ok`（JSON 可解析）。

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: trigger on Stop + StopFailure + Notification(permission|idle|elicitation)"
```

---

### Task 11: 版本升級 + README 全面改寫

**Files:**
- Modify: `.claude-plugin/plugin.json`、`.claude-plugin/marketplace.json`（version → 1.2.0）
- Modify: `README.md`（全面改寫）
- Modify: `.gitignore`（忽略圖片資料夾若誤放專案）

- [ ] **Step 1: 版本號改 1.2.0（兩處）**

`.claude-plugin/plugin.json`：把 `"version": "1.1.1"` 改成 `"version": "1.2.0"`，並把 `description` 更新為多實例語意：
```
"description": "多個 Claude Code 同時跑時，每個結束/卡住的 CLI 在螢幕角落彈出一張對應圖片（自適應網格）；點圖即切回該 CLI。支援 Windows 與 macOS。",
```
`.claude-plugin/marketplace.json`：把兩個 `"version": "1.1.1"` 都改成 `"version": "1.2.0"`，`description` 同步更新。

- [ ] **Step 2: README 全面改寫**

以新行為改寫 `README.md`，至少涵蓋：
- 一句話定位（多實例、一直顯示、點圖切 CLI、網格）。
- 彈窗何時消失：**只有**「點圖（會切回對應 CLI）」或「回到對應 CLI」；**移除**所有定時/30 分鐘說明。
- 多圖與資料夾：放圖到 `~/.claude/alert-images/`、按檔名排序、每個 CLI 固定一張、不夠則循環；舊單張 `~/.claude/alert-image.png` 與內建預設的退路。
- 自適應網格：1/2/3 一排、4→2×2、5/6→3×2；等比不裁切。
- 觸發時機表：`Stop` / `StopFailure`（API 錯誤如 400/429/5xx）/ `Notification`(permission/idle/elicitation)；不含 `SubagentStop`。
- 參數表：`MaxPerRow`、`MaxLayoutWidthRatio`、`GapPx`、`MarginPx`、`PollMs`、終端機名稱清單；指出在 `show-popup.ps1`/`show-popup.sh` 頂端。
- 視窗綁定與探針：說明 `scripts/probe-window.ps1` 的用途與在「切不到對的 CLI」時如何回報/調整終端機清單。
- 運作原理圖（hook→alert.sh→狀態夾→renderer→網格）。
- 疑難排解：沿用並更新（裝完沒反應→enable/reload；切不到對的 CLI→跑探針、補終端機名；macOS 為盡力而為）。

- [ ] **Step 3: `.gitignore` 補一行**

在 `.gitignore` 末尾加入：
```
# 使用者的多圖資料夾若誤放專案目錄，不要提交
alert-images/
```

- [ ] **Step 4: 驗證 JSON 合法 + 版本一致**

Run: `python3 -c "import json;print(json.load(open('.claude-plugin/plugin.json'))['version'], json.load(open('.claude-plugin/marketplace.json'))['version'])"`
Expected: `1.2.0 1.2.0`。

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json README.md .gitignore
git commit -m "docs: bump to 1.2.0 and rewrite README for multi-instance alerts"
```

---

### Task 12: 端對端手動驗證（spec §12 全情境）

**Files:** 無（驗證 task）

> 安裝/重載 plugin 後，以真實 Claude Code 實例驗證。每項記錄 pass/fail，fail 則回對應 task 修正。

- [ ] **Step 1: 安裝並啟用**

Run（在 Claude Code 中）：`/reload-plugins`（或重開 session）。確認 hook 生效。

- [ ] **Step 2: 單一 CLI**

讓一個 Claude Code 回應結束 → 右下角跳一張圖 → 點圖（該 CLI 到前景、圖消失）；再次跑完、改用「直接點回該 CLI」→ 圖在 ~0.3s 消失、renderer 結束。
Expected: 與描述一致。

- [ ] **Step 3: 兩個 CLI 同時停**

開兩個獨立終端機各跑一個 Claude Code，都讓其結束 → 出現兩張圖（1×2）→ 點 #1：#1 的 CLI 到前景且僅 #1 消失、#2 仍在 → 切回 #2 的 CLI：#2 消失。
Expected: 精準對應、互不干擾。

- [ ] **Step 4: 圖片資料夾與版面**

`~/.claude/alert-images/` 分別放 0／1／4／6 張圖，重跑多個 CLI：0→用內建預設；1→都用該張（循環）；4→2×2；6→3×2；每個 CLI 固定自己那張。
Expected: 分配與排列、等比不裁切皆正確。

- [ ] **Step 5: 觸發時機**

分別驗證：權限提問（`permission_prompt`）、閒置（`idle_prompt`）、MCP 結構化提問（`elicitation_dialog`）、API 錯誤（`StopFailure`，如可觸發 400/限流）皆會跳圖；確認子代理結束（`SubagentStop`）**不**跳。
Expected: 與觸發表一致。

- [ ] **Step 6: 不搶焦點 + 韌性**

彈窗跳出時於某 CLI 持續打字不被打斷；強制關閉某 CLI → 其孤兒圖自動移除；`kill` renderer 後下次事件能重新拉起。
Expected: 全數通過。

- [ ] **Step 7: macOS（若有 Mac）**

在 macOS 重複 Step 2–4 的可行部分；確認「點圖至少把終端機 App 叫到前景」「網格與一直顯示」運作；記錄 per-分頁聚焦為已知限制。

- [ ] **Step 8: 收尾 commit（如有微調）**

```bash
git add -A
git commit -m "test: end-to-end manual verification pass for v1.2.0"
```

---

## 探針結論（Task 1 完成後填寫）

- GetConsoleWindow 可用：________
- CLI 終端機位於 parent chain 第 __ 層，ProcessName=________
- 終端機名稱清單需增補：________
- Task 4 採用策略：________
