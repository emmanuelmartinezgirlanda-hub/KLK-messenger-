"""Voz latino neutra: Chatterbox imitando el acento de una voz libre mexicana (Piper es_MX, Apache 2.0).
4 tomas por frase; Whisper elige la mejor y marca dónde termina la última palabra."""
import os, re, difflib, json, unicodedata
import numpy as np, soundfile as sf, torch, whisper
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

GUION = os.environ.get("GUION", "marketing/anuncio/guion_neutro.txt")
lines = [l.strip().split("|", 1) for l in open(GUION, encoding="utf-8") if "|" in l]
def norm(t):
    t = unicodedata.normalize("NFD", t.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()
def heard(t):
    t = t.replace("Queloque", "que lo que").replace("mésenyer", "messenger").replace("ese eme ese", "sms")
    return norm(t.replace("cu erre", "qr").replace("stíkers", "stickers"))

# Referencia de acento: 3 frases de la voz es_MX (≈15 s)
ref = []
for i in ["01", "03", "05"]:
    x, sr = sf.read(f"ref/es_MX-claude-high/{i}.wav")
    ref.append(x); ref.append(np.zeros(int(sr * 0.3)))
sf.write("ref.wav", np.concatenate(ref).astype(np.float32), sr)

os.makedirs("out/best", exist_ok=True); os.makedirs("out/takes", exist_ok=True)
rep = open("out/informe.txt", "w", encoding="utf-8")
model = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
w = whisper.load_model("small")
cuts = {}
for i, text in lines:
    want, best = heard(text), None
    for take in range(4):
        torch.manual_seed(2000 * int(i) + take)
        wav = model.generate(text, language_id="es", audio_prompt_path="ref.wav",
                             exaggeration=0.5, cfg_weight=0.5, temperature=0.7)
        p = f"out/takes/{i}_{take}.wav"
        sf.write(p, wav.squeeze(0).cpu().numpy().astype(np.float32), model.sr)
        r = w.transcribe(p, language="es", fp16=False, word_timestamps=True)
        got = r["text"].strip()
        score = difflib.SequenceMatcher(None, want, norm(got)).ratio()
        if sf.info(p).duration > 0.085 * len(text) + 1.0: score -= 0.1
        rep.write(f"{i}.{take} [{score:.2f}] {got}\n"); rep.flush()
        print(i, take, round(score, 2), got, flush=True)
        if best is None or score > best[0]:
            best = (score, p, r)
    os.replace(best[1], f"out/best/{i}.wav")
    last = norm(text)[-1]
    end = None
    for s in best[2]["segments"]:
        for wd in s["words"]:
            n = "".join(norm(wd["word"]))
            if n and (n == last or n[:4] == last[:4]): end = wd["end"]
    cuts[i] = end
    rep.write(f"==> {i} ({best[0]:.2f}) fin={end}\n")
json.dump(cuts, open("out/recorte.json", "w"), indent=1)
rep.close()
