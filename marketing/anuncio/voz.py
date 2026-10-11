"""Genera la voz del anuncio con varias voces libres y la comprueba con Whisper."""
import os, traceback
import numpy as np
import soundfile as sf

lines = [l.strip().split("|", 1) for l in open("marketing/anuncio/guion_voz.txt", encoding="utf-8") if "|" in l]
os.makedirs("out", exist_ok=True)
report = open("out/informe.txt", "w", encoding="utf-8")

def save(folder, i, wav, sr):
    os.makedirs(f"out/{folder}", exist_ok=True)
    sf.write(f"out/{folder}/{i}.wav", np.asarray(wav, dtype=np.float32), sr)

# --- Kokoro (Apache 2.0) ---
try:
    from kokoro import KPipeline
    pipe = KPipeline(lang_code="e")
    for voice in ["em_alex", "ef_dora", "em_santa"]:
        for i, text in lines:
            chunks = [a for _, _, a in pipe(text, voice=voice, speed=1.0)]
            save(f"kokoro_{voice}", i, np.concatenate([np.asarray(c) for c in chunks]), 24000)
        print("kokoro", voice, "ok", flush=True)
except Exception:
    traceback.print_exc(); report.write("kokoro falló\n" + traceback.format_exc())

# --- Chatterbox multilingüe (MIT) ---
try:
    import torch
    from chatterbox.mtl_tts import ChatterboxMultilingualTTS
    model = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
    for name, ex in [("chatterbox", 0.5), ("chatterbox_viva", 0.75)]:
        for i, text in lines:
            torch.manual_seed(int(i))
            wav = model.generate(text, language_id="es", exaggeration=ex, cfg_weight=0.5)
            save(name, i, wav.squeeze(0).cpu().numpy(), model.sr)
            print(name, i, "ok", flush=True)
except Exception:
    traceback.print_exc(); report.write("chatterbox falló\n" + traceback.format_exc())

# --- Comprobación con Whisper ---
try:
    import whisper
    w = whisper.load_model("small")
    for folder in sorted(os.listdir("out")):
        if not os.path.isdir(f"out/{folder}"): continue
        report.write(f"\n== {folder}\n")
        for i, text in lines:
            p = f"out/{folder}/{i}.wav"
            if os.path.exists(p):
                r = w.transcribe(p, language="es", fp16=False)
                d = sf.info(p).duration
                report.write(f"{i} [{d:.2f}s] {r['text'].strip()}\n")
        report.flush()
except Exception:
    traceback.print_exc(); report.write("whisper falló\n" + traceback.format_exc())
report.close()
print(open("out/informe.txt", encoding="utf-8").read())
