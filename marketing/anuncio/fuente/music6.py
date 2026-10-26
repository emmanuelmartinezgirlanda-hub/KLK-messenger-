# Música original para el anuncio de KLK messenger (compuesta por código, sin samples ajenos).
import numpy as np
from scipy.signal import butter, sosfilt
from scipy.io import wavfile

SR = 44100
BPM = 124
import sys, json
D = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else [4.6,4.6,4.8,6.6,6.2,4.8,6.0,6.2,4.2,5.2,4.8,5.0]
S = [sum(D[:i]) for i in range(len(D))]
END = sum(D) + 0.6
DUR = END + 0.4
N = int(SR * DUR)
beat = 60 / BPM
s16 = beat / 4
rng = np.random.default_rng(7)
mixL = np.zeros(N); mixR = np.zeros(N)

def add(sig, t, gain=1.0, pan=0.0):
    i = int(t * SR)
    if i >= N: return
    sig = sig[: N - i] * gain
    mixL[i:i+len(sig)] += sig * (1 - max(0, pan))
    mixR[i:i+len(sig)] += sig * (1 + min(0, pan))

def env(n, a=0.002, d=0.1, s=0.0, r=0.05, hold=None):
    t = np.arange(n) / SR
    e = np.where(t < a, t / a, s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    if hold is not None:
        rel = t > hold
        e[rel] *= np.exp(-(t[rel] - hold) / r)
    return e

def lp(x, f, order=2):
    return sosfilt(butter(order, f, 'low', fs=SR, output='sos'), x)
def hp(x, f, order=2):
    return sosfilt(butter(order, f, 'high', fs=SR, output='sos'), x)
def bp(x, lo, hi):
    return sosfilt(butter(2, [lo, hi], 'band', fs=SR, output='sos'), x)

def midi(m): return 440 * 2 ** ((m - 69) / 12)

def kick():
    n = int(0.35 * SR); t = np.arange(n) / SR
    f = 48 + 110 * np.exp(-t * 30)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 9) + 0.15 * np.sin(ph * 2) * np.exp(-t * 40)

def snare():
    n = int(0.22 * SR); t = np.arange(n) / SR
    noise = bp(rng.standard_normal(n), 1500, 7000) * np.exp(-t * 22)
    body = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 30)
    return 0.8 * noise + 0.5 * body

def clap():
    n = int(0.2 * SR); t = np.arange(n) / SR
    x = bp(rng.standard_normal(n), 900, 5000)
    e = np.zeros(n)
    for k, o in enumerate([0, 0.011, 0.022]):
        i = int(o * SR); e[i:] += np.exp(-(t[: n - i]) * (60 if k < 2 else 18))
    return x * e * 0.8

def guira(accent):
    # güira: raspado metálico corto (muy de merengue)
    n = int(0.07 * SR); t = np.arange(n) / SR
    x = hp(rng.standard_normal(n), 6000, 3)
    return x * np.exp(-t * (55 if accent else 80)) * (1.0 if accent else 0.55)

def pluck(freq, dur, bright=3500):
    n = int(dur * SR); t = np.arange(n) / SR
    saw = sum(np.sin(2 * np.pi * freq * k * t + 0.3 * k) / k for k in range(1, 9))
    saw += 0.6 * sum(np.sin(2 * np.pi * freq * 1.006 * k * t) / k for k in range(1, 9))
    return lp(saw, bright) * env(n, 0.003, 0.18, 0.0)

def bass(freq, dur):
    n = int(dur * SR); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(2 * np.pi * freq * 2 * t) + 0.12 * np.sin(2 * np.pi * freq * 3 * t)
    return lp(x, 900) * env(n, 0.004, 0.35, 0.55, 0.04, hold=dur * 0.8)

def marimba(freq, dur=0.45):
    n = int(dur * SR); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * freq * 4.0 * t) * np.exp(-t * 30)
    return x * np.exp(-t * 7) * env(n, 0.002, 10, 1)

def crash(dur=2.0):
    n = int(dur * SR); t = np.arange(n) / SR
    return hp(rng.standard_normal(n), 4000) * np.exp(-t * 2.2) * 0.5

def riser(dur):
    n = int(dur * SR); t = np.arange(n) / SR
    x = hp(rng.standard_normal(n), 1500) * (t / dur) ** 2
    sweep = np.sin(2 * np.pi * np.cumsum(200 + 1800 * (t / dur) ** 2) / SR) * (t / dur) ** 2 * 0.25
    return x * 0.35 + sweep

def boom():
    n = int(1.6 * SR); t = np.arange(n) / SR
    f = 40 + 80 * np.exp(-t * 6)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.5)

# Progresión (La menor): Am F C G — 1 compás cada acorde
prog = [(57, [57, 60, 64]), (53, [53, 57, 60]), (48, [55, 60, 64]), (55, [55, 59, 62])]
bar = beat * 4
BRK0, BRK1 = S[10], S[11]          # bajón en «privada de verdad»
OUT = S[11]                        # final
def section_on(t):
    if t < S[1]: return 'intro'
    if BRK0 <= t < BRK1: return 'break'
    if t >= OUT: return 'outro'
    return 'full'

t0 = S[1]
for i in range(3):
    root, ch = prog[i % 4]
    for m in ch:
        add(lp(pluck(midi(m + 12), bar * 0.95, 2200), 2500), 0.15 + i * bar * 0.97, 0.18)
hook = [76, 74, 72, 74, 76, 79, 76, 72]
for k, m in enumerate(hook):
    add(marimba(midi(m)), 0.3 + k * beat / 2, 0.32, pan=0.2)
add(riser(max(1.0, t0 - 0.2)), 0.2, 0.6)
add(crash(), t0, 0.7); add(boom(), t0, 0.9)

t = t0; step = 0
while t < OUT + 0.01:
    sec = section_on(t)
    bar_i = int((t - t0) / bar)
    pos = step % 16
    root, ch = prog[bar_i % 4]
    if sec == 'full':
        if pos in (0, 8): add(kick(), t, 0.95)
        if pos in (4, 12): add(kick(), t, 0.55)
        if pos in (3, 6, 11, 14): add(snare(), t, 0.42, pan=-0.05)
        if pos in (4, 12): add(clap(), t, 0.35)
        add(guira(pos % 2 == 0), t, 0.22, pan=0.35)
        if pos in (0, 3, 6, 10, 12): add(bass(midi(root - 12), s16 * (3 if pos in (0, 3) else 2)), t, 0.55)
        if pos in (2, 6, 10, 14):
            for j, m in enumerate(ch): add(pluck(midi(m + 12), 0.2), t, 0.11, pan=(-0.4 + 0.4 * j))
        if bar_i % 4 in (2, 3) and pos in (0, 3, 6, 8, 11, 14):
            mel = {0: 76, 3: 74, 6: 72, 8: 74, 11: 76, 14: 72}[pos] - (2 if bar_i % 4 == 3 else 0)
            add(marimba(midi(mel)), t, 0.16, pan=0.25)
    elif sec == 'break':
        if pos == 0:
            for j, m in enumerate(ch): add(lp(pluck(midi(m + 12), bar, 1400), 1500), t, 0.14, pan=(-0.4 + 0.4 * j))
            add(bass(midi(root - 12), bar * 0.9), t, 0.35)
        if pos % 4 == 2: add(guira(False), t, 0.12, pan=0.35)
    t += s16; step += 1

# acentos en las novedades: Mi Gente, Negocios y Plus
for k in (3, 5, 8):
    add(riser(0.9), S[k] - 0.9, 0.45); add(crash(), S[k], 0.5); add(boom(), S[k], 0.6)
add(riser(1.0), BRK0 - 1.0, 0.35)
# final
add(crash(3), OUT, 0.75); add(boom(), OUT, 1.0)
for m in [57, 60, 64, 69]: add(lp(pluck(midi(m + 12), 3.5, 3000), 3500), OUT, 0.16)
for k, m in enumerate([76, 74, 72, 74, 76, 79, 81]):
    add(marimba(midi(m)), OUT + 0.6 + k * beat / 2, 0.3, pan=0.2)
fin = END - 1.2
add(kick(), fin, 0.9); add(crash(2), fin, 0.5)
for m in [45, 57, 64, 69]: add(pluck(midi(m), 1.6, 1800), fin, 0.2)

mix = np.stack([mixL, mixR], 1)
fo = int(1.0 * SR); mix[-fo:] *= np.linspace(1, 0, fo)[:, None]
mix = np.tanh(mix * 0.9) / np.max(np.abs(np.tanh(mix * 0.9))) * 0.89
wavfile.write('music6.wav', SR, (mix * 32767).astype(np.int16))
print('ok', mix.shape[0] / SR)
