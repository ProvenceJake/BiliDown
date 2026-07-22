#!/usr/bin/env python3
from __future__ import annotations

import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "Support"
ICONSET = SUPPORT / "AppIcon.iconset"
ICNS = SUPPORT / "AppIcon.icns"
PREVIEW = SUPPORT / "AppIcon.png"


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def mix(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(lerp(a, b, t) for a, b in zip(c1, c2))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def add_shadow(base: Image.Image, mask: Image.Image, offset: tuple[int, int], blur: int, alpha: int) -> None:
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shadow_alpha = mask.filter(ImageFilter.GaussianBlur(blur))
    shadow_alpha = shadow_alpha.point(lambda value: int(value * alpha / 255))
    shadow.putalpha(shadow_alpha)
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    layer.alpha_composite(shadow, offset)
    base.alpha_composite(layer)


def triangle_points(cx: int, cy: int, width: int, height: int) -> list[tuple[int, int]]:
    return [
        (cx - width // 3, cy - height // 2),
        (cx - width // 3, cy + height // 2),
        (cx + width // 2, cy),
    ]


def make_master(size: int = 1024, scale: int = 4) -> Image.Image:
    s = scale
    canvas_size = size * s
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    pad = 76 * s
    icon_box = (pad, pad, canvas_size - pad, canvas_size - pad)
    radius = 210 * s
    body_mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(body_mask).rounded_rectangle(icon_box, radius=radius, fill=255)

    add_shadow(img, body_mask, (0, 20 * s), 44 * s, 70)
    add_shadow(img, body_mask, (0, 6 * s), 12 * s, 45)

    top = (21, 205, 232)
    mid = (79, 110, 247)
    bottom = (128, 79, 225)
    gradient = Image.new("RGBA", img.size, (0, 0, 0, 0))
    pixels = gradient.load()
    for y in range(canvas_size):
        for x in range(canvas_size):
            t = (x * 0.58 + y * 0.42) / canvas_size
            color = mix(top, mid, min(1.0, t * 1.25)) if t < 0.65 else mix(mid, bottom, (t - 0.65) / 0.35)
            pixels[x, y] = (*color, 255)
    gradient.putalpha(body_mask)
    img.alpha_composite(gradient)

    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(
        (168 * s, 192 * s, 856 * s, 616 * s),
        radius=84 * s,
        fill=(255, 255, 255, 230),
        outline=(255, 255, 255, 105),
        width=4 * s,
    )
    draw.rounded_rectangle(
        (202 * s, 232 * s, 822 * s, 326 * s),
        radius=48 * s,
        fill=(13, 157, 217, 42),
    )
    for i, color in enumerate([(242, 97, 119, 240), (255, 194, 92, 240), (74, 197, 151, 240)]):
        cx = (258 + i * 58) * s
        draw.ellipse((cx - 16 * s, 278 * s - 16 * s, cx + 16 * s, 278 * s + 16 * s), fill=color)

    play_shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    play_draw = ImageDraw.Draw(play_shadow)
    play_draw.polygon(triangle_points(512 * s + 7 * s, 446 * s + 12 * s, 190 * s, 220 * s), fill=(0, 0, 0, 42))
    play_shadow = play_shadow.filter(ImageFilter.GaussianBlur(5 * s))
    img.alpha_composite(play_shadow)
    draw = ImageDraw.Draw(img)
    draw.polygon(triangle_points(512 * s, 446 * s, 190 * s, 220 * s), fill=(42, 101, 238, 255))

    badge_mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(badge_mask).ellipse((306 * s, 538 * s, 718 * s, 950 * s), fill=255)
    add_shadow(img, badge_mask, (0, 12 * s), 28 * s, 72)
    draw = ImageDraw.Draw(img)
    draw.ellipse((306 * s, 538 * s, 718 * s, 950 * s), fill=(255, 92, 116, 255))
    draw.ellipse((354 * s, 586 * s, 670 * s, 902 * s), fill=(255, 255, 255, 42))

    arrow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    ad.rounded_rectangle((476 * s, 604 * s, 548 * s, 770 * s), radius=36 * s, fill=(255, 255, 255, 255))
    ad.polygon(
        [
            (396 * s, 742 * s),
            (628 * s, 742 * s),
            (512 * s, 868 * s),
        ],
        fill=(255, 255, 255, 255),
    )
    ad.rounded_rectangle((378 * s, 846 * s, 646 * s, 900 * s), radius=27 * s, fill=(255, 255, 255, 255))
    arrow_shadow = arrow.copy()
    arrow_shadow.putalpha(arrow.getchannel("A").filter(ImageFilter.GaussianBlur(4 * s)).point(lambda v: math.floor(v * 0.22)))
    img.alpha_composite(arrow_shadow, (0, 6 * s))
    img.alpha_composite(arrow)

    highlight = Image.new("RGBA", img.size, (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.rounded_rectangle((154 * s, 112 * s, 734 * s, 226 * s), radius=56 * s, fill=(255, 255, 255, 38))
    highlight.putalpha(highlight.getchannel("A").filter(ImageFilter.GaussianBlur(14 * s)))
    img.alpha_composite(highlight)

    return img.resize((size, size), Image.Resampling.LANCZOS)


def save_iconset(master: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for filename, pixels in sizes:
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(ICONSET / filename)
    master.save(PREVIEW)
    subprocess.run(["iconutil", "-c", "icns", "-o", str(ICNS), str(ICONSET)], check=True)


def main() -> None:
    SUPPORT.mkdir(parents=True, exist_ok=True)
    save_iconset(make_master())
    print(ICNS)
    print(PREVIEW)


if __name__ == "__main__":
    main()
