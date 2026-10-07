"""Genera los packs de stickers de KLK (pelota, Navidad, carnaval, merengue y cumpleaños).

Uso: python3 tool/make_stickers.py   (necesita Pillow y la fuente Poppins Bold)
Dibuja todo a mano con Pillow: no usa imágenes de terceros.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "stickers")
FONT = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"
S = 640  # se dibuja al doble y se reduce a 320 para suavizar bordes
WHITE = (255, 255, 255, 255)
INK = (20, 24, 40, 255)


def font(size):
    return ImageFont.truetype(FONT, size)


def badge(color):
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((20, 20, S - 20, S - 20), fill=WHITE)
    d.ellipse((40, 40, S - 40, S - 40), fill=color)
    return im, d


def text(d, lines, y, size):
    f = font(size)
    for ln in lines:
        w = d.textlength(ln, font=f)
        d.text(((S - w) / 2, y), ln, font=f, fill=WHITE, stroke_width=10, stroke_fill=INK)
        y += size * 1.08


# ---------- Iconos ----------

def baseball(d, cx, cy, r):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=WHITE, outline=INK, width=8)
    red = (206, 17, 38, 255)
    for side in (-1, 1):
        box = (cx + side * r * 0.55 - r, cy - r, cx + side * r * 0.55 + r, cy + r)
        start, end = (110, 250) if side == 1 else (-70, 70)
        d.arc(box, start, end, fill=red, width=7)
        for t in range(-3, 4):
            a = math.radians((start + end) / 2 + t * 18)
            x = cx + side * r * 0.55 + r * math.cos(a)
            y = cy + r * math.sin(a)
            d.line((x - 9, y - 6, x + 9, y + 6), fill=red, width=5)


def bat(d, cx, cy, r):
    pts = [(cx - r, cy + r * 0.9), (cx - r * 0.85, cy + r), (cx + r, cy - r * 0.6), (cx + r * 0.75, cy - r * 0.95)]
    d.polygon(pts, fill=(196, 140, 72, 255), outline=INK, width=8)
    d.ellipse((cx - r * 1.1, cy + r * 0.8, cx - r * 0.75, cy + r * 1.15), fill=(160, 100, 50, 255), outline=INK, width=6)


def star(d, cx, cy, r, color=(255, 205, 40, 255)):
    pts = []
    for i in range(10):
        a = math.radians(-90 + i * 36)
        rr = r if i % 2 == 0 else r * 0.45
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=color, outline=INK, width=7)


def tree(d, cx, cy, r):
    green = (31, 122, 77, 255)
    for i, k in enumerate((1.0, 0.78, 0.56)):
        top = cy - r + i * r * 0.45
        d.polygon([(cx, top), (cx - r * k, top + r * 0.8), (cx + r * k, top + r * 0.8)], fill=green, outline=INK, width=7)
    d.rectangle((cx - 16, cy + r * 0.7, cx + 16, cy + r * 1.05), fill=(120, 70, 30, 255), outline=INK, width=6)
    star(d, cx, cy - r, 30)
    for x, y, c in ((-40, 0, (206, 17, 38, 255)), (35, 30, (0, 166, 180, 255)), (-10, 60, (255, 182, 39, 255))):
        d.ellipse((cx + x - 11, cy + y - 11, cx + x + 11, cy + y + 11), fill=c, outline=INK, width=4)


def gift(d, cx, cy, r, color=(206, 17, 38, 255)):
    d.rectangle((cx - r, cy - r * 0.55, cx + r, cy + r), fill=color, outline=INK, width=8)
    d.rectangle((cx - r * 1.1, cy - r * 0.85, cx + r * 1.1, cy - r * 0.45), fill=color, outline=INK, width=8)
    d.rectangle((cx - 16, cy - r * 0.85, cx + 16, cy + r), fill=(255, 205, 40, 255), outline=INK, width=5)
    d.ellipse((cx - r * 0.75, cy - r * 1.3, cx - 6, cy - r * 0.8), outline=INK, width=10)
    d.ellipse((cx + 6, cy - r * 1.3, cx + r * 0.75, cy - r * 0.8), outline=INK, width=10)


def moon(d, cx, cy, r, bg):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 225, 120, 255), outline=INK, width=7)
    d.ellipse((cx - r * 0.45, cy - r * 1.05, cx + r * 1.35, cy + r * 0.75), fill=bg)
    star(d, cx + r * 1.0, cy - r * 0.2, 22)


def fireworks(d, cx, cy, r):
    for k, (dx, dy, col) in enumerate(((0, 0, (255, 205, 40, 255)), (-r * 0.9, r * 0.5, (0, 166, 180, 255)),
                                       (r * 0.9, r * 0.4, (255, 255, 255, 255)))):
        rr = r * (0.75 if k == 0 else 0.45)
        for i in range(12):
            a = math.radians(i * 30)
            d.line((cx + dx + rr * 0.3 * math.cos(a), cy + dy + rr * 0.3 * math.sin(a),
                    cx + dx + rr * math.cos(a), cy + dy + rr * math.sin(a)), fill=col, width=9)


def mask(d, cx, cy, r, horns=False):
    if horns:
        for side in (-1, 1):
            d.polygon([(cx + side * r * 0.45, cy - r * 0.35), (cx + side * r * 1.05, cy - r * 1.25),
                       (cx + side * r * 0.85, cy - r * 0.2)], fill=(206, 17, 38, 255), outline=INK, width=7)
    face = (255, 205, 40, 255) if not horns else (206, 17, 38, 255)
    d.ellipse((cx - r, cy - r * 0.6, cx + r, cy + r * 0.9), fill=face, outline=INK, width=8)
    for side in (-1, 1):
        ex = cx + side * r * 0.42
        d.ellipse((ex - r * 0.25, cy - r * 0.15, ex + r * 0.25, cy + r * 0.25), fill=INK)
    d.arc((cx - r * 0.5, cy + r * 0.1, cx + r * 0.5, cy + r * 0.7), 20, 160, fill=INK, width=9)
    if horns:
        for i in range(-2, 3):
            d.ellipse((cx + i * r * 0.35 - 9, cy - r * 0.55 - 9, cx + i * r * 0.35 + 9, cy - r * 0.55 + 9),
                      fill=(255, 255, 255, 255), outline=INK, width=3)


def vejiga(d, cx, cy, r):
    d.ellipse((cx - r * 0.75, cy - r, cx + r * 0.75, cy + r * 0.55), fill=(255, 182, 39, 255), outline=INK, width=8)
    d.line((cx, cy + r * 0.55, cx + r * 0.5, cy + r * 1.1), fill=INK, width=8)
    d.ellipse((cx - r * 0.35, cy - r * 0.65, cx - r * 0.05, cy - r * 0.3), fill=(255, 240, 200, 255))


def confetti(d, cx, cy, r):
    cols = [(206, 17, 38, 255), (0, 166, 180, 255), (255, 205, 40, 255), (255, 255, 255, 255), (106, 44, 145, 255)]
    import random
    rnd = random.Random(7)
    for i in range(26):
        x = cx + rnd.uniform(-r * 1.2, r * 1.2)
        y = cy + rnd.uniform(-r, r)
        d.rectangle((x - 9, y - 5, x + 9, y + 5), fill=cols[i % len(cols)], outline=INK, width=2)


def notes(d, cx, cy, r):
    for dx, dy, k in ((-r * 0.55, r * 0.1, 1.0), (r * 0.45, -r * 0.2, 0.85)):
        x, y = cx + dx, cy + dy
        d.ellipse((x - 34 * k, y + 50 * k, x + 22 * k, y + 92 * k), fill=WHITE, outline=INK, width=7)
        d.rectangle((x + 10 * k, y - 70 * k, x + 22 * k, y + 72 * k), fill=WHITE, outline=INK, width=5)
    d.polygon([(cx - r * 0.55 + 10, cy - r * 0.6), (cx + r * 0.45 + 22, cy - r * 0.9),
               (cx + r * 0.45 + 22, cy - r * 0.6), (cx - r * 0.55 + 10, cy - r * 0.3)], fill=WHITE, outline=INK, width=6)


def drum(d, cx, cy, r):
    d.rectangle((cx - r, cy - r * 0.45, cx + r, cy + r * 0.55), fill=(196, 106, 0, 255), outline=INK, width=8)
    d.ellipse((cx - r * 1.05, cy - r * 0.75, cx - r * 0.65, cy + r * 0.85), fill=(255, 240, 210, 255), outline=INK, width=7)
    d.ellipse((cx + r * 0.65, cy - r * 0.75, cx + r * 1.05, cy + r * 0.85), fill=(255, 240, 210, 255), outline=INK, width=7)
    for i in range(5):
        x = cx - r * 0.6 + i * r * 0.3
        d.line((x, cy - r * 0.45, x + r * 0.15, cy + r * 0.55), fill=INK, width=4)


def guira(d, cx, cy, r):
    d.rounded_rectangle((cx - r * 0.35, cy - r, cx + r * 0.35, cy + r * 0.8), radius=40,
                        fill=(200, 205, 215, 255), outline=INK, width=8)
    for row in range(7):
        for col in range(3):
            x = cx - r * 0.2 + col * r * 0.2
            y = cy - r * 0.8 + row * r * 0.24
            d.ellipse((x - 5, y - 5, x + 5, y + 5), fill=INK)
    d.rectangle((cx - 8, cy + r * 0.8, cx + 8, cy + r * 1.15), fill=INK)


def cake(d, cx, cy, r):
    d.rounded_rectangle((cx - r, cy - r * 0.2, cx + r, cy + r * 0.85), radius=20, fill=(255, 240, 225, 255), outline=INK, width=8)
    d.rounded_rectangle((cx - r * 0.75, cy - r * 0.75, cx + r * 0.75, cy - r * 0.15), radius=16, fill=(255, 205, 220, 255), outline=INK, width=8)
    for i in range(-1, 2):
        x = cx + i * r * 0.4
        d.rectangle((x - 8, cy - r * 1.15, x + 8, cy - r * 0.75), fill=(0, 166, 180, 255), outline=INK, width=4)
        d.ellipse((x - 11, cy - r * 1.42, x + 11, cy - r * 1.12), fill=(255, 182, 39, 255), outline=INK, width=4)
    for i in range(6):
        x = cx - r * 0.8 + i * r * 0.32
        d.ellipse((x - 10, cy + r * 0.2, x + 10, cy + r * 0.4), fill=(206, 17, 38, 255))


def balloons(d, cx, cy, r):
    for dx, dy, col in ((-r * 0.55, 0, (206, 17, 38, 255)), (r * 0.5, -r * 0.2, (0, 45, 98, 255)),
                        (0, -r * 0.55, (255, 205, 40, 255))):
        x, y = cx + dx, cy + dy
        d.line((x, y + r * 0.55, cx, cy + r * 1.1), fill=INK, width=5)
        d.ellipse((x - r * 0.42, y - r * 0.55, x + r * 0.42, y + r * 0.55), fill=col, outline=INK, width=7)


def accordion(d, cx, cy, r):
    d.rectangle((cx - r, cy - r * 0.6, cx - r * 0.55, cy + r * 0.6), fill=(206, 17, 38, 255), outline=INK, width=7)
    d.rectangle((cx + r * 0.55, cy - r * 0.6, cx + r, cy + r * 0.6), fill=(206, 17, 38, 255), outline=INK, width=7)
    for i in range(6):
        x0 = cx - r * 0.55 + i * r * 0.183
        d.polygon([(x0, cy - r * 0.5), (x0 + r * 0.09, cy - r * 0.6), (x0 + r * 0.183, cy - r * 0.5),
                   (x0 + r * 0.183, cy + r * 0.5), (x0 + r * 0.09, cy + r * 0.6), (x0, cy + r * 0.5)],
                  fill=(240, 240, 245, 255) if i % 2 else (210, 215, 225, 255), outline=INK, width=4)
    for i in range(3):
        d.ellipse((cx + r * 0.68, cy - r * 0.4 + i * r * 0.35, cx + r * 0.87, cy - r * 0.22 + i * r * 0.35), fill=WHITE)


BLUE, RED, GREEN, PURPLE, ORANGE, TEAL, NIGHT = (
    (0, 45, 98, 255), (206, 17, 38, 255), (31, 122, 77, 255), (106, 44, 145, 255),
    (196, 106, 0, 255), (0, 140, 155, 255), (20, 30, 60, 255))

STICKERS = [
    # (id, color, icono, líneas de texto, tamaño de letra)
    ("jonron", BLUE, lambda d: (bat(d, 250, 215, 95), baseball(d, 410, 170, 58)), ["¡Jonrón!"], 100),
    ("ponchao", RED, lambda d: baseball(d, 320, 200, 105), ["¡Ponchao!"], 92),
    ("safe", GREEN, lambda d: baseball(d, 320, 200, 105), ["¡Safe!"], 120),
    ("pelota", ORANGE, lambda d: (baseball(d, 230, 200, 70), bat(d, 400, 205, 80)), ["Vamo' a", "la pelota"], 76),
    ("navidad", GREEN, lambda d: tree(d, 320, 210, 110), ["¡Feliz", "Navidad!"], 76),
    ("aguinaldo", RED, lambda d: gift(d, 320, 230, 90), ["¡Aguinaldo!"], 78),
    ("nochebuena", NIGHT, lambda d: moon(d, 300, 200, 95, NIGHT), ["¡Noche", "buena!"], 80),
    ("anonuevo", PURPLE, lambda d: fireworks(d, 320, 190, 120), ["¡Feliz", "Año Nuevo!"], 70),
    ("carnaval", PURPLE, lambda d: (confetti(d, 320, 190, 140), mask(d, 320, 200, 100)), ["¡Carnaval!"], 88),
    ("cojuelo", RED, lambda d: mask(d, 320, 215, 95, horns=True), ["Diablo", "cojuelo"], 78),
    ("vejigazo", TEAL, lambda d: vejiga(d, 320, 210, 110), ["¡Vejigazo!"], 84),
    ("comparsa", BLUE, lambda d: confetti(d, 320, 200, 150), ["¡A la", "comparsa!"], 78),
    ("merengue", RED, lambda d: notes(d, 320, 200, 120), ["¡Merengue!"], 84),
    ("abailar", TEAL, lambda d: notes(d, 320, 200, 120), ["¡A bailar!"], 92),
    ("guiratambora", ORANGE, lambda d: (guira(d, 200, 210, 95), drum(d, 410, 230, 85)), ["Güira y", "tambora"], 76),
    ("perico", GREEN, lambda d: accordion(d, 320, 215, 140), ["Perico", "ripiao"], 82),
    ("feliz_cumple", PURPLE, lambda d: cake(d, 320, 230, 110), ["¡Feliz", "cumple!"], 82),
    ("muchos_mas", BLUE, lambda d: balloons(d, 320, 200, 120), ["¡Que cumplas", "muchos más!"], 60),
    ("bizcocho", RED, lambda d: cake(d, 320, 230, 110), ["¡Bizcocho", "pa' ti!"], 74),
    ("felicidades", TEAL, lambda d: gift(d, 320, 230, 90, color=(255, 182, 39, 255)), ["¡Felici-", "dades!"], 82),
]


def make(sid, color, icon, lines, size):
    im, d = badge(color)
    icon(d)
    y0 = 360 if len(lines) == 1 else 330
    text(d, lines, y0, size)
    im = im.resize((320, 320), Image.LANCZOS)
    im.save(os.path.join(OUT, f"{sid}.png"), optimize=True)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    only = set(sys.argv[1:])
    for s in STICKERS:
        if not only or s[0] in only:
            make(*s)
    print(f"{len(STICKERS)} stickers en {os.path.abspath(OUT)}")
