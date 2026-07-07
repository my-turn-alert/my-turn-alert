"""gen_auto_images.py — 在 OutDir 內生成 001.png..100.png（macOS/Linux 路徑）。

設計原則同 gen-auto-images.ps1：
- 寫入位置由呼叫端指定，本檔不自行解析使用者目錄。
- 同 process 一次生 100 張；idempotent（已存在不覆蓋）。
- 優先 PIL；無 PIL 時退回 Tkinter PhotoImage 寫 GIF。
"""
from __future__ import annotations

import colorsys
import os
import sys


def _color(i: int, s: float = 0.35, v: float = 0.95) -> tuple[int, int, int]:
    h = ((i - 1) * 3.6) / 360.0
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return int(r * 255), int(g * 255), int(b * 255)


def _try_pillow(out_dir: str) -> bool:
    try:
        from PIL import Image, ImageDraw, ImageFont
    except Exception:
        return False
    size = 320
    font = None
    for path in (
        r"C:\Windows\Fonts\segoeuib.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        try:
            font = ImageFont.truetype(path, 140)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()
    for i in range(1, 101):
        name = f"{i:03d}.png"
        path = os.path.join(out_dir, name)
        if os.path.exists(path):
            continue
        bg = _color(i, 0.35, 0.95)
        fg = _color(i, 0.85, 0.35)
        img = Image.new("RGB", (size, size), bg)
        draw = ImageDraw.Draw(img)
        draw.rectangle((8, 8, size - 8, size - 8), outline=fg, width=6)
        text = str(i)
        try:
            bbox = draw.textbbox((0, 0), text, font=font)
            w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
            draw.text(((size - w) / 2 - bbox[0], (size - h) / 2 - bbox[1]),
                      text, fill=fg, font=font)
        except Exception:
            draw.text((size / 2, size / 2), text, fill=fg, font=font, anchor="mm")
        tmp = path + ".tmp"
        img.save(tmp, "PNG")
        os.replace(tmp, path)
    return True


def _try_tk(out_dir: str) -> bool:
    try:
        import tkinter as tk
    except Exception:
        return False
    size = 320
    root = tk.Tk()
    root.withdraw()
    for i in range(1, 101):
        name = f"{i:03d}.gif"  # tk.PhotoImage 只能寫 GIF/PPM
        path = os.path.join(out_dir, name)
        if os.path.exists(path):
            continue
        bg = _color(i)
        photo = tk.PhotoImage(width=size, height=size)
        photo.put(f"#{bg[0]:02x}{bg[1]:02x}{bg[2]:02x}", to=(0, 0, size, size))
        tmp = path + ".tmp"
        photo.write(tmp, format="gif")
        os.replace(tmp, path)
    root.destroy()
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_auto_images.py <out-dir>", file=sys.stderr)
        return 2
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    if _try_pillow(out_dir):
        return 0
    if _try_tk(out_dir):
        return 0
    print("no image library available; auto-gen skipped", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
