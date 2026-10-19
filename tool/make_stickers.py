"""Genera todos los stickers de KLK (assets/stickers/<id>.png, 512×512).

Uso: python3 tool/make_stickers.py   (necesita Pillow y la fuente Inter Display Black)
Estilo: borde blanco troquelado, sombra suave, letras con degradado y relieve,
caritas tipo emoji e iconos dibujados a mano. No usa imágenes de terceros.
La lista de stickers tiene que coincidir con lib/features/messaging/stickers.dart.
"""
import hashlib
import math
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "stickers")
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-Black.otf"
C = 1024  # lienzo de trabajo; se reduce a 512
FINAL = 512
INK = (24, 20, 46, 255)
WHITE = (255, 255, 255, 255)

PAL = {
    "red": ((255, 92, 104), (206, 17, 38)),
    "blue": ((84, 140, 255), (0, 45, 98)),
    "yellow": ((255, 233, 110), (255, 166, 0)),
    "green": ((74, 230, 150), (16, 140, 86)),
    "purple": ((190, 120, 255), (106, 44, 145)),
    "orange": ((255, 190, 90), (255, 96, 0)),
    "teal": ((90, 232, 236), (0, 150, 170)),
    "pink": ((255, 150, 205), (232, 24, 109)),
    "brown": ((214, 150, 96), (122, 66, 30)),
    "night": ((170, 185, 255), (70, 80, 190)),
}


def font(size):
    return ImageFont.truetype(FONT, size)


def grad(size, top, bottom):
    """Degradado vertical RGBA."""
    w, h = size
    g = Image.linear_gradient("L").resize((max(1, w), max(1, h)))
    a = Image.new("RGBA", (w, h), top + (255,) if len(top) == 3 else top)
    b = Image.new("RGBA", (w, h), bottom + (255,) if len(bottom) == 3 else bottom)
    return Image.composite(b, a, g)


def paste_grad(layer, mask, top, bottom):
    """Pinta `mask` (L) con un degradado sobre `layer`."""
    bbox = mask.getbbox()
    if not bbox:
        return
    x0, y0, x1, y1 = bbox
    g = grad((x1 - x0, y1 - y0), top, bottom)
    full = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    full.paste(g, (x0, y0))
    layer.alpha_composite(Image.composite(full, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask))


def shape_mask(draw_fn):
    m = Image.new("L", (C, C), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def ink_outline(layer, mask, width):
    """Contorno oscuro alrededor de una forma."""
    grown = mask.filter(ImageFilter.MaxFilter(width * 2 + 1)) if width < 12 else _dilate(mask, width)
    ring = Image.new("RGBA", layer.size, INK)
    layer.alpha_composite(Image.composite(ring, Image.new("RGBA", layer.size, (0, 0, 0, 0)), grown))


def _dilate(mask, r):
    b = mask.filter(ImageFilter.GaussianBlur(r * 0.6))
    return b.point(lambda v: 255 if v > 6 else 0).filter(ImageFilter.GaussianBlur(1.2))


def filled(layer, draw_fn, top, bottom, outline=14):
    m = shape_mask(draw_fn)
    if outline:
        ink_outline(layer, m, outline)
    paste_grad(layer, m, top, bottom)
    return m


def shine(layer, box, alpha=90):
    hl = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse(box, fill=(255, 255, 255, alpha))
    layer.alpha_composite(hl.filter(ImageFilter.GaussianBlur(6)))


# ---------- Caritas ----------

def face(layer, cx, cy, r, kind):
    d = ImageDraw.Draw(layer)
    angry = kind == "angry"
    top, bottom = ((255, 120, 90), (220, 30, 40)) if angry else ((255, 226, 92), (255, 168, 20))
    if kind == "party":
        hat = [(cx - r * 0.55, cy - r * 0.78), (cx + r * 0.05, cy - r * 1.75), (cx + r * 0.45, cy - r * 0.86)]
        filled(layer, lambda m: m.polygon(hat, fill=255), (190, 120, 255), (106, 44, 145))
        d.ellipse((cx - r * 0.06, cy - r * 1.95, cx + r * 0.2, cy - r * 1.68), fill=(255, 205, 40, 255), outline=INK, width=8)
    if kind == "pray":
        d.ellipse((cx - r * 0.75, cy - r * 1.42, cx + r * 0.75, cy - r * 1.0), outline=INK, width=26)
        d.ellipse((cx - r * 0.75, cy - r * 1.42, cx + r * 0.75, cy - r * 1.0), outline=(255, 214, 60, 255), width=14)
    filled(layer, lambda m: m.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255), top, bottom, outline=16)
    shine(layer, (cx - r * 0.65, cy - r * 0.85, cx + r * 0.1, cy - r * 0.35), 110)
    e = r * 0.36  # separación de ojos
    ey = cy - r * 0.18
    lw = int(r * 0.11)

    def dot_eyes(size=0.13):
        for s in (-1, 1):
            d.ellipse((cx + s * e - r * size, ey - r * size * 1.4, cx + s * e + r * size, ey + r * size * 1.4), fill=INK)

    def happy_eyes():
        for s in (-1, 1):
            d.arc((cx + s * e - r * 0.2, ey - r * 0.12, cx + s * e + r * 0.2, ey + r * 0.26), 200, 340, fill=INK, width=lw)

    def smile(w=0.55, h=0.45, y=0.12):
        d.arc((cx - r * w, cy - r * (h - y) , cx + r * w, cy + r * (h + y)), 20, 160, fill=INK, width=lw)

    def open_mouth(w=0.5, top=0.18, bottom=0.72):
        box = (cx - r * w, cy + r * top - r * 0.35, cx + r * w, cy + r * bottom)
        d.chord(box, 0, 180, fill=INK)
        d.chord((cx - r * w * 0.6, cy + r * bottom - r * 0.32, cx + r * w * 0.6, cy + r * bottom + r * 0.1), 180, 360, fill=(240, 80, 100, 255))

    if kind == "laugh":
        for s in (-1, 1):  # ojos cerrados ><
            x = cx + s * e
            d.line((x - s * r * 0.16, ey - r * 0.14, x + s * r * 0.12, ey), fill=INK, width=lw)
            d.line((x + s * r * 0.12, ey, x - s * r * 0.16, ey + r * 0.14), fill=INK, width=lw)
        open_mouth(0.55, 0.22, 0.75)
        for s in (-1, 1):  # lágrimas de risa
            tx = cx + s * r * 0.92
            drop = [(tx, ey - r * 0.05), (tx + s * r * 0.22, ey + r * 0.32), (tx - s * r * 0.02, ey + r * 0.38)]
            filled(layer, lambda m, p=drop: m.polygon(p, fill=255), (150, 225, 255), (40, 150, 255), outline=8)
    elif kind == "shock":
        for s in (-1, 1):
            x = cx + s * e
            d.ellipse((x - r * 0.2, ey - r * 0.26, x + r * 0.2, ey + r * 0.22), fill=WHITE, outline=INK, width=lw - 4)
            d.ellipse((x - r * 0.08, ey - r * 0.1, x + r * 0.08, ey + r * 0.08), fill=INK)
        d.ellipse((cx - r * 0.2, cy + r * 0.25, cx + r * 0.2, cy + r * 0.7), fill=INK)
        drop = [(cx + r * 0.78, cy - r * 0.78), (cx + r * 0.98, cy - r * 0.38), (cx + r * 0.62, cy - r * 0.38)]
        filled(layer, lambda m: (m.polygon(drop, fill=255), m.ellipse((cx + r * 0.6, cy - r * 0.55, cx + r * 1.0, cy - r * 0.2), fill=255)),
               (150, 225, 255), (40, 150, 255), outline=8)
    elif kind == "cool":
        for s in (-1, 1):
            x = cx + s * e
            d.rounded_rectangle((x - r * 0.33, ey - r * 0.2, x + r * 0.3, ey + r * 0.2), radius=int(r * 0.12), fill=INK)
            d.line((x - r * 0.2, ey - r * 0.1, x - r * 0.05, ey - r * 0.1), fill=(120, 130, 170, 255), width=8)
        d.line((cx - e + r * 0.3, ey - r * 0.12, cx + e - r * 0.33, ey - r * 0.12), fill=INK, width=lw)
        d.arc((cx - r * 0.45, cy + r * 0.0, cx + r * 0.55, cy + r * 0.62), 25, 120, fill=INK, width=lw)
    elif kind == "love":
        for s in (-1, 1):
            heart(layer, cx + s * e, ey + r * 0.02, r * 0.27, outline=6)
        open_mouth(0.42, 0.25, 0.68)
    elif kind == "angry":
        for s in (-1, 1):
            x = cx + s * e
            d.line((x - s * r * 0.25, ey - r * 0.32, x + s * r * 0.18, ey - r * 0.12), fill=INK, width=lw)
        dot_eyes(0.11)
        d.arc((cx - r * 0.4, cy + r * 0.35, cx + r * 0.4, cy + r * 0.85), 200, 340, fill=INK, width=lw)
    elif kind == "wink":
        d.ellipse((cx - e - r * 0.12, ey - r * 0.17, cx - e + r * 0.12, ey + r * 0.17), fill=INK)
        d.arc((cx + e - r * 0.2, ey - r * 0.1, cx + e + r * 0.2, ey + r * 0.2), 200, 340, fill=INK, width=lw)
        smile(0.5, 0.4, 0.15)
        d.chord((cx + r * 0.05, cy + r * 0.38, cx + r * 0.38, cy + r * 0.78), 0, 180, fill=(240, 80, 100, 255), outline=INK, width=8)
    elif kind == "pray":
        happy_eyes()
        smile(0.42, 0.35, 0.2)
        for s in (-1, 1):
            d.ellipse((cx + s * r * 0.62 - r * 0.14, cy + r * 0.12, cx + s * r * 0.62 + r * 0.14, cy + r * 0.3), fill=(255, 130, 120, 160))
    elif kind == "cry":
        for s in (-1, 1):
            x = cx + s * e
            d.arc((x - r * 0.2, ey - r * 0.05, x + r * 0.2, ey + r * 0.3), 200, 340, fill=INK, width=lw)
            stream = (x - r * 0.08, ey + r * 0.12, x + r * 0.08, cy + r * 0.95)
            filled(layer, lambda m, b=stream: m.rounded_rectangle(b, radius=int(r * 0.08), fill=255), (160, 230, 255), (40, 150, 255), outline=6)
        d.arc((cx - r * 0.35, cy + r * 0.35, cx + r * 0.35, cy + r * 0.8), 200, 340, fill=INK, width=lw)
    elif kind == "sweat":
        dot_eyes(0.11)
        open_mouth(0.4, 0.3, 0.7)
        for k in (0, 1):
            x = cx + r * (0.7 + k * 0.25)
            y = cy - r * (0.75 - k * 0.45)
            drop = [(x, y - r * 0.2), (x + r * 0.13, y + r * 0.05), (x - r * 0.13, y + r * 0.05)]
            filled(layer, lambda m, p=drop, x=x, y=y: (m.polygon(p, fill=255), m.ellipse((x - r * 0.13, y - r * 0.05, x + r * 0.13, y + r * 0.18), fill=255)),
                   (160, 230, 255), (40, 150, 255), outline=6)
    elif kind == "meh":
        for s in (-1, 1):
            x = cx + s * e
            d.chord((x - r * 0.2, ey - r * 0.2, x + r * 0.2, ey + r * 0.2), 0, 180, fill=INK)
            d.line((x - r * 0.24, ey, x + r * 0.24, ey), fill=INK, width=lw)
        d.line((cx - r * 0.3, cy + r * 0.5, cx + r * 0.3, cy + r * 0.45), fill=INK, width=lw)
        d.line((cx + e - r * 0.25, ey - r * 0.42, cx + e + r * 0.2, ey - r * 0.5), fill=INK, width=lw)
    elif kind == "party":
        happy_eyes()
        open_mouth(0.48, 0.2, 0.7)
    elif kind == "sleep":
        for s in (-1, 1):
            d.arc((cx + s * e - r * 0.2, ey - r * 0.2, cx + s * e + r * 0.2, ey + r * 0.15), 20, 160, fill=INK, width=lw)
        d.ellipse((cx - r * 0.12, cy + r * 0.38, cx + r * 0.12, cy + r * 0.62), fill=INK)
        f = font(int(r * 0.6))
        d.text((cx + r * 0.75, cy - r * 1.3), "z", font=f, fill=WHITE, stroke_width=10, stroke_fill=INK)
        d.text((cx + r * 1.05, cy - r * 1.75), "z", font=font(int(r * 0.42)), fill=WHITE, stroke_width=8, stroke_fill=INK)
    elif kind == "think":
        d.ellipse((cx - e - r * 0.12, ey - r * 0.3, cx - e + r * 0.12, ey + r * 0.02), fill=INK)
        d.ellipse((cx + e - r * 0.12, ey - r * 0.3, cx + e + r * 0.12, ey + r * 0.02), fill=INK)
        d.line((cx - r * 0.25, cy + r * 0.5, cx + r * 0.35, cy + r * 0.4), fill=INK, width=lw)
        d.line((cx - e - r * 0.2, ey - r * 0.5, cx - e + r * 0.2, ey - r * 0.42), fill=INK, width=lw)


# ---------- Iconos ----------

def heart(layer, cx, cy, r, top=(255, 110, 140), bottom=(220, 20, 60), outline=12):
    def shp(m):
        m.ellipse((cx - r, cy - r * 0.75, cx + r * 0.05, cy + r * 0.25), fill=255)
        m.ellipse((cx - r * 0.05, cy - r * 0.75, cx + r, cy + r * 0.25), fill=255)
        m.polygon([(cx - r * 0.97, cy - r * 0.12), (cx + r * 0.97, cy - r * 0.12), (cx, cy + r * 0.95)], fill=255)
    filled(layer, shp, top, bottom, outline=outline)
    shine(layer, (cx - r * 0.75, cy - r * 0.6, cx - r * 0.3, cy - r * 0.2), 120)


def sparkle(layer, cx, cy, r, color=(255, 222, 60)):
    pts = []
    for i in range(8):
        a = math.radians(-90 + i * 45)
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    filled(layer, lambda m: m.polygon(pts, fill=255), (255, 250, 200), color, outline=8)


def star(layer, cx, cy, r):
    pts = []
    for i in range(10):
        a = math.radians(-90 + i * 36)
        rr = r if i % 2 == 0 else r * 0.45
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    filled(layer, lambda m: m.polygon(pts, fill=255), (255, 240, 120), (255, 170, 0), outline=10)


def fire(layer, cx, cy, r):
    def flame(m, s=1.0, dy=0.0):
        pts = []
        for i in range(60):
            t = i / 59 * 2 * math.pi
            x = math.sin(t) * (0.62 + 0.1 * math.sin(3 * t))
            y = -math.cos(t) * 0.95 + (0.25 if math.cos(t) > 0 else -0.08)
            if math.cos(t) > 0.6:
                x *= 0.55
            pts.append((cx + x * r * s, cy + (y + dy) * r * s))
        m.polygon(pts, fill=255)
    filled(layer, flame, (255, 214, 60), (235, 40, 20), outline=12)
    filled(layer, lambda m: flame(m, 0.55, 0.45), (255, 250, 200), (255, 180, 30), outline=0)


def bulb(layer, cx, cy, r, on=True):
    if on:
        d = ImageDraw.Draw(layer)
        for i in range(8):
            a = math.radians(-180 + i * 25.7)
            d.line((cx + r * 1.15 * math.cos(a), cy - r * 0.2 + r * 1.15 * math.sin(a),
                    cx + r * 1.5 * math.cos(a), cy - r * 0.2 + r * 1.5 * math.sin(a)), fill=INK, width=22)
            d.line((cx + r * 1.15 * math.cos(a), cy - r * 0.2 + r * 1.15 * math.sin(a),
                    cx + r * 1.5 * math.cos(a), cy - r * 0.2 + r * 1.5 * math.sin(a)), fill=(255, 214, 60, 255), width=10)
    top, bottom = ((255, 250, 170), (255, 190, 20)) if on else ((150, 160, 190), (70, 80, 110))
    filled(layer, lambda m: (m.ellipse((cx - r, cy - r * 1.2, cx + r, cy + r * 0.6), fill=255),
                             m.rectangle((cx - r * 0.45, cy + r * 0.2, cx + r * 0.45, cy + r * 0.8), fill=255)), top, bottom)
    filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.5, cy + r * 0.75, cx + r * 0.5, cy + r * 1.25), radius=int(r * 0.15), fill=255),
           (200, 205, 220), (120, 125, 145), outline=10)
    shine(layer, (cx - r * 0.65, cy - r * 0.95, cx - r * 0.15, cy - r * 0.35), 130)


def baseball(layer, cx, cy, r):
    filled(layer, lambda m: m.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255), (255, 255, 255), (220, 222, 230))
    d = ImageDraw.Draw(layer)
    red = (220, 30, 50, 255)
    for s in (-1, 1):
        box = (cx + s * r * 1.35 - r, cy - r, cx + s * r * 1.35 + r, cy + r)
        start, end = (125, 235) if s == 1 else (-55, 55)
        d.arc(box, start, end, fill=red, width=10)
        for t in range(-2, 3):
            a = math.radians((start + end) / 2 + t * 20)
            x = cx + s * r * 1.35 + r * math.cos(a)
            y = cy + r * math.sin(a)
            d.line((x - 12, y - 8, x + 12, y + 8), fill=red, width=7)


def plate(layer, cx, cy, r, food="mangu"):
    filled(layer, lambda m: m.ellipse((cx - r * 1.2, cy - r * 0.5, cx + r * 1.2, cy + r * 0.6), fill=255), (255, 255, 255), (210, 214, 225))
    if food == "mangu":
        filled(layer, lambda m: m.ellipse((cx - r * 0.75, cy - r * 0.75, cx + r * 0.55, cy + r * 0.25), fill=255), (255, 236, 160), (230, 190, 80), outline=10)
        for i in range(3):
            filled(layer, lambda m, i=i: m.ellipse((cx - r * 0.55 + i * r * 0.32, cy - r * 0.95, cx - r * 0.15 + i * r * 0.32, cy - r * 0.6), fill=255),
                   (200, 110, 255), (120, 40, 160), outline=8)
        filled(layer, lambda m: m.ellipse((cx + r * 0.3, cy - r * 0.35, cx + r * 0.95, cy + r * 0.2), fill=255), (255, 255, 255), (240, 240, 240), outline=8)
        filled(layer, lambda m: m.ellipse((cx + r * 0.5, cy - r * 0.22, cx + r * 0.75, cy + r * 0.05), fill=255), (255, 220, 60), (255, 160, 0), outline=0)
        filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.95, cy - r * 0.1, cx - r * 0.25, cy + r * 0.25), radius=20, fill=255), (255, 150, 120), (200, 60, 40), outline=8)
    else:  # caldero de sancocho / habichuelas
        col = ((255, 200, 90), (220, 120, 20)) if food == "sancocho" else ((180, 110, 70), (110, 50, 30))
        filled(layer, lambda m: m.ellipse((cx - r * 0.95, cy - r * 0.55, cx + r * 0.95, cy + r * 0.15), fill=255), col[0], col[1], outline=10)
        d = ImageDraw.Draw(layer)
        for i in range(3):
            x = cx - r * 0.5 + i * r * 0.5
            d.arc((x - r * 0.15, cy - r * 1.3, x + r * 0.15, cy - r * 0.75), 90, 270, fill=(255, 255, 255, 200), width=12)


def cup(layer, cx, cy, r, top=(255, 255, 255), bottom=(220, 222, 230), drink=(120, 66, 30)):
    filled(layer, lambda m: m.ellipse((cx + r * 0.55, cy - r * 0.45, cx + r * 1.15, cy + r * 0.35), fill=255), top, bottom, outline=12)
    ImageDraw.Draw(layer).ellipse((cx + r * 0.72, cy - r * 0.28, cx + r * 0.98, cy + r * 0.18), fill=(0, 0, 0, 0))
    filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.8, cy - r * 0.75, cx + r * 0.8, cy + r * 0.85), radius=int(r * 0.3), fill=255), top, bottom)
    filled(layer, lambda m: m.ellipse((cx - r * 0.7, cy - r * 0.85, cx + r * 0.7, cy - r * 0.55), fill=255), tuple(min(255, c + 60) for c in drink), drink, outline=8)
    d = ImageDraw.Draw(layer)
    for i in range(2):
        x = cx - r * 0.25 + i * r * 0.5
        d.arc((x - r * 0.15, cy - r * 1.55, x + r * 0.15, cy - r * 0.95), 90, 270, fill=INK, width=14)


def bottle(layer, cx, cy, r):
    filled(layer, lambda m: (m.rounded_rectangle((cx - r * 0.45, cy - r * 0.4, cx + r * 0.45, cy + r * 1.1), radius=int(r * 0.2), fill=255),
                             m.polygon([(cx - r * 0.45, cy - r * 0.3), (cx - r * 0.16, cy - r * 0.9), (cx + r * 0.16, cy - r * 0.9), (cx + r * 0.45, cy - r * 0.3)], fill=255),
                             m.rectangle((cx - r * 0.16, cy - r * 1.3, cx + r * 0.16, cy - r * 0.85), fill=255)),
           (255, 210, 120), (190, 110, 20))
    filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.45, cy + r * 0.05, cx + r * 0.45, cy + r * 0.6), radius=8, fill=255), (255, 255, 255), (230, 235, 245), outline=8)
    ImageDraw.Draw(layer).rectangle((cx - r * 0.18, cy + r * 0.2, cx + r * 0.18, cy + r * 0.45), fill=(206, 17, 38, 255))
    shine(layer, (cx - r * 0.35, cy - r * 0.3, cx - r * 0.12, cy + r * 0.0), 140)
    d = ImageDraw.Draw(layer)
    for i, (dx, dy) in enumerate(((-0.75, -0.6), (0.72, -0.2), (0.8, 0.6))):
        d.ellipse((cx + r * dx - 14, cy + r * dy - 14, cx + r * dx + 14, cy + r * dy + 14), fill=(160, 220, 255, 255), outline=INK, width=5)


def sun(layer, cx, cy, r):
    pts = []
    for i in range(24):
        a = math.radians(i * 15)
        rr = r * 1.3 if i % 2 == 0 else r * 0.95
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    filled(layer, lambda m: m.polygon(pts, fill=255), (255, 214, 60), (255, 120, 0), outline=10)
    filled(layer, lambda m: m.ellipse((cx - r * 0.8, cy - r * 0.8, cx + r * 0.8, cy + r * 0.8), fill=255), (255, 240, 120), (255, 170, 0), outline=10)


def palm(layer, cx, cy, r):
    trunk = [(cx - r * 0.1, cy - r * 0.6), (cx + r * 0.1, cy - r * 0.6), (cx + r * 0.35, cy + r * 1.2), (cx + r * 0.05, cy + r * 1.2)]
    filled(layer, lambda m: m.polygon(trunk, fill=255), (220, 160, 90), (150, 90, 40), outline=10)
    for a in (-160, -120, -60, -20, -90):
        ang = math.radians(a)
        ex, ey = cx + r * 1.1 * math.cos(ang), cy - r * 0.6 + r * 0.9 * math.sin(ang) + r * 0.25
        mx, my = (cx + ex) / 2, (cy - r * 0.6 + ey) / 2 - r * 0.25
        leaf = [(cx, cy - r * 0.6), (mx - 30, my), (ex, ey), (mx + 30, my + 40)]
        filled(layer, lambda m, p=leaf: m.polygon(p, fill=255), (90, 230, 140), (20, 140, 70), outline=10)
    for dx in (-0.12, 0.12):
        filled(layer, lambda m, dx=dx: m.ellipse((cx + r * dx - 22, cy - r * 0.55, cx + r * dx + 22, cy - r * 0.55 + 44), fill=255), (170, 110, 60), (110, 60, 20), outline=6)


def notes(layer, cx, cy, r):
    def shp(m):
        for dx, k in ((-0.45, 1.0), (0.45, 0.9)):
            x = cx + r * dx
            m.ellipse((x - r * 0.35 * k, cy + r * 0.45, x + r * 0.15 * k, cy + r * 0.85), fill=255)
            m.rectangle((x + r * 0.03 * k, cy - r * 0.7, x + r * 0.15 * k, cy + r * 0.68), fill=255)
        m.polygon([(cx - r * 0.42, cy - r * 0.7), (cx + r * 0.58, cy - r * 0.95), (cx + r * 0.58, cy - r * 0.68), (cx - r * 0.42, cy - r * 0.43)], fill=255)
    filled(layer, shp, (200, 140, 255), (106, 44, 145), outline=12)


def guira(layer, cx, cy, r):
    filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.38, cy - r, cx + r * 0.38, cy + r * 0.8), radius=int(r * 0.38), fill=255), (235, 238, 245), (150, 155, 175))
    d = ImageDraw.Draw(layer)
    for row in range(7):
        for col in range(3):
            x = cx - r * 0.2 + col * r * 0.2
            y = cy - r * 0.75 + row * r * 0.23
            d.ellipse((x - 6, y - 6, x + 6, y + 6), fill=INK)
    filled(layer, lambda m: m.rounded_rectangle((cx - 14, cy + r * 0.75, cx + 14, cy + r * 1.2), radius=10, fill=255), (120, 80, 40), (80, 40, 10), outline=8)


def drum(layer, cx, cy, r):
    filled(layer, lambda m: m.rounded_rectangle((cx - r, cy - r * 0.45, cx + r, cy + r * 0.55), radius=30, fill=255), (240, 150, 60), (180, 80, 10))
    for s in (-1, 1):
        filled(layer, lambda m, s=s: m.ellipse((cx + s * r - r * 0.22, cy - r * 0.7, cx + s * r + r * 0.22, cy + r * 0.8), fill=255), (255, 250, 235), (225, 215, 190), outline=10)
    d = ImageDraw.Draw(layer)
    for i in range(5):
        x = cx - r * 0.6 + i * r * 0.3
        d.line((x, cy - r * 0.4, x + r * 0.15, cy + r * 0.5), fill=INK, width=6)


def tree(layer, cx, cy, r):
    filled(layer, lambda m: m.rectangle((cx - r * 0.15, cy + r * 0.6, cx + r * 0.15, cy + r * 1.05), fill=255), (170, 110, 60), (110, 60, 20), outline=10)
    for i, k in enumerate((1.0, 0.8, 0.58)):
        top = cy - r * 0.95 + i * r * 0.45
        tri = [(cx, top), (cx - r * k, top + r * 0.8), (cx + r * k, top + r * 0.8)]
        filled(layer, lambda m, p=tri: m.polygon(p, fill=255), (90, 230, 140), (20, 130, 70), outline=12)
    star(layer, cx, cy - r * 1.0, r * 0.28)
    for (x, y, col) in ((-0.4, 0.05, (255, 80, 100)), (0.35, 0.35, (80, 200, 255)), (-0.1, 0.55, (255, 200, 40)), (0.2, -0.2, (255, 255, 255))):
        filled(layer, lambda m, x=x, y=y: m.ellipse((cx + r * x - 20, cy + r * y - 20, cx + r * x + 20, cy + r * y + 20), fill=255), col, col, outline=6)


def gift(layer, cx, cy, r):
    filled(layer, lambda m: m.rectangle((cx - r * 0.9, cy - r * 0.4, cx + r * 0.9, cy + r), fill=255), (255, 110, 120), (200, 20, 40))
    filled(layer, lambda m: m.rectangle((cx - r, cy - r * 0.75, cx + r, cy - r * 0.35), fill=255), (255, 130, 140), (210, 30, 50))
    filled(layer, lambda m: m.rectangle((cx - r * 0.15, cy - r * 0.75, cx + r * 0.15, cy + r), fill=255), (255, 240, 120), (255, 180, 0), outline=8)
    d = ImageDraw.Draw(layer)
    for s in (-1, 1):
        d.ellipse((cx + s * r * 0.05 - (r * 0.6 if s < 0 else 0), cy - r * 1.2, cx + s * r * 0.05 + (r * 0.6 if s > 0 else 0), cy - r * 0.75), outline=INK, width=26)
        d.ellipse((cx + s * r * 0.05 - (r * 0.6 if s < 0 else 0), cy - r * 1.2, cx + s * r * 0.05 + (r * 0.6 if s > 0 else 0), cy - r * 0.75), outline=(255, 200, 30, 255), width=12)


def cake(layer, cx, cy, r):
    filled(layer, lambda m: m.rounded_rectangle((cx - r, cy - r * 0.1, cx + r, cy + r * 0.85), radius=30, fill=255), (255, 245, 235), (240, 215, 200))
    filled(layer, lambda m: m.rounded_rectangle((cx - r * 0.75, cy - r * 0.65, cx + r * 0.75, cy - r * 0.05), radius=24, fill=255), (255, 200, 225), (240, 120, 170))
    d = ImageDraw.Draw(layer)
    for i in range(-1, 2):
        x = cx + i * r * 0.4
        d.rectangle((x - 10, cy - r * 1.05, x + 10, cy - r * 0.65), fill=(80, 200, 255, 255), outline=INK, width=5)
        filled(layer, lambda m, x=x: m.ellipse((x - 16, cy - r * 1.4, x + 16, cy - r * 1.02), fill=255), (255, 240, 120), (255, 120, 0), outline=6)
    for i in range(6):
        x = cx - r * 0.8 + i * r * 0.32
        d.ellipse((x - 12, cy + r * 0.3, x + 12, cy + r * 0.5), fill=(206, 17, 38, 255))


def mask(layer, cx, cy, r, devil=False):
    if devil:
        for s in (-1, 1):
            horn = [(cx + s * r * 0.45, cy - r * 0.45), (cx + s * r * 1.05, cy - r * 1.35), (cx + s * r * 0.9, cy - r * 0.25)]
            filled(layer, lambda m, p=horn: m.polygon(p, fill=255), (255, 240, 200), (230, 200, 150), outline=10)
    top, bottom = ((255, 110, 110), (200, 20, 40)) if devil else ((255, 230, 100), (255, 160, 0))
    filled(layer, lambda m: m.ellipse((cx - r, cy - r * 0.7, cx + r, cy + r * 0.9), fill=255), top, bottom)
    d = ImageDraw.Draw(layer)
    for s in (-1, 1):
        ex = cx + s * r * 0.42
        d.ellipse((ex - r * 0.25, cy - r * 0.2, ex + r * 0.25, cy + r * 0.2), fill=INK)
    d.arc((cx - r * 0.5, cy + r * 0.05, cx + r * 0.5, cy + r * 0.7), 20, 160, fill=INK, width=14)
    for i in range(-2, 3):
        d.ellipse((cx + i * r * 0.32 - 12, cy - r * 0.55 - 12, cx + i * r * 0.32 + 12, cy - r * 0.55 + 12), fill=WHITE, outline=INK, width=4)


def vejiga(layer, cx, cy, r):
    ImageDraw.Draw(layer).line((cx, cy + r * 0.6, cx + r * 0.5, cy + r * 1.2), fill=INK, width=12)
    filled(layer, lambda m: m.ellipse((cx - r * 0.75, cy - r, cx + r * 0.75, cy + r * 0.65), fill=255), (255, 220, 120), (255, 150, 0))
    shine(layer, (cx - r * 0.45, cy - r * 0.7, cx - r * 0.05, cy - r * 0.25), 150)


def balloons(layer, cx, cy, r):
    d = ImageDraw.Draw(layer)
    for dx, dy, col in ((-0.55, 0.0, ((255, 110, 120), (206, 17, 38))), (0.5, -0.2, ((110, 160, 255), (0, 45, 98))),
                        (0.0, -0.55, ((255, 240, 120), (255, 170, 0)))):
        x, y = cx + r * dx, cy + r * dy
        d.line((x, y + r * 0.5, cx, cy + r * 1.15), fill=INK, width=8)
        filled(layer, lambda m, x=x, y=y: m.ellipse((x - r * 0.42, y - r * 0.55, x + r * 0.42, y + r * 0.55), fill=255), col[0], col[1], outline=10)
        shine(layer, (x - r * 0.28, y - r * 0.4, x - r * 0.05, y - r * 0.1), 140)


def crown(layer, cx, cy, r):
    pts = [(cx - r, cy + r * 0.5), (cx - r, cy - r * 0.4), (cx - r * 0.5, cy + r * 0.05), (cx, cy - r * 0.7),
           (cx + r * 0.5, cy + r * 0.05), (cx + r, cy - r * 0.4), (cx + r, cy + r * 0.5)]
    filled(layer, lambda m: m.polygon(pts, fill=255), (255, 240, 120), (255, 160, 0))
    for x, col in ((-0.5, (255, 90, 110)), (0, (90, 200, 255)), (0.5, (120, 230, 150))):
        filled(layer, lambda m, x=x: m.ellipse((cx + r * x - 22, cy + r * 0.12 - 22, cx + r * x + 22, cy + r * 0.12 + 22), fill=255), col, col, outline=6)


def flag(layer, cx, cy, r):
    """Bandera dominicana ondeando (sin escudo)."""
    w, h = r * 2.0, r * 1.35
    x0, y0 = cx - w / 2, cy - h / 2
    pole = (x0 - 22, y0 - 20, x0 - 2, y0 + h * 1.7)
    filled(layer, lambda m: m.rounded_rectangle(pole, radius=10, fill=255), (240, 240, 245), (170, 175, 190), outline=8)

    def wave(px, py):
        return py + math.sin((px - x0) / w * math.pi * 2) * h * 0.06

    def quad(m, a, b, c, dd):
        m.polygon([(a, wave(a, b)), (c, wave(c, b)), (c, wave(c, dd)), (a, wave(a, dd))], fill=255)

    cw, ch = w * 0.44, h * 0.44
    blue, red = ((70, 120, 255), (0, 45, 98)), ((255, 90, 100), (206, 17, 38))
    for (qx, qy, col) in ((0, 0, blue), (1, 1, blue), (1, 0, red), (0, 1, red)):
        ax = x0 + (0 if qx == 0 else w - cw)
        ay = y0 + (0 if qy == 0 else h - ch)
        steps = 6
        def shp(m, ax=ax, ay=ay):
            for k in range(steps):
                quad(m, ax + cw * k / steps, ay, ax + cw * (k + 1) / steps + 1, ay + ch)
        filled(layer, shp, col[0], col[1], outline=0)
    # contorno de la bandera
    m = Image.new("L", (C, C), 0)
    md = ImageDraw.Draw(m)
    for k in range(12):
        quad(md, x0 + w * k / 12, y0, x0 + w * (k + 1) / 12 + 1, y0 + h)
    out = _dilate(m, 12)
    ring = Image.composite(Image.new("RGBA", (C, C), INK), Image.new("RGBA", (C, C), (0, 0, 0, 0)), ImageChops.subtract(out, m))
    layer.alpha_composite(ring)


def clock(layer, cx, cy, r):
    filled(layer, lambda m: m.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255), (255, 255, 255), (220, 225, 235))
    d = ImageDraw.Draw(layer)
    d.line((cx, cy, cx, cy - r * 0.6), fill=INK, width=18)
    d.line((cx, cy, cx + r * 0.45, cy + r * 0.2), fill=(206, 17, 38, 255), width=14)
    d.ellipse((cx - 18, cy - 18, cx + 18, cy + 18), fill=INK)


ICONS = {
    "heart": heart, "fire": fire, "bulb": bulb, "bulb_off": lambda l, x, y, r: bulb(l, x, y, r, on=False),
    "baseball": baseball, "mangu": plate, "sancocho": lambda l, x, y, r: plate(l, x, y, r, "sancocho"),
    "habichuela": lambda l, x, y, r: plate(l, x, y, r, "habichuela"), "coffee": cup,
    "juice": lambda l, x, y, r: cup(l, x, y, r, (255, 255, 255), (220, 222, 230), (255, 150, 40)),
    "bottle": bottle, "sun": sun, "palm": palm, "notes": notes, "guira": guira, "drum": drum, "tree": tree,
    "gift": gift, "cake": cake, "mask": mask, "devil": lambda l, x, y, r: mask(l, x, y, r, True), "vejiga": vejiga,
    "balloons": balloons, "crown": crown, "flag": flag, "clock": clock, "star": star,
}


# ---------- Texto ----------

def fit_font(lines, max_w, max_h):
    size = 300
    while size > 40:
        f = font(size)
        d = ImageDraw.Draw(Image.new("L", (1, 1)))
        w = max(d.textlength(ln, font=f) for ln in lines)
        h = size * 0.98 * len(lines)
        if w <= max_w and h <= max_h:
            return f, size
        size -= 6
    return font(size), size


def word_art(lines, colors, max_w, max_h, pill=False):
    """Devuelve una capa con el texto: degradado + contorno + relieve (o en píldora)."""
    f, size = fit_font(lines, max_w, max_h)
    lh = size * 0.98
    layer = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    mask_ = Image.new("L", (C, C), 0)
    md = ImageDraw.Draw(mask_)
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    total = lh * len(lines)
    y = (C - total) / 2 - size * 0.1
    line_masks = []
    for ln in lines:
        w = probe.textlength(ln, font=f)
        md.text(((C - w) / 2, y), ln, font=f, fill=255)
        lm = Image.new("L", (C, C), 0)
        ImageDraw.Draw(lm).text(((C - w) / 2, y), ln, font=f, fill=255)
        line_masks.append(lm)
        y += lh
    top, bottom = colors
    if pill:
        x0, y0, x1, y1 = mask_.getbbox()
        pad_x, pad_y = size * 0.42, size * 0.28
        box = (x0 - pad_x, y0 - pad_y, x1 + pad_x, y1 + pad_y)
        rad = int(min(box[3] - box[1], 260) * 0.45)
        depth = int(size * 0.09)
        filled(layer, lambda m: m.rounded_rectangle((box[0], box[1] + depth, box[2], box[3] + depth), radius=rad, fill=255), bottom, bottom, outline=14)
        darker = tuple(int(c * 0.55) for c in bottom)
        filled(layer, lambda m: m.rounded_rectangle((box[0], box[1] + depth, box[2], box[3] + depth), radius=rad, fill=255), darker, darker, outline=0)
        filled(layer, lambda m: m.rounded_rectangle(box, radius=rad, fill=255), top, bottom, outline=14)
        shine(layer, (box[0] + rad * 0.4, box[1] + 18, box[0] + (box[2] - box[0]) * 0.55, box[1] + 18 + (box[3] - box[1]) * 0.22), 70)
        sw = max(6, int(size * 0.055))
        shadow = _dilate(mask_, sw)
        sh = ImageChops.offset(shadow, 0, int(size * 0.05))
        layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), INK), Image.new("RGBA", (C, C), (0, 0, 0, 0)), sh))
        layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), INK), Image.new("RGBA", (C, C), (0, 0, 0, 0)), shadow))
        layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), WHITE), Image.new("RGBA", (C, C), (0, 0, 0, 0)), mask_))
        return layer
    sw = max(8, int(size * 0.075))
    outline = _dilate(mask_, sw)
    depth = int(size * 0.11)
    # relieve: el contorno se repite hacia abajo
    for k in range(depth, 0, -3):
        sh = ImageChops.offset(outline, 0, k)
        layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), INK), Image.new("RGBA", (C, C), (0, 0, 0, 0)), sh))
    layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), INK), Image.new("RGBA", (C, C), (0, 0, 0, 0)), outline))
    for lm in line_masks:  # degradado y brillo línea a línea
        paste_grad(layer, lm, top, bottom)
        x0, y0, x1, y1 = lm.getbbox()
        hi = Image.new("L", (C, C), 0)
        ImageDraw.Draw(hi).rectangle((x0, y0, x1, y0 + (y1 - y0) * 0.36), fill=70)
        hi = ImageChops.multiply(hi, lm)
        layer.alpha_composite(Image.composite(Image.new("RGBA", (C, C), WHITE), Image.new("RGBA", (C, C), (0, 0, 0, 0)), hi))
    return layer


# ---------- Montaje ----------

def place(src, dst, cx, cy, scale):
    """Pega `src` (C×C) reducida a `scale` y centrada en (cx, cy)."""
    bbox = src.getbbox()
    if not bbox:
        return
    crop = src.crop(bbox)
    w, h = int(crop.width * scale), int(crop.height * scale)
    crop = crop.resize((max(1, w), max(1, h)), Image.LANCZOS)
    dst.alpha_composite(crop, (int(cx - w / 2), int(cy - h / 2)))


def make(sid, lines, color, face_kind=None, icon=None, pill=False):
    rnd = random.Random(int(hashlib.md5(sid.encode()).hexdigest(), 16))
    colors = PAL[color]
    art = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    has_pic = face_kind or icon
    text = word_art(lines, colors, 900, 520 if has_pic else 760, pill=pill)
    tb = text.getbbox()
    th = tb[3] - tb[1]
    if has_pic:
        pic = Image.new("RGBA", (C, C), (0, 0, 0, 0))
        if face_kind:
            face(pic, C / 2, C / 2, 230, face_kind)
        else:
            ICONS[icon](pic, C / 2, C / 2, 230)
        pb = pic.getbbox()
        ph = pb[3] - pb[1]
        target_ph = min(430, 900 - th * 0.85)
        s = min(1.0, target_ph / ph)
        total = ph * s + th - 60
        top_y = (C - total) / 2
        side = rnd.choice((-1, 1)) if len(max(lines, key=len)) <= 9 else 0
        place(pic, art, C / 2 + side * 120, top_y + ph * s / 2, s)
        place(text, art, C / 2, top_y + ph * s - 60 + th / 2, 1.0)
    else:
        place(text, art, C / 2, C / 2, 1.0)
        for _ in range(3):
            ang = rnd.uniform(0, 2 * math.pi)
            sparkle(art, C / 2 + math.cos(ang) * 430, C / 2 + math.sin(ang) * 330, rnd.uniform(34, 52))
    # inclinación ligera para darle vida
    art = art.rotate(rnd.uniform(-7, 7), resample=Image.BICUBIC, center=(C / 2, C / 2))
    # que quepa con margen para el borde blanco
    bb = art.getbbox()
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    s = min(1.0, (C - 150) / max(w, h))
    fitted = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    place(art, fitted, C / 2, C / 2, s)
    alpha = fitted.split()[3]
    cut = _dilate(alpha, 26)
    shadow = cut.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.32))
    out = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    out.alpha_composite(Image.composite(Image.new("RGBA", (C, C), (10, 10, 30, 255)), Image.new("RGBA", (C, C), (0, 0, 0, 0)),
                                        ImageChops.offset(shadow, 0, 12)))
    out.alpha_composite(Image.composite(Image.new("RGBA", (C, C), WHITE), Image.new("RGBA", (C, C), (0, 0, 0, 0)), cut))
    out.alpha_composite(fitted)
    small = out.resize((FINAL, FINAL), Image.LANCZOS)
    # 256 colores con transparencia: pesa ~3 veces menos y no se nota
    small.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).save(
        os.path.join(OUT, sid + ".png"), optimize=True)


# id, líneas, color, carita, icono, píldora
STICKERS = [
    # Criollos
    ("klk", ["¡Klk!"], "red", "cool", None, False),
    ("quelloque", ["¡Qué lo", "que!"], "blue", "wink", None, False),
    ("dimelo", ["Dímelo"], "yellow", None, None, True),
    ("tato", ["Tá to'"], "green", "cool", None, True),
    ("tamoactivo", ["Tamo'", "activo"], "orange", None, "fire", False),
    ("vamoarriba", ["Vamo'", "arriba"], "blue", None, "flag", False),
    ("tabuenoya", ["Ta' bueno", "ya"], "purple", "angry", None, False),
    ("diache", ["¡Diache!"], "orange", "shock", None, False),
    ("aymimadre", ["Ay mi", "madre"], "pink", "shock", None, False),
    ("jajaja", ["¡Jajajá!"], "yellow", "laugh", None, False),
    ("tranquilo", ["Tranquilo"], "teal", "sleep", None, True),
    ("bendicion", ["Bendición"], "blue", "pray", None, False),
    ("ombe", ["¡Ombe!"], "red", "meh", None, False),
    ("wepa", ["¡Wepa!"], "pink", "party", None, False),
    ("concho", ["¡Concho!"], "orange", "shock", None, True),
    ("eseasi", ["Eso e'", "así"], "green", "cool", None, False),
    ("tutaloco", ["¿Tú 'tá", "loco?"], "purple", "shock", None, False),
    ("suave", ["¡Suave!"], "teal", "meh", None, True),
    ("ahorita", ["Ahorita"], "yellow", None, "clock", False),
    ("quevaina", ["¡Qué", "vaina!"], "orange", "meh", None, False),
    ("nio", ["¡Ño!"], "red", "shock", None, False),
    ("palante", ["¡Pa'", "lante!"], "green", None, "fire", False),
    ("dale", ["¡Dale!"], "blue", None, None, True),
    ("mipana", ["Mi pana"], "teal", "wink", None, False),
    ("tiguere", ["Tremendo", "tíguere"], "yellow", "cool", None, False),
    ("unchin", ["Un chin"], "pink", "wink", None, True),
    ("quejevi", ["¡Qué", "jevi!"], "teal", "cool", None, False),
    ("tabrutal", ["¡Tá", "brutal!"], "red", None, "fire", False),
    ("quechevere", ["¡Qué", "chévere!"], "green", "party", None, False),
    ("mevoamori", ["Me vo'", "a morí"], "pink", "laugh", None, False),
    ("toyready", ["Toy", "ready"], "blue", "cool", None, True),
    ("quillao", ["Toy", "quillao"], "red", "angry", None, False),
    ("arrancao", ["Toy", "arrancao"], "green", "cry", None, False),
    ("enolla", ["Toy en", "olla"], "orange", "cry", None, True),
    ("asandobatata", ["Me cogiste", "asando batata"], "teal", "shock", None, False),
    ("nipalla", ["Ni pa'llá", "voy"], "purple", "meh", None, False),
    ("jabladera", ["Deja la", "jabladera"], "purple", "think", None, True),
    ("bochinche", ["¡Qué", "bochinche!"], "orange", "shock", None, False),
    ("diosbendiga", ["Dios te", "bendiga"], "blue", "pray", None, False),
    ("mamaben", ["Mamá, la", "bendición"], "pink", "pray", None, True),
    # Amor
    ("tequiero", ["Te quiero", "un montón"], "pink", "love", None, False),
    ("miamor", ["Mi amor"], "red", None, "heart", False),
    ("mivida", ["Mi vida"], "pink", "love", None, True),
    ("mireina", ["Mi reina"], "purple", None, "crown", False),
    ("mirey", ["Mi rey"], "blue", None, "crown", False),
    ("besito", ["Un", "besito"], "red", "love", None, False),
    ("teextrano", ["Te", "extraño"], "teal", "cry", None, False),
    ("quelindo", ["¡Qué", "lindo!"], "pink", None, "heart", True),
    # Comida
    ("mangu", ["¡Mangú!"], "yellow", None, "mangu", False),
    ("tresgolpes", ["Los tres", "golpes"], "orange", None, "mangu", True),
    ("sancocho", ["Sancocho"], "orange", None, "sancocho", False),
    ("habichuela", ["Habichuela", "con dulce"], "brown", None, "habichuela", False),
    ("cafecito", ["Un", "cafecito"], "brown", None, "coffee", True),
    ("morirsonando", ["Morir", "soñando"], "orange", None, "juice", False),
    ("unafria", ["Una fría"], "yellow", None, "bottle", False),
    ("jambre", ["Tengo un", "jambre"], "orange", "sweat", None, False),
    ("jartura", ["¡Qué", "jartura!"], "green", "sleep", None, True),
    ("querico", ["¡Qué", "rico!"], "red", "love", None, False),
    # Día a día
    ("apagon", ["¡Se fue", "la luz!"], "night", None, "bulb_off", False),
    ("llegoluz", ["¡Llegó", "la luz!"], "yellow", None, "bulb", False),
    ("quecalor", ["¡Qué", "calor!"], "orange", "sweat", None, False),
    ("playa", ["¡Pa' la", "playa!"], "teal", None, "palm", False),
    ("janguear", ["Vamo' a", "janguear"], "purple", "party", None, False),
    ("vengo", ["Voy en", "camino"], "green", None, "clock", True),
    ("orgullo", ["Orgullo", "dominicano"], "blue", None, "flag", False),
    # Pelota
    ("jonron", ["¡Jonrón!"], "blue", None, "baseball", False),
    ("ponchao", ["¡Ponchao!"], "red", "angry", None, False),
    ("safe", ["¡Safe!"], "green", None, "baseball", True),
    ("pelota", ["Vamo' a la", "pelota"], "orange", None, "baseball", False),
    ("pafuera", ["¡Pa'", "fuera!"], "purple", None, "star", False),
    ("playball", ["¡Play", "ball!"], "teal", None, "baseball", True),
    # Música
    ("merengue", ["¡Merengue!"], "red", None, "notes", False),
    ("abailar", ["¡A bailar!"], "pink", "party", None, False),
    ("guiratambora", ["Güira y", "tambora"], "orange", None, "guira", False),
    ("perico", ["Perico", "ripiao"], "green", None, "drum", True),
    ("bachata", ["¡Bachata!"], "purple", "love", None, False),
    ("dembow", ["¡Dembow!"], "night", None, "fire", True),
    # Navidad
    ("navidad", ["¡Feliz", "Navidad!"], "green", None, "tree", False),
    ("aguinaldo", ["¡Aguinaldo!"], "red", None, "gift", False),
    ("nochebuena", ["¡Noche", "buena!"], "blue", None, "star", True),
    ("anonuevo", ["¡Feliz Año", "Nuevo!"], "purple", "party", None, False),
    # Carnaval
    ("carnaval", ["¡Carnaval!"], "orange", None, "mask", False),
    ("cojuelo", ["Diablo", "cojuelo"], "red", None, "devil", False),
    ("vejigazo", ["¡Vejigazo!"], "teal", None, "vejiga", True),
    ("comparsa", ["¡A la", "comparsa!"], "pink", "party", None, False),
    # Cumpleaños
    ("feliz_cumple", ["¡Feliz", "cumple!"], "purple", None, "cake", False),
    ("muchos_mas", ["¡Que cumplas", "muchos más!"], "teal", "party", None, False),
    ("bizcocho", ["¡Bizcocho", "pa' ti!"], "pink", None, "cake", True),
    ("felicidades", ["¡Felicidades!"], "orange", None, "balloons", False),
    # KLK Plus 💎 (solo se pueden enviar con Plus; todos los ven)
    ("p_vuelvo", ["¡Vuelvo", "pa' RD!"], "teal", None, "palm", False),
    ("p_extrano", ["Extraño", "mi tierra"], "blue", None, "flag", False),
    ("p_jefa", ["¡La jefa!"], "pink", None, "crown", False),
    ("p_jefe", ["¡El jefe!"], "blue", None, "crown", True),
    ("p_fuego", ["¡Tá en", "fuego!"], "night", None, "fire", False),
    ("p_estrella", ["¡Tú ere'", "una estrella!"], "purple", None, "star", True),
    ("p_solazo", ["¡Qué", "solazo!"], "yellow", None, "sun", False),
    ("p_corazon", ["Con el", "corazón"], "red", None, "heart", False),
    ("p_gracias", ["¡Gracia'", "mi gente!"], "orange", "love", None, True),
    ("p_cool", ["Tranquilo", "y relajao"], "teal", "cool", None, False),
    ("p_guino", ["Tú sabe'", "cómo e'"], "purple", "wink", None, False),
    ("p_risa", ["¡Me muero", "de la risa!"], "yellow", "laugh", None, True),
]


if __name__ == "__main__":
    import sys
    only = set(sys.argv[1:])
    os.makedirs(OUT, exist_ok=True)
    for sid, lines, color, fk, ic, pill in STICKERS:
        if only and sid not in only:
            continue
        make(sid, lines, color, fk, ic, pill)
        print("ok", sid)
