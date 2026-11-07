"""Solo Whisper: tiempos de cada palabra de los audios originales y de todas las tomas (rama marketing-keloke)."""
import os, json, whisper
w = whisper.load_model("medium")
res = {}
files = [f"marketing/anuncio/keloke/{f}" for f in sorted(os.listdir("marketing/anuncio/keloke")) if f.endswith(".wav")]
files += [f"out/{f}" for f in sorted(os.listdir("out")) if "_toma" in f]
for p in files:
    r = w.transcribe(p, language="es", fp16=False, word_timestamps=True)
    res[os.path.basename(p)] = [(x["word"], round(x["start"], 2), round(x["end"], 2)) for s in r["segments"] for x in s["words"]]
    print(p, r["text"], flush=True)
    json.dump(res, open("out/palabras.json", "w"), ensure_ascii=False, indent=0)
