"""Idiomas de KLK.

  python3 tool/l10n.py wrap   → envuelve con tr('…') los textos visibles de las pantallas
                                 (Text, tooltip, hintText…) y quita los `const` que lo impiden.
  python3 tool/l10n.py build  → genera lib/core/l10n/strings.dart con tool/l10n_data.py
  python3 tool/l10n.py check  → lista los textos tr('…') que aún no tienen traducción

La clave de cada traducción es el texto en español tal y como está escrito en el código.
"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
LIB = os.path.join(ROOT, "lib")
SKIP = {
    "lib/core/l10n/l10n.dart", "lib/core/l10n/strings.dart", "lib/features/messaging/models.dart",
    "lib/features/messaging/app_controller.dart", "lib/features/messaging/demo_data.dart",
    "lib/features/messaging/stickers.dart", "lib/main.dart",
}
LIT = r"'(?:[^'\\$]|\\.)*'"
KEYS = r"(?:tooltip|hintText|labelText|helperText|message|text|semanticLabel)"
PATTERNS = [
    re.compile(r"(\bText\(\s*)(" + LIT + r")(?=\s*[,)])"),
    re.compile(r"(\b" + KEYS + r":\s*)(" + LIT + r")(?=\s*[,)\n])"),
    re.compile(r"(\b_(?:snack|say)\(\s*)(" + LIT + r")(?=\s*[,)])"),
]
TERNARY = re.compile(r"(\?\s*)(" + LIT + r")(\s*:\s*)(" + LIT + r")")
TR_LIT = re.compile(r"\btr\((" + LIT + r")\)")


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def visible(lit):
    body = lit[1:-1]
    return bool(re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}", body)) and not body.startswith(("assets/", "http"))


def wrap_text(src):
    def sub(m):
        lit = m.group(2)
        if not visible(lit):
            return m.group(0)
        return m.group(1) + "tr(" + lit + ")"

    for p in PATTERNS:
        src = p.sub(sub, src)
    out = []
    for line in src.split("\n"):
        if re.search(r"\bText\(|title:|subtitle:|label:|tooltip:|child:|text:", line):
            line = re.sub(r"(\?\s*)(" + LIT + r")(?=\s*:)", lambda m: m.group(1) + (f"tr({m.group(2)})" if visible(m.group(2)) else m.group(2)), line)
            line = re.sub(r"(?<!\w)(:\s*)(" + LIT + r")(?=\)|\s*,\s*style)", lambda m: m.group(1) + (f"tr({m.group(2)})" if visible(m.group(2)) and "?" in line else m.group(2)), line)
            line = TERNARY.sub(
                lambda m: m.group(1) + (f"tr({m.group(2)})" if visible(m.group(2)) else m.group(2))
                + m.group(3) + (f"tr({m.group(4)})" if visible(m.group(4)) else m.group(4)),
                line)
        out.append(line)
    return "\n".join(out)


def _code_mask(src):
    """True en los caracteres que son código (no texto entre comillas ni comentarios)."""
    mask = [True] * len(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = False
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                mask[k] = False
            i = j
        elif c in "'\"":
            triple = src.startswith(c * 3, i)
            q = c * 3 if triple else c
            j = i + len(q)
            while j < n and not src.startswith(q, j):
                j += 2 if src[j] == "\\" else 1
            j = min(n, j + len(q))
            for k in range(i, j):
                mask[k] = False
            i = j
        else:
            i += 1
    return mask


def strip_consts(src):
    """Quita solo los `const` de las expresiones que contienen un tr(…)."""
    mask = _code_mask(src)
    remove = set()
    for m in re.finditer(r"\btr\(", src):
        if not mask[m.start()]:
            continue
        depth = 0
        i = m.start() - 1
        while i >= 0:
            c = src[i]
            if mask[i]:
                if c in ")]}":
                    depth += 1
                elif c in "([{":
                    if depth > 0:
                        depth -= 1
                    else:
                        # abre una expresión que contiene el tr: ¿va precedida de const?
                        before = src[:i]
                        mm = re.search(r"\bconst\s+((?:[A-Za-z_][\w.]*)?\s*(?:<[^<>;]*>)?\s*)$", before)
                        if mm:
                            remove.add(mm.start())
                elif c == ";" and depth == 0:
                    break
            i -= 1
    for pos in sorted(remove, reverse=True):
        src = src[:pos] + re.sub(r"^const\s+", "", src[pos:], count=1)
    return src


def add_import(path, src):
    if "core/l10n/l10n.dart" in src:
        return src
    target = os.path.join(LIB, "core", "l10n", "l10n.dart")
    imp = os.path.relpath(target, os.path.dirname(path)).replace(os.sep, "/")
    lines = src.split("\n")
    last = max(i for i, l in enumerate(lines) if l.startswith("import "))
    lines.insert(last + 1, f"import '{imp}';")
    return "\n".join(lines)


def files():
    for f in sorted(glob.glob(os.path.join(LIB, "**", "*.dart"), recursive=True)):
        if rel(f) not in SKIP:
            yield f


def wrap():
    changed = 0
    for f in files():
        src = open(f, encoding="utf-8").read()
        new = wrap_text(src)
        if new != src:
            new = add_import(f, strip_consts(new))
            open(f, "w", encoding="utf-8").write(new)
            changed += 1
    print("archivos cambiados:", changed)


def keys():
    found = []
    for f in files():
        for lit in TR_LIT.findall(open(f, encoding="utf-8").read()):
            if lit[1:-1] not in found:
                found.append(lit[1:-1])
    return found


def build():
    sys.path.insert(0, os.path.dirname(__file__))
    from l10n_data import T, LANGS  # noqa
    lines = [
        "// Traducciones de KLK. La clave es el texto original en español.",
        "// Generado con tool/l10n.py build a partir de tool/l10n_data.py: no lo edites a mano.",
        "// ignore_for_file: lines_longer_than_80_chars",
        "const translations = <String, Map<String, String>>{",
    ]
    for i, lang in enumerate(LANGS):
        lines.append(f"  '{lang}': {{")
        for es, tr_ in T.items():
            v = tr_[i]
            if v:
                v = v.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$").replace("\n", "\\n")
                lines.append(f"    '{es}': '{v}',")
        lines.append("  },")
    lines.append("};")
    open(os.path.join(LIB, "core", "l10n", "strings.dart"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    missing = [k for k in keys() if k not in T]
    print("traducciones:", len(T), "· sin traducir:", len(missing))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "wrap":
        wrap()
    elif cmd == "build":
        build()
    else:
        sys.path.insert(0, os.path.dirname(__file__))
        try:
            from l10n_data import T  # noqa
        except ImportError:
            T = {}
        for k in keys():
            if k not in T:
                print(k)
