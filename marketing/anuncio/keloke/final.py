"""Voz del chico del balcón (clonada): «¡Queloqué, mi gente!» y la frase final de descarga."""
import os, re, json, difflib, unicodedata
import numpy as np, soundfile as sf, torch, whisper
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
LINES = {
  "saludo": "¡Queloqué, mi gente!",
  "descarga": "¡Descárgala ya en la App Store! Y en la Play Store, próximamente.",
}
def norm(t):
    t = unicodedata.normalize("NFD", t.lower()); t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()
w = whisper.load_model("medium")
m = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
ref = "out/balc1_ref.wav"
res = {}
for k, text in LINES.items():
    want = norm(text.replace("Queloqué", "que lo que"))
    for take in range(6):
        torch.manual_seed(31 * take + len(k))
        y = m.generate(text, language_id="es", audio_prompt_path=ref, exaggeration=0.6, cfg_weight=0.5, temperature=0.7)
        y = y.squeeze(0).cpu().numpy().astype(np.float32)
        p = f"out/fin_{k}_{take}.wav"; sf.write(p, y, m.sr)
        r = w.transcribe(p, language="es", fp16=False, word_timestamps=True)
        sc = difflib.SequenceMatcher(None, want, norm(r["text"])).ratio()
        res[f"{k}_{take}"] = {"score": round(sc, 3), "text": r["text"].strip(),
            "words": [(x["word"], round(x["start"], 2), round(x["end"], 2)) for s in r["segments"] for x in s["words"]]}
        print(k, take, round(sc, 2), r["text"], flush=True)
        json.dump(res, open("out/final.json", "w"), ensure_ascii=False, indent=0)
