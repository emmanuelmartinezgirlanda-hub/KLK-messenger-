package api

import (
	"html/template"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Páginas para compartir por WhatsApp, Instagram o SMS: se ven con foto,
// título y descripción (vista previa) y llevan a descargar KLK.
//   /k/{id}     un canal
//   /i/{code}   una invitación (7 días de Plus gratis)
//   /u/{user}   el perfil de alguien (@usuario)

const (
	appStoreURL = "https://apps.apple.com/app/klk-messenger/id6823299468"
	androidURL  = "https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/download/android/KLK-messenger.apk"
	defaultOG   = "https://klkmessenger.com/img/og.png"
)

type sharePage struct {
	Title, Description, URL, Image string
	Emoji, Heading, Sub, Body      string
	Code                           string // invitación
	Steps                          []string
	Posts                          []string
}

var shareTmpl = template.Must(template.New("s").Parse(`<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Title}}</title>
<meta name="description" content="{{.Description}}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="KLK messenger">
<meta property="og:title" content="{{.Title}}">
<meta property="og:description" content="{{.Description}}">
<meta property="og:url" content="{{.URL}}">
<meta property="og:image" content="{{.Image}}">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="apple-itunes-app" content="app-id=6823299468">
<style>
:root{--navy:#002D62;--red:#CE1126}
*{box-sizing:border-box}body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:linear-gradient(160deg,var(--navy),#00183a 60%,var(--red));color:#111827;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:22px}
.card{background:#fff;border-radius:26px;max-width:420px;width:100%;padding:28px 22px;text-align:center;box-shadow:0 12px 44px rgba(0,0,0,.35)}
.emoji{font-size:58px;line-height:1}
h1{font-size:23px;margin:12px 0 2px;color:var(--navy)}
.sub{color:#6B7280;font-size:14.5px;margin:0 0 10px}
.body{color:#374151;margin:8px 0 14px}
.code{display:inline-block;font-weight:900;letter-spacing:3px;font-size:26px;color:var(--navy);border:2px dashed var(--navy);border-radius:14px;padding:8px 18px;margin:6px 0 4px}
.posts{text-align:left;margin:14px 0}
.post{background:#F3F4F6;border-radius:14px;padding:10px 12px;margin:8px 0;font-size:14.5px;white-space:pre-line}
ol{text-align:left;color:#374151;padding-left:22px;margin:10px 0 16px}
a.btn{display:block;text-decoration:none;font-weight:800;border-radius:999px;padding:13px;margin:9px 0}
a.p{background:var(--navy);color:#fff}a.s{border:2px solid var(--navy);color:var(--navy)}
.brand{margin-top:16px;color:#9CA3AF;font-size:13px}.brand b{color:var(--red)}
</style></head><body><div class="card">
<div class="emoji">{{.Emoji}}</div>
<h1>{{.Heading}}</h1>
{{if .Sub}}<p class="sub">{{.Sub}}</p>{{end}}
{{if .Body}}<p class="body">{{.Body}}</p>{{end}}
{{if .Code}}<div class="code">{{.Code}}</div>{{end}}
{{if .Posts}}<div class="posts">{{range .Posts}}<div class="post">{{.}}</div>{{end}}</div>{{end}}
{{if .Steps}}<ol>{{range .Steps}}<li>{{.}}</li>{{end}}</ol>{{end}}
<a class="btn p" href="` + appStoreURL + `">Descargar en iPhone (App Store)</a>
<a class="btn s" href="` + androidURL + `">Descargar para Android</a>
<div class="brand">¡Klk! · <b>KLK messenger</b>, la app de los dominicanos en el mundo 🇩🇴</div>
</div></body></html>`))

func origin(r *http.Request) string {
	scheme := "https"
	if r.TLS == nil && r.Header.Get("X-Forwarded-Proto") == "" && strings.HasPrefix(r.Host, "localhost") {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

func renderShare(w http.ResponseWriter, p sharePage) {
	if p.Image == "" {
		p.Image = defaultOG
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
	if err := shareTmpl.Execute(w, p); err != nil {
		slog.Warn("página para compartir", "err", err)
	}
}

func followersLabel(n int) string {
	switch {
	case n == 1:
		return "1 seguidor"
	case n >= 1000:
		return strconv.FormatFloat(float64(n)/1000, 'f', 1, 64) + " mil seguidores"
	default:
		return strconv.Itoa(n) + " seguidores"
	}
}

// GET /k/{id}: un canal.
func (s *Server) channelPage(w http.ResponseWriter, r *http.Request) {
	c, err := s.store.Channel(r.Context(), r.PathValue("id"), "00000000-0000-0000-0000-000000000000")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	posts, _ := s.store.ChanPosts(r.Context(), c.ID, zeroTime, 3)
	desc := c.Description
	if desc == "" {
		desc = "Canal en KLK messenger · " + followersLabel(c.Followers)
	}
	p := sharePage{
		Title:       c.Emoji + " " + c.Name + " · Canal de KLK",
		Description: truncate(desc, 200),
		URL:         origin(r) + "/k/" + c.ID,
		Emoji:       c.Emoji,
		Heading:     c.Name,
		Sub:         "Canal · " + followersLabel(c.Followers),
		Body:        truncate(c.Description, 300),
		Steps: []string{
			"Descarga KLK messenger (gratis).",
			"Ve a Estados → Canales → Buscar.",
			"Busca «" + truncate(c.Name, 40) + "» y toca Seguir.",
		},
	}
	for _, cp := range posts {
		t := truncate(cp.Body, 220)
		if cp.HasImage {
			t = "📷 " + t
		}
		if strings.TrimSpace(t) != "" {
			p.Posts = append(p.Posts, t)
		}
	}
	renderShare(w, p)
}

var inviteCodeRe = regexp.MustCompile(`^[A-Za-z0-9]{6,12}$`)

// GET /i/{code}: invitación de un amigo.
func (s *Server) invitePage(w http.ResponseWriter, r *http.Request) {
	code := strings.ToUpper(r.PathValue("code"))
	if !inviteCodeRe.MatchString(code) {
		http.NotFound(w, r)
		return
	}
	if !strings.HasPrefix(code, "KLK") {
		code = "KLK" + code
	}
	owner, err := s.store.InviteOwner(r.Context(), code)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	who := "Un amigo"
	if u, err := s.store.Username(r.Context(), owner); err == nil && u != "" {
		who = "@" + u
	}
	renderShare(w, sharePage{
		Title:       who + " te invita a KLK messenger 🎁",
		Description: "Te regala 7 días de KLK Plus gratis. La app de los dominicanos en el mundo: chats, llamadas y videollamadas cifradas.",
		URL:         origin(r) + "/i/" + code,
		Emoji:       "🎁",
		Heading:     who + " te invita a KLK",
		Sub:         "7 días de KLK Plus gratis con este código",
		Code:        code,
		Steps: []string{
			"Descarga KLK messenger y entra con tu número o tu correo.",
			"Ve a Ajustes → Invita y gana Plus.",
			"En «¿Te invitó un amigo?» pon el código de arriba.",
		},
	})
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9._]{3,30}$`)

// GET /u/{user}: el perfil de alguien.
func (s *Server) profilePage(w http.ResponseWriter, r *http.Request) {
	u := strings.TrimPrefix(r.PathValue("user"), "@")
	if !usernameRe.MatchString(u) {
		http.NotFound(w, r)
		return
	}
	if _, err := s.store.AccountByUsername(r.Context(), strings.ToLower(u)); err != nil {
		http.NotFound(w, r)
		return
	}
	renderShare(w, sharePage{
		Title:       "Escríbeme por KLK messenger: @" + u,
		Description: "Chats, llamadas y videollamadas cifradas. Gratis. La app de los dominicanos en el mundo 🇩🇴",
		URL:         origin(r) + "/u/" + u,
		Emoji:       "💬",
		Heading:     "@" + u,
		Sub:         "está en KLK messenger",
		Steps: []string{
			"Descarga KLK messenger (gratis).",
			"Toca el lápiz ✏️ para un chat nuevo.",
			"Busca @" + u + " y escríbele.",
		},
	})
}

var zeroTime time.Time
