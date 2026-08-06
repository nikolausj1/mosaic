#!/usr/bin/env python3
"""
Mosaic App Store screenshots v2 - spanning / continuous-panorama style.
Builds one 6600x2868 canvas and slices it into five 1320x2868 panels.
"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ---------------------------------------------------------------- paths
REPO = "/Users/justinnikolaus/Library/CloudStorage/Dropbox/_Projects/Photo Collage"
SCRATCH = "/private/tmp/claude-501/-Users-justinnikolaus-Library-CloudStorage-Dropbox--Projects-Photo-Collage/f141c70c-60fb-4e8a-ac4d-057c0d712685/scratchpad"
OUT_DIR = f"{REPO}/_store/screenshots-v2"

SRC = {
    "selected": f"{SCRATCH}/sc-selected.png",
    "editor2":  f"{SCRATCH}/sc-editor2.png",
    "border":   f"{SCRATCH}/sc-border.png",
    "save":     f"{SCRATCH}/sc-save.png",
}
BORDER_TRIMMED_PATH = f"{SCRATCH}/sc-border-trimmed.png"
LOCKUP_PATH = f"{REPO}/Sources/Resources/Assets.xcassets/Lockup.imageset/lockup.png"
FONT_PATH = "/System/Library/Fonts/SFNS.ttf"

# ---------------------------------------------------------------- canvas geometry
PANEL_W = 1320
PANEL_H = 2868
N_PANELS = 5
W = PANEL_W * N_PANELS   # 6600
H = PANEL_H              # 2868

# ---------------------------------------------------------------- brand
NEAR_BLACK = (11, 11, 13)
TEXT_LIGHT = (242, 242, 244)
ACCENT_LIGHT = (113, 191, 255)   # #71BFFF
ACCENT_DEEP = (31, 107, 232)     # #1F6BE8

def font(weight, size):
    f = ImageFont.truetype(FONT_PATH, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f

# ---------------------------------------------------------------- source prep
def make_trimmed_border_shot():
    """The Border-tab screenshot carries two long runs of dead flat
    background (verified programmatically as uniform #0B0B0D across the
    full width): y 368-645 between the header and the collage, and
    y 1798-2075 between the collage and the thickness/radius/swatch
    controls. Both are removed so that, once the phone is tilted and
    placed, the COLOR SWATCHES stay inside the frame - without them the
    panel's own headline ("Colors sampled straight from your shot")
    points at something the viewer cannot see. Only empty background is
    removed; every control keeps its size, order and spacing, and both
    cut edges sit well inside a verified flat run so the joins are
    invisible."""
    im = Image.open(SRC["border"]).convert("RGBA")
    keep = [(0, 380), (640, 1810), (2062, im.height)]
    parts = [im.crop((0, a, im.width, b)) for a, b in keep]
    out = Image.new("RGBA", (im.width, sum(p.height for p in parts)))
    y = 0
    for p in parts:
        out.paste(p, (0, y)); y += p.height
    out.save(BORDER_TRIMMED_PATH)
    return BORDER_TRIMMED_PATH


# ---------------------------------------------------------------- background
def build_background():
    """Deep, restrained gradient across the full 6600-wide canvas.
    Near-black base, a soft accent glow rising from the lower-right,
    and a faint cool glow near the upper-left (behind the text panel)."""
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)

    base = np.array(NEAR_BLACK, dtype=np.float32)
    deep = np.array((14, 22, 40), dtype=np.float32)     # subtle deep-navy lift
    glow_deep = np.array(ACCENT_DEEP, dtype=np.float32)
    glow_light = np.array(ACCENT_LIGHT, dtype=np.float32)

    # 1) gentle diagonal lift, near-black -> deep navy, top-left to bottom-right
    diag = (xs / W) * 0.55 + (ys / H) * 0.45
    diag = np.clip(diag, 0, 1)
    img = base[None, None, :] + (deep - base)[None, None, :] * diag[:, :, None]

    # 2) big soft glow anchored below/right of center, restrained strength
    gx, gy = W * 0.78, H * 1.05
    d = np.sqrt(((xs - gx) / (W * 0.62)) ** 2 + ((ys - gy) / (H * 0.62)) ** 2)
    glow = np.clip(1.0 - d, 0, 1) ** 2.2 * 0.40
    img = img + glow_deep[None, None, :] * glow[:, :, None]

    # 3) faint cool highlight upper-left, behind the opening text panel
    gx2, gy2 = W * 0.06, H * 0.18
    d2 = np.sqrt(((xs - gx2) / (W * 0.30)) ** 2 + ((ys - gy2) / (H * 0.55)) ** 2)
    glow2 = np.clip(1.0 - d2, 0, 1) ** 2.6 * 0.10
    img = img + glow_light[None, None, :] * glow2[:, :, None]

    img = np.clip(img, 0, 255).astype(np.uint8)
    return Image.fromarray(img, mode="RGB").convert("RGBA")


def add_grain(im, amount=4):
    """Very light film grain so the gradient doesn't band."""
    arr = np.array(im).astype(np.int16)
    noise = np.random.default_rng(7).integers(-amount, amount + 1, arr.shape[:2])
    for c in range(3):
        arr[:, :, c] = np.clip(arr[:, :, c] + noise, 0, 255)
    return Image.fromarray(arr.astype(np.uint8), mode=im.mode)


def rounded_square(size, color, radius_ratio=0.22):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=color)
    return im


def add_tile_motif(bg):
    """Sparing geometric accents echoing the icon's staircase-of-squares
    tile mark. Large, translucent, kept low in the frame so they never
    compete with headlines (which all live in the top band)."""
    bg = bg.copy()
    tiles = [
        # (cx, cy, size, color, alpha, angle)
        (W * 0.045, H * 0.78, 620, ACCENT_DEEP, 20, -6),
        (W * 0.115, H * 0.92, 440, ACCENT_LIGHT, 14, -6),
        (W * 0.955, H * 0.88, 640, ACCENT_DEEP, 18, 9),
        (W * 0.890, H * 1.02, 420, ACCENT_LIGHT, 13, 9),
    ]
    for cx, cy, size, color, alpha, angle in tiles:
        sq = rounded_square(size, color + (255,))
        sq = sq.rotate(angle, resample=Image.BICUBIC, expand=True)
        r, g, b, a = sq.split()
        a = a.point(lambda v: int(v * (alpha / 255)))
        sq.putalpha(a)
        bg.alpha_composite(sq, (int(cx - sq.width / 2), int(cy - sq.height / 2)))
    return bg


# ---------------------------------------------------------------- device mockup
def round_corners(im, radius):
    mask = Image.new("L", im.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, im.size[0] - 1, im.size[1] - 1], radius=radius, fill=255)
    out = im.copy()
    out.putalpha(mask)
    return out


def make_device(shot_path, corner_radius=44, bezel=14, bezel_color=(28, 28, 32, 255)):
    """Round the screenshot corners, add a thin bezel ring, return an
    RGBA image slightly larger than the screenshot (bezel included)."""
    shot = Image.open(shot_path).convert("RGBA")
    shot_r = round_corners(shot, corner_radius)

    w, h = shot.size
    plate_w, plate_h = w + bezel * 2, h + bezel * 2
    plate = Image.new("RGBA", (plate_w, plate_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(plate)
    d.rounded_rectangle([0, 0, plate_w - 1, plate_h - 1],
                         radius=corner_radius + bezel, fill=bezel_color)
    # faint edge highlight
    d.rounded_rectangle([0, 0, plate_w - 1, plate_h - 1],
                         radius=corner_radius + bezel, outline=(90, 100, 115, 160), width=2)
    plate.alpha_composite(shot_r, (bezel, bezel))
    return plate


def drop_shadow_for(size, blur=60, offset=(0, 50), alpha=140):
    w, h = size
    pad = blur * 3
    shadow = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(shadow)
    d.rounded_rectangle([pad, pad, pad + w, pad + h], radius=90, fill=(0, 0, 0, alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    return shadow, pad, offset


def rotated_bbox(w, h, angle_deg):
    a = math.radians(angle_deg)
    new_w = abs(w * math.cos(a)) + abs(h * math.sin(a))
    new_h = abs(w * math.sin(a)) + abs(h * math.cos(a))
    return new_w, new_h


def composite_device(canvas, shot_path, cx, angle, scale=1.0, top=None, cy=None):
    """Build device plate, rotate, add shadow, composite onto canvas.
    Horizontal placement is by center-x (cx). Vertical placement is
    either an explicit center-y (cy) or, preferably, a `top` (the
    rotated bounding box's top edge) so every device can share the
    same clear-of-headline start line."""
    plate = make_device(shot_path)
    if scale != 1.0:
        plate = plate.resize((int(plate.width * scale), int(plate.height * scale)),
                              Image.LANCZOS)

    rotated = plate.rotate(angle, resample=Image.BICUBIC, expand=True)

    if cy is None:
        cy = top + rotated.height / 2

    shadow, pad, offset = drop_shadow_for(rotated.size, blur=55, offset=(0, 60), alpha=130)
    shadow_pos = (int(cx - shadow.width / 2 + offset[0]),
                  int(cy - shadow.height / 2 + offset[1]))
    canvas.alpha_composite(shadow, shadow_pos)

    dev_pos = (int(cx - rotated.width / 2), int(cy - rotated.height / 2))
    canvas.alpha_composite(rotated, dev_pos)
    return dev_pos, rotated.size


# ---------------------------------------------------------------- text helpers
def draw_text_wrapped(draw, xy, text, fnt, fill, max_width, line_spacing=1.12,
                       align="left", anchor_x="left"):
    """Simple greedy word-wrap; returns bottom y after drawing."""
    words = text.split(" ")
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=fnt) <= max_width or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)

    x, y = xy
    asc, desc = fnt.getmetrics()
    line_h = int((asc + desc) * line_spacing)
    for line in lines:
        lw = draw.textlength(line, font=fnt)
        if align == "center":
            draw_x = x - lw / 2
        elif align == "right":
            draw_x = x - lw
        else:
            draw_x = x
        draw.text((draw_x, y), line, font=fnt, fill=fill)
        y += line_h
    return y


# ---------------------------------------------------------------- build
def main():
    import os
    os.makedirs(OUT_DIR, exist_ok=True)

    border_shot_path = make_trimmed_border_shot()

    bg = build_background()
    bg = add_tile_motif(bg)
    bg = add_grain(bg, amount=3)

    canvas = bg.convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    f_headline = font("Bold", 92)
    f_sub = font("Regular", 46)
    f_promise = font("Semibold", 108)
    f_promise_sub = font("Regular", 50)

    PAD = 96          # inner text padding from a panel's own edges
    SEAM_CLEAR = 90   # extra clearance text must keep from a seam
    BOTTOM_CLEAR = 220

    def panel_left(i):
        return i * PANEL_W

    # ---------- Panel 1: text-only opener ----------
    p0 = panel_left(0)
    lockup = Image.open(LOCKUP_PATH).convert("RGBA")
    lockup_w = 620
    lockup_h = int(lockup.height * (lockup_w / lockup.width))
    lockup_r = lockup.resize((lockup_w, lockup_h), Image.LANCZOS)
    lockup_x = p0 + (PANEL_W - lockup_w) // 2
    lockup_y = 980
    canvas.alpha_composite(lockup_r, (lockup_x, lockup_y))

    # "Auto layout that finds faces" - Justin, 2026-08-06: THE headline from
    # now on (also the App Store subtitle). Replaced "Your photos.\nSide by
    # side." - the selling points are auto layout, face finding, fully
    # adjustable, and the old line said none of them.
    headline1 = "Auto layout\nthat finds faces."
    y = lockup_y + lockup_h + 90
    for line in headline1.split("\n"):
        lw = draw.textlength(line, font=f_promise)
        draw.text((p0 + PANEL_W / 2 - lw / 2, y), line, font=f_promise, fill=TEXT_LIGHT)
        asc, desc = f_promise.getmetrics()
        y += int((asc + desc) * 1.08)

    y += 28
    sub1 = "Two to four photos. One frame."
    lw = draw.textlength(sub1, font=f_promise_sub)
    draw.text((p0 + PANEL_W / 2 - lw / 2, y), sub1, font=f_promise_sub, fill=(200, 205, 214, 255))

    # ---------- Devices + copy for panels 2-5 ----------
    # Consistent tilt for all devices (one steady angle, not alternating).
    # All four share the same "top" line, clear of the headline block;
    # drawn left-to-right so each phone's seam bleed is gently
    # overlapped by its right-hand neighbour, like a fanned deck of
    # cards flowing across the spread. The "reshape" phone is centered
    # on the panel2/panel3 seam so it visibly straddles the cut.
    ANGLE = -9
    DEVICE_TOP = 640

    # (source, headline, subhead, center_x, scale, text_panel)
    devices = [
        dict(src=SRC["selected"],
             headline="Pick 2 to 4.\nIt does the rest.",
             sub="Auto-framing on arrival, no fiddly cropping.",
             cx=panel_left(1) + PANEL_W * 0.62, scale=1.00,
             text_panel=1),
        dict(src=SRC["editor2"],
             headline="Reshape it\nyour way.",
             sub="Drag any seam. Pull any corner.",
             cx=panel_left(2) + PANEL_W * 0.78, scale=1.02,
             text_panel=2),
        dict(src=border_shot_path,
             headline="Borders, from\nyour own photos.",
             sub="Colors sampled straight from your shot.",
             cx=panel_left(3) + PANEL_W * 0.58, scale=0.98,
             text_panel=3),
        dict(src=SRC["save"],
             headline="Full resolution.\nAlways.",
             # Was "Saved under the date the photos were taken." - that
             # described the OLD S7 filing behavior. Saves now land at the
             # top of the library (export-time creation date); the source
             # photos' date/location lives in the file's own EXIF.
             sub="Lands right at the top of your library.",
             cx=panel_left(4) + PANEL_W * 0.50, scale=0.98,
             text_panel=4),
    ]

    for dev in devices:
        composite_device(canvas, dev["src"], dev["cx"], ANGLE, dev["scale"], top=DEVICE_TOP)

    # headline/subhead text, drawn after all devices so text stays crisp
    for dev in devices:
        i = dev["text_panel"]
        px = panel_left(i)
        text_x = px + PAD
        max_w = PANEL_W - PAD - SEAM_CLEAR
        y = 210
        for line in dev["headline"].split("\n"):
            draw.text((text_x, y), line, font=f_headline, fill=TEXT_LIGHT)
            asc, desc = f_headline.getmetrics()
            y += int((asc + desc) * 1.10)
        y += 18
        draw_text_wrapped(draw, (text_x, y), dev["sub"], f_sub, (205, 210, 218, 255), max_w)

    # ---------- slice + save ----------
    canvas_rgb = canvas.convert("RGB")
    banner_path = f"{OUT_DIR}/_banner-full.png"
    canvas_rgb.save(banner_path)

    panel_paths = []
    for i in range(N_PANELS):
        left = i * PANEL_W
        panel = canvas_rgb.crop((left, 0, left + PANEL_W, H))
        assert panel.size == (PANEL_W, PANEL_H), panel.size
        path = f"{OUT_DIR}/{i+1:02d}.png"
        panel.save(path)
        panel_paths.append(path)

    print("Saved:", banner_path)
    for p in panel_paths:
        print("Saved:", p)

    # ---------- continuity check ----------
    arr = np.array(canvas_rgb)
    print("\nContinuity check (adjacent columns across each seam):")
    for i in range(1, N_PANELS):
        seam_x = i * PANEL_W
        left_col = arr[:, seam_x - 1, :].astype(np.int16)
        right_col = arr[:, seam_x, :].astype(np.int16)
        diff = np.abs(left_col - right_col)
        print(f"  seam {i} (x={seam_x}): mean abs diff = {diff.mean():.3f}, "
              f"max abs diff = {diff.max()}")


if __name__ == "__main__":
    main()
