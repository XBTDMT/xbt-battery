#!/usr/bin/env python3
"""public-images.py — compose the public-release images from the app's OWN offscreen renders.

    build/sym/Debug/Battery.app/Contents/MacOS/Battery --render-showcase build/showcase
    python3 -I scripts/public-images.py build/showcase <images folder>

The images folder is `public/images` in the development repo and `images` in the public one.

Every UI pixel comes from `--render-showcase` (app/App/RenderHarness/RenderShowcase.swift) or from the shipped
app icon (app/Assets.xcassets/AppIcon.appiconset/icon_1024.png). This script only arranges them: it rounds the
popover's outer corners (the harness paints a square #2a2c31 ground; the real popover is rounded), lays them on a
gradient with a soft shadow, and sets captions in SF Pro. Two things touch the popover's own pixels: the corner
mask (the 12 pt corners become transparent) and a 1 px hairline (white at ~13 % opacity) drawn ON the outermost
pixel ring of each popover, standing in for NSPopover's edge — both are ground, never page content. Beyond that it
draws, edits or resamples no UI content except where a composite says it scales (the social card's popover at
0.68x, the menu-bar sheet's glyphs at 1/2). The app icon and the 8x menu-bar glyphs are copied byte for byte.
Needs Pillow (built and checked with Pillow 12.0.0).
"""
import os
import shutil
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SRC, OUT = sys.argv[1], sys.argv[2]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "app/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
SF = "/System/Library/Fonts/SFNS.ttf"           # SF Pro (variable)
HELV = "/System/Library/Fonts/HelveticaNeue.ttc"

RADIUS = 24        # popover corner, px at 2x (12 pt)
TABS = [("now", "Now"), ("day", "Day"), ("energy", "Energy"), ("health", "Health"),
        ("devices", "Devices"), ("automation", "Automation")]
GLYPHS = [("on-battery", "On battery"), ("charging", "Charging"), ("charged", "Full, on power"),
          ("limit-hold", "Held at your limit"), ("plugged-but-losing", "Plugged in, still draining"),
          ("keep-awake", "Keep awake on"), ("low", "Low battery"), ("low-power-mode", "Low Power Mode")]


def font(size, weight=400):
    try:
        f = ImageFont.truetype(SF, size)
        axes = f.get_variation_axes()
        vals = []
        for a in axes:
            name = a["name"].decode() if isinstance(a["name"], bytes) else a["name"]
            vals.append({"Weight": weight, "Optical Size": min(max(size / 2, a["minimum"]), a["maximum"])}
                        .get(name, a["default"]))
        f.set_variation_by_axes(vals)
        return f
    except OSError:
        return ImageFont.truetype(HELV, size, index=1 if weight >= 600 else 0)


def src(name):
    return Image.open(os.path.join(SRC, name)).convert("RGBA")


def rounded(im, r=RADIUS, edge=True):
    """The popover's outer shape: round the corners of the square render and draw the dark-popover hairline."""
    mask = Image.new("L", (im.width * 4, im.height * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, mask.width - 1, mask.height - 1), r * 4, fill=255)
    mask = mask.resize(im.size, Image.LANCZOS)
    out = im.copy()
    out.putalpha(ImageChops.multiply(im.getchannel("A"), mask))
    if edge:
        line = Image.new("RGBA", (im.width * 4, im.height * 4), (0, 0, 0, 0))
        ImageDraw.Draw(line).rounded_rectangle((2, 2, line.width - 3, line.height - 3), r * 4,
                                               outline=(255, 255, 255, 34), width=4)
        out = Image.alpha_composite(out, line.resize(im.size, Image.LANCZOS))
    return out


def gradient(w, h, top=(28, 32, 40), bottom=(10, 11, 14), glow=None):
    """A vertical gradient, optionally with a soft radial glow (cx, cy, radius, rgb, alpha)."""
    base = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        base.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    bg = base.resize((w, h), Image.BICUBIC).convert("RGBA")
    if glow:
        cx, cy, rad, rgb, alpha = glow
        g = Image.new("L", (w // 8, h // 8), 0)
        ImageDraw.Draw(g).ellipse(((cx - rad) // 8, (cy - rad) // 8, (cx + rad) // 8, (cy + rad) // 8),
                                  fill=alpha)
        g = g.filter(ImageFilter.GaussianBlur(rad // 24)).resize((w, h), Image.BICUBIC)
        bg = Image.composite(Image.new("RGBA", (w, h), rgb + (255,)), bg, g)
    return bg


def drop(canvas, im, x, y, blur=36, dy=22, alpha=150):
    """Paste `im` (RGBA) at (x, y) with a soft shadow under it."""
    pad = blur * 3
    sh = Image.new("L", (im.width + 2 * pad, im.height + 2 * pad), 0)
    sh.paste(im.getchannel("A").point(lambda a: a * alpha // 255), (pad, pad))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new("RGBA", sh.size, (0, 0, 0, 0))
    shadow.putalpha(sh)
    canvas.alpha_composite(shadow, (x - pad, y - pad + dy))
    canvas.alpha_composite(im, (x, y))


def save(im, name):
    path = os.path.join(OUT, name)
    im.save(path, optimize=True)
    print(f"{path}\t{im.width}x{im.height}")


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.join(OUT, "menubar"), exist_ok=True)

    # 1. the six tabs, each as its popover (rounded corners, transparent outside), plus the wireless-only Devices.
    pops = {}
    for key, _ in TABS:
        pops[key] = rounded(src(f"tab-{key}.png"))
        save(pops[key], f"popover-{key}.png")
    pops["devices-wireless"] = rounded(src("tab-devices-wireless.png"))
    save(pops["devices-wireless"], "popover-devices-wireless.png")
    save(rounded(src("tab-devices-on-power.png")), "popover-devices-on-power.png")

    # 2. hero: Day · Now · Automation on a dark gradient, the centre one raised. All three come from ONE fixture
    #    graph (`.showcase`), so their numbers agree.
    W, H = 2560, 1360
    order = ["day", "now", "automation"]
    gap = 80
    x0 = (W - 3 * 720 - 2 * gap) // 2
    hero = gradient(W, H, top=(30, 34, 43), bottom=(9, 10, 13), glow=(W // 2, H // 2, 760, (48, 209, 88), 34))
    for i, key in enumerate(order):
        y = 112 if key == "now" else 176
        if key == "now":
            continue
        drop(hero, pops[key], x0 + i * (720 + gap), y)
    drop(hero, pops["now"], x0 + 720 + gap, 112, blur=44, dy=28, alpha=190)
    save(hero.convert("RGB"), "hero.png")

    # 3. social card, 1200 x 675: icon + name + one line, and the Now popover bleeding off the bottom edge.
    CW, CH = 1200, 675
    card = gradient(CW, CH, top=(30, 34, 43), bottom=(9, 10, 13), glow=(860, 300, 420, (48, 209, 88), 40))
    # 0.68 puts the card's bottom edge in the empty band between the controls card and the closing line,
    # so the bleed never cuts through a control.
    scale = 0.68
    pop = src("tab-now.png").resize((round(720 * scale), round(1050 * scale)), Image.LANCZOS)
    pop = rounded(pop, r=round(RADIUS * scale))
    drop(card, pop, CW - pop.width - 64, 64, blur=24, dy=14, alpha=170)
    icon = Image.open(ICON).convert("RGBA").resize((112, 112), Image.LANCZOS)
    card.alpha_composite(icon, (72, 150))
    d = ImageDraw.Draw(card)
    d.text((70, 286), "Battery", font=font(104, 700), fill=(245, 245, 247))
    y = 418
    for line in ["Charge limits, power draw", "and battery health, right", "in your Mac’s menu bar."]:
        d.text((74, y), line, font=font(36, 500), fill=(196, 199, 206))
        y += 46
    save(card.convert("RGB"), "social-card-1200x675.png")

    # 4. the gallery: all six tabs in rail order, three across and two down, each labelled. Every tile is a
    #    `.showcase` render (Devices is the wireless-only page), so the six share one fixture and their numbers agree.
    gap, m, label_h = 56, 96, 120
    cell_h = 1050 + label_h
    GW = 3 * 720 + 2 * gap + 2 * m
    GH = m + 2 * cell_h + gap + 48
    strip = gradient(GW, GH, top=(30, 34, 43), bottom=(9, 10, 13))
    d = ImageDraw.Draw(strip)
    f = font(44, 600)
    for i, (key, label) in enumerate(TABS):
        x = m + (i % 3) * (720 + gap)
        y = m + (i // 3) * (cell_h + gap)
        drop(strip, pops["devices-wireless" if key == "devices" else key], x, y, blur=28, dy=16, alpha=150)
        tw = d.textlength(label, font=f)
        d.text((x + (720 - tw) / 2, y + 1050 + 52), label, font=f, fill=(214, 216, 222))
    save(strip.convert("RGB"), "tab-gallery.png")

    # 5. the menu-bar glyph: every state, light and dark, as the 8x renders (copied) and one labelled sheet (4x).
    rows = []
    for key, label in GLYPHS:
        pair = []
        for mode in ("light", "dark"):
            name = f"glyph-{key}-{mode}.png"
            shutil.copyfile(os.path.join(SRC, name), os.path.join(OUT, "menubar", name))
            print(f"{os.path.join(OUT, 'menubar', name)}\t{Image.open(os.path.join(SRC, name)).size}")
            g = src(name)
            pair.append(g.resize((g.width // 2, g.height // 2), Image.LANCZOS))
        rows.append((label, pair))
    colw = max(p.width for _, pair in rows for p in pair)
    rowh = rows[0][1][0].height
    lab_w, gx, gy, m = 560, 40, 22, 72
    head = 92
    SW = m + lab_w + 2 * colw + gx + m
    SH = m + head + len(rows) * (rowh + gy) - gy + m
    # a mid-grey ground, so the light AND the dark menu-bar strips both read as strips
    sheet = gradient(SW, SH, top=(64, 66, 73), bottom=(48, 50, 56))
    d = ImageDraw.Draw(sheet)
    fh, fl = font(34, 600), font(38, 500)
    for j, mode in enumerate(("Light menu bar", "Dark menu bar")):
        d.text((m + lab_w + j * (colw + gx), m), mode, font=fh, fill=(160, 164, 172))
    for i, (label, pair) in enumerate(rows):
        y = m + head + i * (rowh + gy)
        d.text((m, y + rowh / 2), label, font=fl, fill=(230, 231, 235), anchor="lm")
        for j, g in enumerate(pair):
            cell = rounded(g.crop((0, 0, colw, rowh)) if g.width >= colw else pad_to(g, colw), r=18, edge=False)
            sheet.alpha_composite(cell, (m + lab_w + j * (colw + gx), y))
    save(sheet.convert("RGB"), "menubar-states.png")

    # 6. the plug-in notice and the app icon, as shipped.
    notice = src("hud-device-notice.png")
    save(notice, "plug-in-notice.png")
    shutil.copyfile(ICON, os.path.join(OUT, "app-icon-1024.png"))   # byte for byte, never re-encoded
    print(f"{os.path.join(OUT, 'app-icon-1024.png')}\t{Image.open(ICON).size}")


def pad_to(g, w):
    """Extend a glyph strip to `w` with its own ground colour (sampled from its left edge)."""
    out = Image.new("RGBA", (w, g.height), g.getpixel((2, g.height // 2)))
    out.paste(g, (0, 0))
    return out


if __name__ == "__main__":
    main()
