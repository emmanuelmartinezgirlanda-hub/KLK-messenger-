"""Locución del anuncio de la app (guion_v7) con la voz clonada del chico del balcón.
4 tomas por frase; Whisper elige la que mejor se entiende."""
import re, json, difflib, unicodedata
import numpy as np, soundfile as sf, torch, whisper
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
def norm(t):
    t = unicodedata.normalize("NFD", t.lower()); t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()
lines = [l.split("|", 1) for l in open("marketing/anuncio/guion_v7.txt", encoding="utf-8").read().strip().splitlines()]
w = whisper.load_model("medium")
m = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
ref = "out/balc1_ref.wav"
res = {}
for n, text in lines:
    want = norm(text.replace("Queloqué", "que lo que"))
    best = None
    for take in range(4):
        torch.manual_seed(97 * take + int(n))
        y = m.generate(text, language_id="es", audio_prompt_path=ref, exaggeration=0.65, cfg_weight=0.45, temperature=0.7)
        y = y.squeeze(0).cpu().numpy().astype(np.float32)
        p = f"out/v7_{n}_{take}.wav"; sf.write(p, y, m.sr)
        r = w.transcribe(p, language="es", fp16=False)
        sc = difflib.SequenceMatcher(None, want, norm(r["text"])).ratio()
        print(n, take, round(sc, 2), r["text"], flush=True)
        res[f"{n}_{take}"] = {"score": round(sc, 3), "text": r["text"].strip(), "dur": round(len(y) / m.sr, 2)}
        if best is None or sc > best[0]: best = (sc, take)
    res[f"{n}_best"] = best[1]
    json.dump(res, open("out/v7.json", "w"), ensure_ascii=False, indent=0)
