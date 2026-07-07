"""產生 README 用的示意圖(hero banner 與多實例 demo 圖)。

與 _make_default_image.py 相同,這支腳本只在「製作 plugin 時」執行一次,
不是執行期的一部分。輸出到 assets/。
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path(__file__).resolve().parents[1] / "assets"

GOLD = "#F0A500"
DARK_TEXT = "#5A3E00"
SUB_TEXT = "#7A5A1E"

# 三張 demo 卡片各用不同色相,模擬 auto-images 的「每個 CLI 一張圖」
CARD_HUES = [
    ("#F0A500", "#FFEEBA", "#5A3E00"),  # 琥珀
    ("#2E9E6B", "#D9F2E4", "#0F4D30"),  # 綠
    ("#4A7BD0", "#DEE8FB", "#1D3A6E"),  # 藍
]


def _load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        r"C:\Windows\Fonts\msjh.ttc",
        r"C:\Windows\Fonts\msyh.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def _draw_bell(draw: ImageDraw.ImageDraw, cx: float, cy: float,
               scale: float, color: str) -> None:
    s = scale
    body_w = 96 * s
    body_h = 96 * s
    left = cx - body_w / 2
    right = cx + body_w / 2
    top = cy - body_h / 2
    bottom = cy + body_h / 2

    knob_r = 9 * s
    draw.ellipse([cx - knob_r, top - knob_r * 1.6, cx + knob_r, top + knob_r * 0.4],
                 fill=color)
    draw.polygon(
        [
            (cx - 20 * s, top),
            (cx + 20 * s, top),
            (right, bottom - 22 * s),
            (right + 8 * s, bottom - 6 * s),
            (left - 8 * s, bottom - 6 * s),
            (left, bottom - 22 * s),
        ],
        fill=color,
    )
    draw.ellipse([cx - 20 * s, top - 14 * s, cx + 20 * s, top + 14 * s], fill=color)
    clapper_r = 11 * s
    draw.ellipse([cx - clapper_r, bottom - 2 * s, cx + clapper_r,
                  bottom + clapper_r * 1.8], fill=color)


def _lerp_color(c1: tuple, c2: tuple, t: float) -> tuple:
    return tuple(int(a * (1 - t) + b * t) for a, b in zip(c1, c2))


def _hex_rgb(h: str) -> tuple:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _draw_alert_card(img: Image.Image, x: int, y: int, size: int,
                     hue: tuple[str, str, str], number: int) -> None:
    """在 img 的 (x, y) 畫一張 size×size 的提醒卡片。"""
    accent, bg_top_hex, text_color = hue
    card = Image.new("RGB", (size, size), "#FFFFFF")
    d = ImageDraw.Draw(card)
    bg_top = _hex_rgb(bg_top_hex)
    white = (255, 255, 255)
    for yy in range(size):
        d.line([(0, yy), (size, yy)], fill=_lerp_color(bg_top, white, yy / size))
    d.rounded_rectangle([3, 3, size - 3, size - 3], radius=int(size * 0.09),
                        outline=accent, width=max(2, size // 80))
    _draw_bell(d, cx=size / 2, cy=size * 0.37, scale=size / 320, color=accent)
    d.text((size / 2, size * 0.70), "輪到你了", font=_load_font(int(size * 0.125)),
           anchor="mm", fill=text_color)
    d.text((size / 2, size * 0.84), f"CLI #{number}", font=_load_font(int(size * 0.08)),
           anchor="mm", fill=text_color)

    # 陰影
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([x + 4, y + 6, x + size + 4, y + size + 6],
                         radius=int(size * 0.09), fill=(0, 0, 0, 70))
    img.paste(Image.alpha_composite(img.convert("RGBA"), shadow).convert("RGB"), (0, 0))
    img.paste(card, (x, y))


def _draw_cursor(draw: ImageDraw.ImageDraw, x: int, y: int, scale: float = 1.0) -> None:
    """畫一個滑鼠游標箭頭,尖端在 (x, y)。"""
    s = scale
    pts = [
        (x, y), (x, y + 34 * s), (x + 8 * s, y + 26 * s),
        (x + 14 * s, y + 40 * s), (x + 19 * s, y + 37 * s),
        (x + 13 * s, y + 24 * s), (x + 24 * s, y + 24 * s),
    ]
    draw.polygon(pts, fill="#FFFFFF", outline="#222222")


def make_demo() -> None:
    """桌面右下角三張彈窗的示意圖。"""
    W, H = 960, 500
    img = Image.new("RGB", (W, H), "#1B2735")
    d = ImageDraw.Draw(img)

    # 桌面漸層背景
    top = _hex_rgb("#22304A")
    bottom = _hex_rgb("#101722")
    for yy in range(H):
        d.line([(0, yy), (W, yy)], fill=_lerp_color(top, bottom, yy / H))

    # 模擬三個終端機視窗(左上,示意多個 Claude Code 在跑)
    term_font = _load_font(15)
    for i, (tx, ty) in enumerate([(40, 40), (90, 90), (140, 140)]):
        tw, th = 400, 180
        d.rounded_rectangle([tx, ty, tx + tw, ty + th], radius=8,
                            fill="#0C0C0C", outline="#3A4A63", width=1)
        d.rounded_rectangle([tx, ty, tx + tw, ty + 26], radius=8, fill="#1F2A3C")
        d.rectangle([tx, ty + 13, tx + tw, ty + 26], fill="#1F2A3C")
        d.text((tx + 12, ty + 13), f"Claude Code — CLI #{i + 1}",
               font=term_font, anchor="lm", fill="#9FB3D1")
        d.text((tx + 14, ty + 44), "> claude", font=term_font, fill="#7CE38B")
        d.text((tx + 14, ty + 68), "* Working..." if i == 2 else "● Done. Waiting for you",
               font=term_font, fill="#E8C15A" if i == 2 else "#8FD0FF")

    # 工作列
    d.rectangle([0, H - 36, W, H], fill="#0B1018")

    # 右下角三張提醒卡片(自適應網格:3 張一排)
    card, gap, margin = 150, 12, 20
    total_w = card * 3 + gap * 2
    x0 = W - margin - total_w
    y0 = H - 36 - margin - card
    for i, hue in enumerate(CARD_HUES):
        _draw_alert_card(img, x0 + i * (card + gap), y0, card, hue, i + 1)

    d = ImageDraw.Draw(img)

    # 游標點在第二張卡片上 + 說明文字
    cx = x0 + card + gap + card // 2
    _draw_cursor(d, cx, y0 + card // 2 + 10)
    label_font = _load_font(20)
    d.text((x0 + total_w // 2, y0 - 46), "每個 CLI 一張圖 · 點圖即切回該 CLI",
           font=label_font, anchor="mm", fill="#FFFFFF")
    # 箭頭
    ax = x0 + total_w // 2
    d.line([(ax, y0 - 30), (ax, y0 - 10)], fill="#FFFFFF", width=2)
    d.polygon([(ax - 5, y0 - 14), (ax + 5, y0 - 14), (ax, y0 - 4)], fill="#FFFFFF")

    out = ASSETS / "demo-multi.png"
    img.save(out, "PNG")
    print(f"已生成:{out}  ({img.size[0]}x{img.size[1]})")


def make_hero() -> None:
    """README 頂部 banner。"""
    W, H = 960, 280
    img = Image.new("RGB", (W, H), "#FFFFFF")
    d = ImageDraw.Draw(img)
    top = _hex_rgb("#FFEEBA")
    white = (255, 255, 255)
    for yy in range(H):
        d.line([(0, yy), (W, yy)], fill=_lerp_color(top, white, yy / H))
    d.rounded_rectangle([6, 6, W - 6, H - 6], radius=24, outline=GOLD, width=4)

    _draw_bell(d, cx=150, cy=H / 2 - 10, scale=1.15, color=GOLD)
    d.text((150, H / 2 + 88), "輪到你了", font=_load_font(30), anchor="mm",
           fill=DARK_TEXT)

    d.text((280, 86), "my-turn-alert", font=_load_font(52), fill=DARK_TEXT)
    d.text((283, 158), "Claude Code 跑完了、卡住了、在等你 — 彈圖提醒,點圖切回去",
           font=_load_font(22), fill=SUB_TEXT)
    d.text((283, 198), "Visual popup alerts when any Claude Code CLI needs a human.",
           font=_load_font(19), fill=SUB_TEXT)

    out = ASSETS / "hero.png"
    img.save(out, "PNG")
    print(f"已生成:{out}  ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    ASSETS.mkdir(parents=True, exist_ok=True)
    make_hero()
    make_demo()
