"""Cambia «Keloke» por «Queloqué mésenyer» con la voz clonada de cada actor (Chatterbox).
Whisper localiza la palabra en el audio original (entre dos palabras ancla) y en cada toma nueva.
Salida en out/: <clip>.json (tiempos) y <clip>_frase.wav (solo «Queloqué mésenyer» con la voz del actor)."""
import os, re, json, difflib, unicodedata
import numpy as np, soundfile as sf, torch, whisper
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

D = "marketing/anuncio/keloke"
LINES = {
    "san":   ("Tranquila, que en Queloqué mésenyer está todo: los turnos y quién pagó.", "en", "esta"),
    "playa": ("¡Esta la subo a Mi Gente en Queloqué mésenyer, pa' que la vea toda la familia!", "en", "pa"),
    "colm":  ("Ahora mis clientes me hacen los pedidos por Queloqué mésenyer. ¡El negocio está volando!", "por", "el"),
    "balc":  ("¡Klk, mi gente! Si no estás en Queloqué mésenyer, te lo estás perdiendo. Descárgala ya.", "en", "te"),
}
def norm(t):
    t = unicodedata.normalize("NFD", t.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()
def words(r):
    out = []
    for s in r["segments"]:
        for w in s.get("words", []):
            n = norm(w["word"])
            if n: out.append((" ".join(n), w["start"], w["end"]))
    return out
def region(ws, a, b):
    """(fin de la ancla a, inicio de la ancla b, texto entre medias)"""
    for j, (t, s, e) in enumerate(ws):
        if t == b or t.startswith(b + " "):
            for i in range(j - 1, -1, -1):
                if ws[i][0] == a or ws[i][0].endswith(" " + a):
                    if 1 <= j - i <= 6:
                        return ws[i][2], s, " ".join(x[0] for x in ws[i + 1:j])
    return None

os.makedirs("out", exist_ok=True)
rep = open("out/informe.txt", "w", encoding="utf-8")
w = whisper.load_model("medium")
model = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
WANT = norm("que lo que messenger")
for clip in sorted(f[:-4] for f in os.listdir(D) if f.endswith(".wav")):
    key = re.sub(r"\d+$", "", clip)
    text, a, b = LINES[key]
    src = f"{D}/{clip}.wav"
    r = w.transcribe(src, language="es", fp16=False, word_timestamps=True)
    ws = words(r)
    reg = region(ws, a, b)
    rep.write(f"\n## {clip}\noriginal: {r['text'].strip()}\npalabras: {ws}\nzona: {reg}\n"); rep.flush()
    print(clip, r["text"], reg, flush=True)
    info = {"original": r["text"].strip(), "words": ws, "zona": reg}
    # Referencia de voz: la frase del actor que dice la marca (segmento de Whisper que la contiene)
    x, sr = sf.read(src)
    if reg:
        seg = next((s for s in r["segments"] if s["start"] <= reg[0] <= s["end"] + 0.3), None)
        s0, s1 = (seg["start"], seg["end"]) if seg else (max(0, reg[0] - 3), reg[1] + 2)
    else:
        s0, s1 = 0, len(x) / sr
    s0, s1 = max(0, s0 - 0.5), min(len(x) / sr, s1 + 0.5)
    if s1 - s0 < 3: s0, s1 = max(0, s0 - 1.5), min(len(x) / sr, s1 + 1.5)
    sf.write(f"out/{clip}_ref.wav", x[int(s0 * sr):int(s1 * sr)], sr)
    info["ref"] = [s0, s1]
    best = None
    for take in range(5):
        torch.manual_seed(77 * take + len(clip))
        wav = model.generate(text, language_id="es", audio_prompt_path=f"out/{clip}_ref.wav",
                             exaggeration=0.6, cfg_weight=0.5, temperature=0.7)
        y = wav.squeeze(0).cpu().numpy().astype(np.float32)
        p = f"out/{clip}_toma{take}.wav"
        sf.write(p, y, model.sr)
        rr = w.transcribe(p, language="es", fp16=False, word_timestamps=True)
        z = region(words(rr), a, b)
        whole = difflib.SequenceMatcher(None, norm(text.replace("Queloqué mésenyer", "que lo que messenger")), norm(rr["text"])).ratio()
        part = difflib.SequenceMatcher(None, WANT, norm(z[2])).ratio() if z else 0
        score = 0.6 * part + 0.4 * whole if z else 0
        rep.write(f"{clip}.{take} [{score:.2f}] {rr['text'].strip()} | zona={z}\n"); rep.flush()
        print(clip, take, round(score, 2), rr["text"], z, flush=True)
        if z and (best is None or score > best[0]):
            best = (score, take, z, y)
    if best:
        score, take, z, y = best
        s, e = max(0, z[0] - 0.03), z[1] + 0.03
        sf.write(f"out/{clip}_frase.wav", y[int(s * model.sr):int(e * model.sr)], model.sr)
        info.update(toma=take, score=score, zona_nueva=z)
    json.dump(info, open(f"out/{clip}.json", "w"), indent=1, ensure_ascii=False)
rep.close()
