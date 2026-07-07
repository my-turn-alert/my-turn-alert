"""產生 plugin 內建的預設提醒圖 assets/default-alert.png。

這支腳本只在「製作 plugin 時」執行一次來生成圖片，不是執行期的一部分。
使用者若要換成自己的圖，放 ~/.claude/alert-image.png 即可，不需動到這裡。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZE = 320
OUT = Path(__file__).resolve().parents[1] / "assets" / "default-alert.png"


def _load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """盡量找一個含中文字形的字型，找不到就退回預設點陣字型。"""
    candidates = [
        r"C:\Windows\Fonts\msjh.ttc",      # 微軟正黑體（Windows，含中文）
        r"C:\Windows\Fonts\msyh.ttc",      # 微軟雅黑
        "/System/Library/Fonts/PingFang.ttc",  # macOS 蘋方
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def _draw_bell(draw: "ImageDraw.ImageDraw", cx: float, cy: float, scale: float = 1.0) -> None:
    """用向量繪製一個鈴鐺圖示，置中於 (cx, cy)。"""
    gold = "#F0A500"
    s = scale

    # 鈴身：上窄下寬的吊鐘形，用一個圓角矩形 + 頂部小圓近似
    body_w = 96 * s
    body_h = 96 * s
    left = cx - body_w / 2
    right = cx + body_w / 2
    top = cy - body_h / 2
    bottom = cy + body_h / 2

    # 頂部把手（小圓）
    knob_r = 9 * s
    draw.ellipse(
        [cx - knob_r, top - knob_r * 1.6, cx + knob_r, top + knob_r * 0.4],
        fill=gold,
    )

    # 鐘體（圓角梯形以多邊形近似）
    draw.polygon(
        [
            (cx - 20 * s, top),            # 頂部左
            (cx + 20 * s, top),            # 頂部右
            (right, bottom - 22 * s),      # 右下擴張
            (right + 8 * s, bottom - 6 * s),
            (left - 8 * s, bottom - 6 * s),
            (left, bottom - 22 * s),       # 左下擴張
        ],
        fill=gold,
    )
    # 把頂部修圓
    draw.ellipse([cx - 20 * s, top - 14 * s, cx + 20 * s, top + 14 * s], fill=gold)

    # 鐘下緣的小擺錘
    clapper_r = 11 * s
    draw.ellipse(
        [cx - clapper_r, bottom - 2 * s, cx + clapper_r, bottom + clapper_r * 1.8],
        fill=gold,
    )


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)

    # 漸層背景（柔和的琥珀→白），給人「提醒」但不刺眼的感覺
    img = Image.new("RGB", (SIZE, SIZE), "#FFFFFF")
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / SIZE
        r = int(255 * (1 - t) + 255 * t)
        g = int(238 * (1 - t) + 255 * t)
        b = int(186 * (1 - t) + 255 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))

    # 圓角外框
    draw.rounded_rectangle(
        [6, 6, SIZE - 6, SIZE - 6], radius=28, outline="#F0A500", width=4
    )

    # 用向量畫一個鈴鐺（不依賴 emoji 字型，跨平台都能正確顯示）
    _draw_bell(draw, cx=SIZE / 2, cy=118, scale=1.0)

    # 提示文字（中 + 英）
    draw.text((SIZE / 2, 222), "輪到你了", font=_load_font(40), anchor="mm",
              fill="#5A3E00")
    draw.text((SIZE / 2, 268), "Claude needs you", font=_load_font(24),
              anchor="mm", fill="#7A5A1E")

    img.save(OUT, "PNG")
    print(f"已生成：{OUT}  ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()
