"""Voz del anuncio con Chatterbox (MIT): 4 tomas por frase y Whisper elige la que mejor se entiende."""
import os, re, difflib, traceback, unicodedata
import numpy as np
import soundfile as sf
import torch
import whisper
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

lines = [l.strip().split("|", 1) for l in open("marketing/anuncio/guion_voz.txt", encoding="utf-8") if "|" in l]
# Lo que debería "oír" Whisper en cada frase (ortografía normal).
def heard(t):
    t = t.replace("Queloque", "que lo que").replace("mésenyer", "messenger")
    t = t.replace("ese eme ese", "sms").replace("cu erre", "qr").replace("stíkers", "stickers")
    return norm(t)
def norm(t):
    t = unicodedata.normalize("NFD", t.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()

os.makedirs("out/best", exist_ok=True); os.makedirs("out/takes", exist_ok=True)
report = open("out/informe.txt", "w", encoding="utf-8")
model = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
w = whisper.load_model("small")
for i, text in lines:
    want = heard(text)
    best = None
    for take in range(4):
        torch.manual_seed(1000 * int(i) + take)
        wav = model.generate(text, language_id="es", exaggeration=0.6, cfg_weight=0.5, temperature=0.75)
        p = f"out/takes/{i}_{take}.wav"
        sf.write(p, wav.squeeze(0).cpu().numpy().astype(np.float32), model.sr)
        got = w.transcribe(p, language="es", fp16=False)["text"].strip()
        score = difflib.SequenceMatcher(None, want, norm(got)).ratio()
        dur = sf.info(p).duration
        # Penaliza tomas que se alargan (palabras repetidas o inventadas).
        if dur > 0.085 * len(text) + 1.0: score -= 0.1
        report.write(f"{i}.{take} [{score:.2f} {dur:.2f}s] {got}\n"); report.flush()
        print(i, take, round(score, 2), got, flush=True)
        if best is None or score > best[0]:
            best = (score, p)
    os.replace(best[1], f"out/best/{i}.wav")
    report.write(f"==> {i}: {best[1]} ({best[0]:.2f})\n")
report.close()
