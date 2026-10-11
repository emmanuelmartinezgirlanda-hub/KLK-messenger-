"""Marca dónde termina la última palabra de cada frase (para cortar ruidos del final)."""
import os, re, unicodedata, json
import whisper
def norm(t):
    t = unicodedata.normalize("NFD", t.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9]+", "", t)
lines = [l.strip().split("|", 1) for l in open("marketing/anuncio/guion_voz.txt", encoding="utf-8") if "|" in l]
w = whisper.load_model("small")
out = {}
for i, text in lines:
    last = norm(text.split()[-1])
    r = w.transcribe(f"voz/best/{i}.wav", language="es", fp16=False, word_timestamps=True)
    words = [(norm(x["word"]), x["start"], x["end"]) for s in r["segments"] for x in s["words"]]
    end = None
    for wd, s0, e0 in words:
        if wd and (wd == last or wd.startswith(last[:4]) or last.startswith(wd[:4])):
            end = e0
    out[i] = {"end": end, "words": words}
    print(i, last, end, [w_[0] for w_ in words], flush=True)
json.dump(out, open("voz/recorte.json", "w"), ensure_ascii=False, indent=1)
