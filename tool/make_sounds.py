"""Tonos de KLK (originales, generados por código: sin samples ni música ajena).

v2, "que suene de verdad": en vez de ondas simples, se modela cada instrumento:
- Tambora: parche con modos inarmónicos (como un tambor real) + golpe de palo en el aro.
- Güira: un raspador que pasa por las ranuras del metal (tren de golpecitos)
  filtrado por las resonancias del cilindro.
- Acordeón: tres lengüetas libres afinadas "en trémolo" (como el de perico
  ripiao), fuelle con aire y la caja que colorea el sonido.
- Bajo: cuerda pulsada (Karplus-Strong).
Todo con pequeñas imperfecciones humanas (tiempo y fuerza) y una sala.

Uso: python3 tool/make_sounds.py  -> assets/sounds/*.wav (mono, 44,1 kHz)."""
import os
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt, lfilter, fftconvolve

SR = 44100
OUT = "assets/sounds"
rng = np.random.default_rng(7)


def lp(x, f, o=2): return sosfilt(butter(o, f, "low", fs=SR, output="sos"), x)
def hp(x, f, o=2): return sosfilt(butter(o, f, "high", fs=SR, output="sos"), x)
def bp(x, lo, hi, o=2): return sosfilt(butter(o, [lo, hi], "band", fs=SR, output="sos"), x)
def midi(m): return 440 * 2 ** ((m - 69) / 12)
def t_(n): return np.arange(n) / SR


def reson(x, f, q):
    """Resonador de 2 polos (una resonancia del material)."""
    w = 2 * np.pi * f / SR
    r = np.exp(-w / (2 * q))
    a = [1, -2 * r * np.cos(w), r * r]
    return lfilter([1 - r], a, x)


# ---------------- Instrumentos ----------------

def tambora_open(gain=1.0, tone=1.0):
    """Mano en el parche: modos de membrana (inarmónicos) con caída de afinación."""
    dur = 0.7
    n = int(dur * SR); t = t_(n)
    f0 = 82 * tone * (1 + 0.35 * np.exp(-t * 30))  # el parche baja un poco al soltar
    ratios = [1.0, 1.594, 2.136, 2.296, 2.653, 2.918, 3.156]
    decays = [7.5, 11, 15, 17, 21, 25, 30]
    amps = [1.0, 0.55, 0.35, 0.22, 0.18, 0.12, 0.08]
    ph = 2 * np.pi * np.cumsum(f0) / SR
    x = sum(a * np.sin(r * ph + rng.uniform(0, 6.28)) * np.exp(-t * d) for r, d, a in zip(ratios, decays, amps))
    # el golpe de la mano: un poco de piel y aire
    hit = bp(rng.standard_normal(n), 200, 2500) * np.exp(-t * 90) * 0.6
    x = x + hit
    x = x * np.minimum(1, t / 0.002)
    return np.tanh(x * 1.3) * gain * 0.8


def tambora_rim(gain=1.0):
    """Palo en el aro de madera: clic seco con dos resonancias de madera."""
    n = int(0.18 * SR); t = t_(n)
    imp = np.zeros(n); imp[0] = 1; imp[1:30] = rng.standard_normal(29) * 0.3
    wood = reson(imp, 1150 * rng.uniform(0.98, 1.02), 14) * 1.2 + reson(imp, 2650, 18) * 0.8 + reson(imp, 480, 8) * 0.5
    click = hp(rng.standard_normal(n), 3000) * np.exp(-t * 400) * 0.25
    # un poquito del parche que vibra con el golpe
    body = np.sin(2 * np.pi * 150 * t) * np.exp(-t * 35) * 0.15
    x = (wood * 18 + click + body) * np.exp(-t * 28)
    return x * gain * 0.7


_GUIRA_MODES = [(3100, 9), (4700, 11), (6400, 12), (8300, 13), (10500, 14)]


def _metal(x):
    return sum(reson(x, f, q) * (1.0 / (1 + i * 0.3)) for i, (f, q) in enumerate(_GUIRA_MODES)) * 2.5


def guira_stroke(length=0.06, accent=False, gain=1.0):
    """Un raspado corto (el "chi"): el peine pasa por unas cuantas ranuras."""
    n = int(length * SR); t = t_(n)
    rate = rng.uniform(900, 1100) * (1.15 if accent else 1.0)  # ranuras por segundo
    ph = np.cumsum(np.full(n, rate / SR))
    clicks = (np.diff(np.floor(ph), prepend=0) > 0).astype(float)
    clicks *= rng.uniform(0.6, 1.0, n)
    exc = clicks * 0.7 + hp(rng.standard_normal(n), 2500) * 0.5
    env = np.minimum(1, t / 0.003) * np.exp(-t * (38 if accent else 60))
    x = _metal(exc * env)
    x = hp(x, 2200, 2)
    return x * gain * (1.0 if accent else 0.6)


def guira_scrape(length=0.3, gain=1.0):
    """El "chaaa" largo: raspado arrastrado, que se acelera y se frena."""
    n = int(length * SR); t = t_(n)
    vel = np.sin(np.pi * np.clip(t / length, 0, 1)) ** 0.7
    rate = 500 + 900 * vel
    ph = np.cumsum(rate / SR)
    clicks = (np.diff(np.floor(ph), prepend=0) > 0).astype(float) * rng.uniform(0.5, 1.0, n)
    exc = clicks * (0.3 + 0.6 * vel) + hp(rng.standard_normal(n), 2500) * 0.45 * vel
    x = _metal(exc)
    x = hp(x, 2200, 2) * np.minimum(1, t / 0.01) * np.minimum(1, (length - t) / 0.03).clip(0, 1)
    return x * gain * 0.75


def _reed(f, n, t):
    """Lengüeta libre: onda rica en armónicos (casi un pulso), con un poquito de vaivén."""
    drift = 1 + 0.0015 * np.sin(2 * np.pi * rng.uniform(0.3, 0.7) * t + rng.uniform(0, 6))
    ph = 2 * np.pi * np.cumsum(f * drift) / SR + rng.uniform(0, 6.28)
    k_max = int(min(40, (SR / 2.2) / f))
    return sum(np.sin(k * ph) / k ** 1.15 for k in range(1, k_max + 1))


def accordion(notes, dur, gain=0.3, bright=1.0):
    """Acordeón diatónico afinado "mojado": 3 lengüetas (una afinada, otra +14 cents,
    otra -12 cents) que baten entre sí, como el de perico ripiao."""
    n = int(dur * SR); t = t_(n)
    x = np.zeros(n)
    for m in notes:
        f = midi(m)
        for cents, a in ((0, 1.0), (14, 0.8), (-12, 0.7)):
            x += _reed(f * 2 ** (cents / 1200), n, t) * a
    x /= max(1, len(notes))
    # caja y fuelle: formantes de madera y el aire que se escapa
    body = reson(x, 950, 2.2) * 0.9 + reson(x, 2400 * bright, 3) * 0.6 + x * 0.25
    air = bp(rng.standard_normal(n), 1200, 6000) * 0.02
    # la lengüeta tarda un poquito en hablar; el fuelle empuja con fuerza variable
    att = 1 - np.exp(-t / 0.018)
    rel = np.clip((dur - t) / 0.035, 0, 1)
    press = 1 + 0.06 * np.sin(2 * np.pi * rng.uniform(1.5, 3) * t)
    y = (body + air) * att * rel * press
    y = lp(y, 4200 * bright, 3)
    return np.tanh(y * 0.35) * gain * 2.2


def bass(m, dur, gain=0.6):
    """Bajo: cuerda pulsada (Karplus-Strong), redondita."""
    f = midi(m)
    n = int(dur * SR)
    p = int(SR / f)
    buf = lp(rng.uniform(-1, 1, p), 1200)
    out = np.zeros(n)
    for i in range(n):
        out[i] = buf[i % p]
        buf[i % p] = 0.996 * 0.5 * (buf[i % p] + buf[(i + 1) % p])
    t = t_(n)
    out *= np.clip((dur - t) / 0.03, 0, 1)
    return lp(out, 900) * gain * 1.6


def marimba(m, dur=0.6, gain=0.5):
    """Marimba (madera con tubo): fundamental + modo 4x de la barra + golpe de baqueta."""
    n = int(dur * SR); t = t_(n); f = midi(m)
    x = np.sin(2 * np.pi * f * t) * np.exp(-t * 6)
    x += 0.35 * np.sin(2 * np.pi * f * 3.93 * t) * np.exp(-t * 26)
    x += 0.12 * np.sin(2 * np.pi * f * 9.2 * t) * np.exp(-t * 60)
    mallet = bp(rng.standard_normal(n), 800, 4000) * np.exp(-t * 300) * 0.2
    return (x + mallet) * np.minimum(1, t / 0.0015) * gain


# ---------------- Mezcla ----------------

def _room(seconds=0.9):
    """Respuesta de una sala pequeña con algo de madera (ruido que se apaga)."""
    n = int(seconds * SR); t = t_(n)
    ir = rng.standard_normal(n) * np.exp(-t * 6.5)
    ir = lp(ir, 5500) + lp(ir, 1500) * 0.6
    ir[:int(0.012 * SR)] = 0  # primeras reflexiones a ~12 ms
    return ir / np.sqrt((ir ** 2).sum())


ROOM = None


class Track:
    def __init__(self, dur):
        self.x = np.zeros(int(dur * SR))

    def add(self, sig, at, gain=1.0, human=True):
        if human:
            at += rng.normal(0, 0.004)  # nadie toca exacto
            gain *= rng.uniform(0.88, 1.08)
        i = max(0, int(at * SR))
        if i >= len(self.x): return
        sig = sig[: len(self.x) - i] * gain
        k = min(len(sig), int(0.006 * SR))
        sig[len(sig) - k:] *= np.linspace(1, 0, k)  # sin clics al cortar
        self.x[i:i + len(sig)] += sig

    def save(self, name, fade=0.08, wet=0.16):
        global ROOM
        if ROOM is None: ROOM = _room()
        x = self.x.copy()
        rev = fftconvolve(x, ROOM)[: len(x)]
        x = x + rev * wet * (np.abs(x).max() / (np.abs(rev).max() + 1e-9))
        x = hp(x, 35)
        f = int(fade * SR); x[-f:] *= np.linspace(1, 0, f)
        x = x / (np.abs(x).max() + 1e-9)
        x = np.tanh(x * 1.6) / np.tanh(1.6) * 0.92  # un pelín de compresión
        wavfile.write(os.path.join(OUT, name + ".wav"), SR, (x * 32767).astype(np.int16))
        print("ok", name, round(len(x) / SR, 2), "s")


BPM = 152  # merengue
beat = 60 / BPM
s16 = beat / 4
swing = 0.012  # el merengue va un pelín "arrastrado" en las semicorcheas


def at16(step): return step * s16 + (swing if step % 2 else 0)


def guira_bar(tr, t0, gain=0.55):
    # patrón típico: chá-chiqui-chá-chiqui… con el raspado largo al final del compás
    for step in range(16):
        if step == 14:
            tr.add(guira_scrape(s16 * 2.2), t0 + at16(step), gain * 0.9)
        elif step == 15:
            continue
        else:
            tr.add(guira_stroke(0.05, accent=step % 4 == 0), t0 + at16(step), gain * 0.8)


def tambora_bar(tr, t0, gain=0.8):
    # palo en el aro en las corcheas y la mano en el parche en 1 y en el "and" del 3
    for step in (2, 6, 10, 14):
        tr.add(tambora_rim(), t0 + at16(step), gain * 0.55)
    for step in (3, 7, 13):
        tr.add(tambora_rim(0.7), t0 + at16(step), gain * 0.4)
    tr.add(tambora_open(1.0), t0 + at16(0), gain)
    tr.add(tambora_open(0.8, tone=1.12), t0 + at16(11), gain * 0.85)
    tr.add(tambora_open(0.9), t0 + at16(12), gain * 0.7)


def make():
    os.makedirs(OUT, exist_ok=True)

    # 1. Güira (gratis): chiqui-chiqui-chaaa
    tr = Track(1.0)
    for k, acc in enumerate([1, 0, 0, 1, 0, 0, 1]):
        tr.add(guira_stroke(0.06, accent=bool(acc)), at16(k))
    tr.add(guira_scrape(0.32), at16(7), 1.0)
    tr.save("guira")

    # 2. Tambora: ta-ka ta-ka TUN, tun
    tr = Track(1.1)
    for k in range(4):
        tr.add(tambora_rim(0.85 if k % 2 else 1.0), at16(k))
    tr.add(tambora_open(1.1), at16(4))
    tr.add(tambora_open(0.7, tone=1.12), at16(6))
    tr.save("tambora")

    # 3. Merengue: tambora + güira + bajo + acordeón (un compás y remate)
    tr = Track(1.9)
    guira_bar(tr, 0)
    tambora_bar(tr, 0)
    for step, m in ((0, 45), (4, 52), (8, 45), (12, 52)):
        tr.add(bass(m, s16 * 3.5), at16(step), 0.7)
    lick = [76, 79, 81, 79, 76, 74, 76, 79]
    for k, m in enumerate(lick):
        tr.add(accordion([m, m - 12], s16 * 1.7, 0.5), at16(k * 2))
    tr.add(accordion([69, 72, 76], 0.45, 0.5), 16 * s16)
    tr.add(tambora_open(1.1), 16 * s16, 0.9)
    tr.save("merengue")

    # 4. Acordeón: lick de perico ripiao (semicorcheas rápidas y acorde)
    tr = Track(1.2)
    for k, m in enumerate([72, 74, 76, 77, 79, 77, 76, 79]):
        tr.add(accordion([m], s16 * 0.92, 0.6), at16(k))
    tr.add(accordion([72, 76, 79], 0.38, 0.55), at16(8))
    tr.add(accordion([48], 0.38, 0.35, bright=0.7), at16(8))
    tr.save("acordeon")

    # 5. "¡Klk!": tres notas de marimba con la güira
    tr = Track(0.9)
    for k, m in enumerate([76, 79, 84]):
        tr.add(marimba(m, 0.75, 0.7), k * 0.11)
    tr.add(guira_stroke(0.07, accent=True), 0.33, 0.35)
    tr.save("klk")

    # Tono de llamada: perico ripiao en bucle (~6,3 s)
    bars = 4
    tr = Track(bars * beat * 4)
    prog = [[57, 60, 64], [53, 57, 60], [55, 59, 62], [52, 55, 59]]
    roots = [45, 41, 43, 40]
    mel = [76, 74, 72, 74, 76, 79, 76, 72]
    for b in range(bars):
        t0 = b * beat * 4
        guira_bar(tr, t0, 0.45)
        tambora_bar(tr, t0, 0.7)
        for step in (0, 4, 8, 12):
            tr.add(bass(roots[b] + (7 if step in (4, 12) else 0), s16 * 3.4), t0 + at16(step), 0.65)
        tr.add(accordion(prog[b], beat * 1.8, 0.3, bright=0.8), t0)
        tr.add(accordion(prog[b], beat * 1.8, 0.26, bright=0.8), t0 + beat * 2)
        for k, m in enumerate(mel):
            tr.add(accordion([m + (2 if b % 2 else 0)], s16 * 1.6, 0.45), t0 + at16(k * 2))
    tr.save("llamada", fade=0.02, wet=0.12)


if __name__ == "__main__":
    make()
