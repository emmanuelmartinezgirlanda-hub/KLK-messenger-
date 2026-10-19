"""Tonos de KLK (originales, generados por código: sin samples ajenos).
Uso: python3 tool/make_sounds.py  -> assets/sounds/*.wav (mono, 22 kHz)."""
import os
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

SR = 22050
OUT = "assets/sounds"
rng = np.random.default_rng(11)


def lp(x, f, o=2): return sosfilt(butter(o, f, "low", fs=SR, output="sos"), x)
def hp(x, f, o=2): return sosfilt(butter(o, f, "high", fs=SR, output="sos"), x)
def bp(x, lo, hi): return sosfilt(butter(2, [lo, hi], "band", fs=SR, output="sos"), x)
def midi(m): return 440 * 2 ** ((m - 69) / 12)
def t_(n): return np.arange(n) / SR


def tambora_open(gain=1.0):
    # golpe grave de la tambora (parche) con un poco de "piel"
    n = int(0.45 * SR); t = t_(n)
    f = 95 + 70 * np.exp(-t * 28)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    skin = bp(rng.standard_normal(n), 300, 1500) * np.exp(-t * 35) * 0.35
    return (body + skin) * gain


def tambora_rim(gain=1.0):
    # golpe de palo en el aro (seco y agudo)
    n = int(0.12 * SR); t = t_(n)
    x = bp(rng.standard_normal(n), 1800, 6000) * np.exp(-t * 60)
    x += np.sin(2 * np.pi * 820 * t) * np.exp(-t * 50) * 0.5
    return x * gain


def guira(accent, length=0.07):
    n = int(length * SR); t = t_(n)
    x = hp(rng.standard_normal(n), 4500, 3)
    return x * np.exp(-t * (40 if accent else 70)) * (1.0 if accent else 0.55)


def guira_scrape(length=0.22):
    # raspado largo: la güira arrastrada
    n = int(length * SR); t = t_(n)
    x = hp(rng.standard_normal(n), 3500, 3)
    ridges = 0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 38 * t))
    env = np.minimum(1, t / 0.02) * np.exp(-t * 6)
    return x * ridges * env


def accordion(notes, dur, gain=0.3):
    # acordeón: dos lengüetas un poco desafinadas + trémolo
    n = int(dur * SR); t = t_(n)
    x = np.zeros(n)
    for m in notes:
        f = midi(m)
        for det in (1.0, 1.006):
            ph = 2 * np.pi * f * det * t
            x += sum(np.sin(k * ph) / k for k in range(1, 7)) * (1 if det == 1 else 0.7)
    x = bp(x, 250, 4200)
    trem = 1 + 0.18 * np.sin(2 * np.pi * 6.2 * t)
    env = np.minimum(1, t / 0.015) * np.minimum(1, (dur - t) / 0.04).clip(0, 1)
    return x * trem * env * gain / max(1, len(notes))


def marimba(m, dur=0.35, gain=0.5):
    n = int(dur * SR); t = t_(n); f = midi(m)
    x = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * f * 4 * t) * np.exp(-t * 30)
    return x * np.exp(-t * 9) * gain


class Track:
    def __init__(self, dur):
        self.x = np.zeros(int(dur * SR))

    def add(self, sig, at, gain=1.0):
        i = int(at * SR)
        if i >= len(self.x): return
        sig = sig[: len(self.x) - i] * gain
        self.x[i:i + len(sig)] += sig

    def save(self, name, fade=0.08):
        x = self.x.copy()
        f = int(fade * SR); x[-f:] *= np.linspace(1, 0, f)
        x = np.tanh(x * 1.2); x = x / (np.abs(x).max() + 1e-9) * 0.9
        wavfile.write(os.path.join(OUT, name + ".wav"), SR, (x * 32767).astype(np.int16))
        print("ok", name, round(len(x) / SR, 2), "s")


BPM = 150  # merengue
beat = 60 / BPM
s16 = beat / 4


def make():
    os.makedirs(OUT, exist_ok=True)

    # 1. Güira (gratis): chiqui-chiqui-chá
    tr = Track(0.9)
    for k, acc in enumerate([1, 0, 0, 1, 0, 0, 1]):
        tr.add(guira(acc), k * s16)
    tr.add(guira_scrape(0.3), 7 * s16, 0.9)
    tr.save("guira")

    # 2. Tambora: ta-ka ta-ka TUN
    tr = Track(1.0)
    for k, at in enumerate([0, 1, 2, 3]):
        tr.add(tambora_rim(0.8 if k % 2 else 1.0), at * s16)
    tr.add(tambora_open(1.1), 4 * s16)
    tr.add(tambora_open(0.6), 6 * s16)
    tr.save("tambora")

    # 3. Merengue: tambora + güira + acordeón (riff corto)
    tr = Track(1.7)
    for step in range(16):
        tr.add(guira(step % 2 == 0), step * s16, 0.55)
        if step in (0, 8): tr.add(tambora_open(), step * s16, 0.8)
        if step in (3, 6, 11, 14): tr.add(tambora_rim(), step * s16, 0.6)
    for k, m in enumerate([76, 79, 81, 79, 76, 74, 76]):
        tr.add(accordion([m, m - 12], s16 * 1.8, 0.5), k * s16 * 2)
    tr.add(accordion([69, 72, 76], 0.5, 0.45), 14 * s16)
    tr.save("merengue")

    # 4. Acordeón: lick de perico ripiao
    tr = Track(1.1)
    for k, m in enumerate([72, 74, 76, 77, 79, 77, 76, 79]):
        tr.add(accordion([m], s16 * 0.95, 0.6), k * s16)
    tr.add(accordion([72, 76, 79], 0.35, 0.55), 8 * s16)
    tr.save("acordeon")

    # 5. Marimba "¡Klk!" (tres notas alegres)
    tr = Track(0.8)
    for k, m in enumerate([76, 79, 84]):
        tr.add(marimba(m, 0.5, 0.7), k * 0.11)
    tr.add(guira(True), 0.33, 0.4)
    tr.save("klk")

    # Tono de llamada: perico ripiao en bucle (~6 s)
    tr = Track(6.4)
    bars = int(6.4 / (beat * 4))
    prog = [[69, 72, 76], [65, 69, 72], [67, 71, 74], [64, 67, 71]]
    mel = [76, 74, 72, 74, 76, 79, 76, 72]
    for b in range(bars):
        t0 = b * beat * 4
        for step in range(16):
            at = t0 + step * s16
            tr.add(guira(step % 2 == 0), at, 0.5)
            if step in (0, 8): tr.add(tambora_open(), at, 0.75)
            if step in (3, 6, 11, 14): tr.add(tambora_rim(), at, 0.55)
        tr.add(accordion(prog[b % 4], beat * 1.8, 0.35), t0)
        tr.add(accordion(prog[b % 4], beat * 1.8, 0.3), t0 + beat * 2)
        for k, m in enumerate(mel):
            tr.add(accordion([m + (2 if b % 2 else 0)], s16 * 1.6, 0.45), t0 + k * beat / 2)
    tr.save("llamada", fade=0.02)


if __name__ == "__main__":
    make()
