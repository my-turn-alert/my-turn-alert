#!/usr/bin/env bash
# show-popup.sh — macOS 長駐 renderer（盡力而為）。
#
# 與 Windows 的差異：
#   - macOS 沒有等價於 GetLastInputInfo 的單一公開 API，
#     用 ioreg/HIDIdleTime 作為「最後輸入後經過秒數」的近似（root 才看得到時退回 osascript）。
#   - 沒有 per-tab focus 偵測：使用者切到別 tab 但同一 Terminal App，
#     會被視為「仍在那個 CLI」。已知限制，跨平台一致。
#
# 圖消失的時機（與 Windows 規格盡量對齊）：
#   1) 點圖：立即關 + 把對應終端機 App 帶到前景（盡力而為，不保證精準到分頁）。
#   2) 前景變成「終端機 App」連續 RequiredHits 次（StartedInCli=false）→ 關。
#   3) 若 popup 出現時前景已是終端機（StartedInCli=true）→ 須再偵測到新輸入活動才關。
#   * 最低顯示時間 MinVisibleMs（1500ms）內不關。
#   * pending 空 → 自我結束；term_pid 已死 → 自癒清除。
#   * 從 pending 讀的 key 一律經白名單（^[A-Za-z0-9_.-]{1,128}$）。
#   * 渲染上限 100 張（producer 端 alert.sh 也擋一次）。

# state 夾預設 my-turn-alert（v1.6.0 改名）；舊夾遷移由 alert.sh 做，這裡不重複。
STATE_DIR="${ALERT_STATE_DIR:-$HOME/.claude/my-turn-alert}"
PENDING_DIR="$STATE_DIR/pending"
mkdir -p "$PENDING_DIR"
PID_FILE="$STATE_DIR/renderer.pid"

if [ -f "$PID_FILE" ]; then
  OLD="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then kill "$OLD" 2>/dev/null; fi
fi
echo "$$" > "$PID_FILE" 2>/dev/null
trap '[ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE" 2>/dev/null' EXIT

command -v python3 >/dev/null 2>&1 || exit 0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
MAX_POPUPS="${ALERT_MAX_POPUPS:-100}"

python3 - "$PENDING_DIR" "$PID_FILE" "$LIB_DIR" "$MAX_POPUPS" <<'PYEOF' 2>/dev/null
import glob
import os
import re
import subprocess
import sys
import time

try:
    import tkinter as tk
except Exception:
    sys.exit(0)

PENDING_DIR, PID_FILE, LIB_DIR, MAX_POPUPS = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
sys.path.insert(0, LIB_DIR)
from grid import grid_cols, grid_rows  # 與測試、Windows 規格同一份

MAX_PER_ROW = 3
MAX_LAYOUT_WIDTH_RATIO = 0.40
# 單格尺寸上限：張數少時 cell 由版面寬除出來會過大（單張 = 螢幕寬 40%）。
# ALERT_CELL_MAX 可覆寫。
CELL_MAX = max(80, int(os.environ.get("ALERT_CELL_MAX", "320") or 320))
GAP = 12
MARGIN = 20
POLL_MS = 300
MIN_VISIBLE_MS = 1500
REQUIRED_HITS = 3
TERMINAL_APPS = ["terminal", "iterm", "iterm2", "code", "warp", "alacritty", "wezterm", "kitty", "hyper", "tabby"]

KEY_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,128}$")


def key_safe(k):
    return bool(k and KEY_RE.match(k) and not re.fullmatch(r"\.+", k))


def _alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def read_pending():
    items = {}
    for f in sorted(glob.glob(os.path.join(PENDING_DIR, "*.txt"))):
        name_key = os.path.splitext(os.path.basename(f))[0]
        if not key_safe(name_key):
            continue
        h = {}
        try:
            for line in open(f, encoding="utf-8", errors="ignore"):
                line = line.rstrip("\n")
                i = line.find("=")
                if i > 0:
                    h[line[:i]] = line[i + 1:]
        except Exception:
            continue
        k = h.get("key", "")
        if not key_safe(k) or k != name_key:
            continue
        items[k] = {
            "path": h.get("image_path", ""),
            "hwnd": h.get("hwnd", "0"),
            "term_pid": int(h.get("term_pid", "0") or 0),
            "seq": int(h.get("seq", "0") or 0),
            "cwd": h.get("cwd", ""),
        }
    # 渲染上限：先到先服務 → 保留 seq 最小（最早）的 MAX_POPUPS 個（不刪檔，producer 負責閘門）
    if len(items) > MAX_POPUPS:
        keep = sorted(items.keys(), key=lambda k: items[k]["seq"])[:MAX_POPUPS]
        items = {k: items[k] for k in keep}
    return items


def remove_pending(key):
    if not key_safe(key):
        return
    try:
        os.remove(os.path.join(PENDING_DIR, key + ".txt"))
    except Exception:
        pass
    # ack 戳記：抑制 Stop 後尾隨的 idle_prompt 讓圖幽靈重現（alert.sh 讀取）
    try:
        with open(os.path.join(os.path.dirname(PENDING_DIR), "acked-" + key + ".stamp"), "w") as f:
            f.write("1")
    except Exception:
        pass


def frontmost_app():
    try:
        out = subprocess.check_output(
            ["osascript", "-e",
             'tell application "System Events" to get name of first application process whose frontmost is true'],
            stderr=subprocess.DEVNULL, timeout=1.0)
        return out.decode("utf-8", "ignore").strip().lower()
    except Exception:
        return ""


def system_idle_seconds():
    """近似 GetLastInputInfo：HID 系統閒置秒數。失敗回 None。"""
    try:
        out = subprocess.check_output(
            ["ioreg", "-c", "IOHIDSystem"],
            stderr=subprocess.DEVNULL, timeout=1.0).decode("utf-8", "ignore")
        for line in out.splitlines():
            if "HIDIdleTime" in line:
                parts = line.split("=")
                if len(parts) >= 2:
                    val = parts[-1].strip().rstrip(",").strip()
                    try:
                        return int(val) / 1_000_000_000.0
                    except Exception:
                        continue
    except Exception:
        pass
    try:
        out = subprocess.check_output(
            ["osascript", "-e", 'tell application "System Events" to idle time'],
            stderr=subprocess.DEVNULL, timeout=1.0)
        return float(out.decode("utf-8", "ignore").strip())
    except Exception:
        return None


def focus_terminal(item):
    for app in ["Terminal", "iTerm", "Warp", "Code", "Alacritty", "WezTerm", "kitty", "Hyper", "Tabby"]:
        try:
            subprocess.run(["osascript", "-e", f'tell application "{app}" to activate'],
                           stderr=subprocess.DEVNULL, timeout=1.0)
            return
        except Exception:
            continue


root = tk.Tk()
root.overrideredirect(True)
root.attributes("-topmost", True)
try:
    root.attributes("-type", "splash")
except Exception:
    pass

state = {"items": {}, "boxes": {}, "key_state": {}}


def now_ms():
    return int(time.monotonic() * 1000)


def init_key_state(key, item):
    fg = frontmost_app()
    started_in = any(name in fg for name in TERMINAL_APPS)
    return {
        "first_ms": now_ms(),
        "started_in_cli": started_in,
        "baseline_idle": system_idle_seconds() or 0.0,
        "return_hits": 0,
        "click_requested": False,
    }


def compute_close(st, fg_is_term, now_ms_, idle_s):
    if st["click_requested"]:
        return True
    if now_ms_ - st["first_ms"] < MIN_VISIBLE_MS:
        return False
    if not fg_is_term:
        st["return_hits"] = 0
        return False
    if st["started_in_cli"]:
        if idle_s is None:
            return False
        # 「新的輸入」近似：當前 idle 比 baseline 小（idle 一直在累加，剛動過手就會掉回 0）。
        if idle_s >= st["baseline_idle"] - 0.1:
            st["return_hits"] = 0
            return False
    st["return_hits"] += 1
    return st["return_hits"] >= REQUIRED_HITS


def render():
    for w in list(state["boxes"].values()):
        w.destroy()
    state["boxes"].clear()
    items = state["items"]
    keys = sorted(items.keys(), key=lambda k: items[k]["seq"])
    if len(keys) > MAX_POPUPS:
        keys = keys[:MAX_POPUPS]
    n = len(keys)
    if n == 0:
        return
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    if n > 9:
        cols = min(10, int(__import__("math").ceil(n ** 0.5)))
        if cols < MAX_PER_ROW:
            cols = MAX_PER_ROW
        max_w_ratio = 0.85
    else:
        cols = grid_cols(n, MAX_PER_ROW)
        max_w_ratio = MAX_LAYOUT_WIDTH_RATIO
    rows = grid_rows(n, cols)
    max_w = int(sw * max_w_ratio)
    cell = int((max_w - (cols + 1) * GAP) / cols)
    if cell > CELL_MAX:
        cell = CELL_MAX
    if cell < 80:
        cell = 80
    need_h = rows * cell + (rows + 1) * GAP
    if need_h > sh * 0.9:
        cell = max(48, int((sh * 0.9 - (rows + 1) * GAP) / rows))
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

        def on_click(_e, key=k):
            st = state["key_state"].get(key)
            if st is not None:
                st["click_requested"] = True
            focus_terminal(state["items"].get(key, {}))
            remove_pending(key)
            state["key_state"].pop(key, None)

        lbl.bind("<Button-1>", on_click)
        state["boxes"][k] = lbl


def tick():
    latest = read_pending()
    # 自癒：term_pid 已死者移除
    for k in list(latest.keys()):
        tp = latest[k]["term_pid"]
        if tp and not _alive(tp):
            remove_pending(k)
            latest.pop(k, None)

    # 維護 per-key 狀態
    for k in latest.keys():
        if k not in state["key_state"]:
            state["key_state"][k] = init_key_state(k, latest[k])
    for k in list(state["key_state"].keys()):
        if k not in latest:
            state["key_state"].pop(k, None)

    # 評估關閉
    fg = frontmost_app()
    fg_is_term = any(name in fg for name in TERMINAL_APPS)
    now = now_ms()
    idle = system_idle_seconds()
    to_close = []
    for k, st in list(state["key_state"].items()):
        if compute_close(st, fg_is_term, now, idle):
            to_close.append(k)
    for k in to_close:
        remove_pending(k)
        latest.pop(k, None)
        state["key_state"].pop(k, None)

    changed = set(latest.keys()) != set(state["items"].keys())
    state["items"] = latest
    if not latest:
        try:
            if open(PID_FILE).read().strip() == str(os.getpid()):
                os.remove(PID_FILE)
        except Exception:
            pass
        root.destroy()
        return
    if changed:
        render()
    root.after(POLL_MS, tick)


render()
root.after(POLL_MS, tick)
root.mainloop()
PYEOF
exit 0
