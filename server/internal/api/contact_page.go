package api

import (
	"html/template"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

var contactDigits = regexp.MustCompile(`^\d{8,15}$`)

// Página que se abre al escanear el código QR de alguien con la cámara del
// móvil (sin KLK): dice de quién es y cómo descargar la app.
var contactTmpl = template.Must(template.New("c").Parse(`<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>{{.Name}} en KLK messenger</title>
<style>
:root{--navy:#002D62;--red:#C62D35}
*{box-sizing:border-box}body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--navy);color:#fff;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:#fff;color:#111827;border-radius:24px;max-width:380px;width:100%;padding:28px 22px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.3)}
.bubble{display:inline-block;background:var(--red);color:#fff;font-weight:900;font-style:italic;font-size:34px;padding:6px 22px;border-radius:18px;border:4px solid #fff;box-shadow:0 0 0 2px var(--red);transform:rotate(-5deg)}
h1{font-size:22px;margin:18px 0 4px}p{color:#4B5563;margin:6px 0 18px}
.phone{font-weight:700;color:var(--navy)}
a.btn{display:block;text-decoration:none;font-weight:700;border-radius:999px;padding:13px;margin:10px 0}
a.p{background:var(--navy);color:#fff}a.s{border:2px solid var(--navy);color:var(--navy)}
small{color:#6B7280}
</style></head><body><div class="card">
<div class="bubble">¡Klk!</div>
<h1>{{.Name}} te espera en KLK messenger</h1>
<p>Número: <span class="phone">{{.Phone}}</span></p>
<p>Abre KLK messenger, toca <b>⋮ → Escanear código QR</b> y apunta a este código, o escríbele a su número.</p>
<a class="btn p" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/download/android/KLK-messenger.apk">Descargar para Android</a>
<a class="btn s" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/latest">Descargar para Windows</a>
<small>Para iPhone, pídele el enlace a quien te pasó este código.</small>
</div></body></html>`))

func (s *Server) contactPage(w http.ResponseWriter, r *http.Request) {
	digits := r.PathValue("digits")
	if !contactDigits.MatchString(digits) {
		http.NotFound(w, r)
		return
	}
	name := strings.TrimSpace(r.URL.Query().Get("n"))
	if name == "" || !utf8.ValidString(name) {
		name = "Tu contacto"
	}
	name = truncate(name, 40)
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
	contactTmpl.Execute(w, map[string]string{"Name": name, "Phone": "+" + digits})
}
