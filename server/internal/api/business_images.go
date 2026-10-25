package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/klk-app/klk-server/internal/store"
)

// Logo del negocio y fotos de los productos. Son PÚBLICAS, como el resto del
// perfil del negocio: el dueño las pone para que las vean sus clientes.

const (
	maxBusinessImage  = 512 << 10 // la app las reduce antes; esto es por si acaso
	maxBusinessImages = 250       // logo + 200 productos + margen
	// Una foto recién subida que aún no está en el perfil guardado no se borra
	// hasta pasado este tiempo (la app la sube y luego guarda el perfil).
	businessImageGrace = time.Hour
)

var businessImageTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

// POST /v1/business/me/images: subir el logo o la foto de un producto.
// Cuerpo: los bytes de la imagen. Devuelve {"id": "..."}.
func (s *Server) uploadBusinessImage(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if r.ContentLength > maxBusinessImage {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "la foto es demasiado grande")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBusinessImage))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "la foto es demasiado grande")
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_body", "no se pudo leer la foto")
		return
	}
	mime := http.DetectContentType(data)
	if len(data) == 0 || !businessImageTypes[mime] {
		writeErr(w, http.StatusBadRequest, "bad_image", "eso no es una foto (JPG, PNG o WebP)")
		return
	}
	now := time.Now()
	if !s.uploadCount.take(dev.AccountID, 1, maxUploadsPerDay, now) ||
		!s.uploadBytes.take(dev.AccountID, int64(len(data)), maxUploadBytesPerDay, now) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has subido demasiadas fotos hoy; prueba mañana")
		return
	}
	ctx := r.Context()
	n, err := s.store.CountBusinessImages(ctx, dev.AccountID)
	if err == nil && n >= maxBusinessImages {
		// Antes de rechazar, limpia las que ya no usa el perfil.
		if keep, ok := s.businessImagesInUse(r, dev.AccountID); ok {
			s.store.PruneBusinessImages(ctx, dev.AccountID, keep, now.Add(-businessImageGrace))
			n, err = s.store.CountBusinessImages(ctx, dev.AccountID)
		}
	}
	if err != nil {
		slog.Error("contar fotos de negocio", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if n >= maxBusinessImages {
		writeErr(w, http.StatusTooManyRequests, "too_many", "tienes demasiadas fotos; borra algún producto")
		return
	}
	img := store.BusinessImage{ID: uuid.NewString(), Owner: dev.AccountID, Mime: mime, Data: data, CreatedAt: now.UTC()}
	if err := s.store.PutBusinessImage(ctx, img); err != nil {
		slog.Error("guardar foto de negocio", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": img.ID})
}

// GET /v1/business/img/{id}: la foto, sin sesión (es pública y así sirve
// también para la página que se comparte por WhatsApp o Instagram).
func (s *Server) getBusinessImage(w http.ResponseWriter, r *http.Request) {
	img, err := s.store.GetBusinessImage(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	h := w.Header()
	h.Set("Content-Type", img.Mime)
	h.Set("Content-Length", fmt.Sprint(len(img.Data)))
	h.Set("Cache-Control", "public, max-age=31536000, immutable") // cada foto nueva tiene id nuevo
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'")
	w.Write(img.Data)
}

// imagesInData saca los ids de fotos que usa el perfil: el logo ("logo") y
// las de los productos ("items[].img").
func imagesInData(data []byte) map[string]bool {
	var d struct {
		Logo  string `json:"logo"`
		Items []struct {
			Img string `json:"img"`
		} `json:"items"`
	}
	keep := map[string]bool{}
	if json.Unmarshal(data, &d) != nil {
		return keep
	}
	if d.Logo != "" {
		keep[d.Logo] = true
	}
	for _, it := range d.Items {
		if it.Img != "" {
			keep[it.Img] = true
		}
	}
	return keep
}

func (s *Server) businessImagesInUse(r *http.Request, owner string) (map[string]bool, bool) {
	b, err := s.store.GetBusiness(r.Context(), owner)
	if errors.Is(err, store.ErrNotFound) {
		return map[string]bool{}, true
	}
	if err != nil {
		return nil, false
	}
	return imagesInData(b.Data), true
}

// pruneBusinessImages borra las fotos que el perfil ya no usa (cambió el logo,
// quitó un producto…). Se llama después de guardar el perfil.
func (s *Server) pruneBusinessImages(r *http.Request, owner string, data []byte) {
	if _, err := s.store.PruneBusinessImages(r.Context(), owner, imagesInData(data), time.Now().Add(-businessImageGrace)); err != nil {
		slog.Warn("limpiar fotos de negocio", "err", err)
	}
}

// ---------------------------------------------------------------------------
// Página pública del negocio: es el enlace que se comparte por WhatsApp,
// Instagram o los estados. Sale con su logo, horario y catálogo.
// ---------------------------------------------------------------------------

var businessKindLabels = map[string]string{
	"colmado":    "🏪 Colmado",
	"peluqueria": "💈 Peluquería / barbería",
	"belleza":    "💅 Uñas y belleza",
	"comida":     "🍽️ Comida",
	"tienda":     "🛍️ Tienda",
	"servicios":  "🔧 Servicios / taller",
	"otro":       "⭐ Negocio",
}

var dayShort = []string{"", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"}

type bizPageItem struct {
	Name, Price, Desc, Img string
}

type bizPage struct {
	Name, Kind, City, About, Address, Delivery, Hours string
	Initials, Logo, URL, Description                  string
	Verified                                          bool
	Items                                             []bizPageItem
	More                                              int
}

var businessTmpl = template.Must(template.New("n").Parse(`<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Name}} · KLK messenger</title>
<meta name="description" content="{{.Description}}">
<meta property="og:type" content="website">
<meta property="og:title" content="{{.Name}}">
<meta property="og:description" content="{{.Description}}">
<meta property="og:url" content="{{.URL}}">
{{if .Logo}}<meta property="og:image" content="{{.Logo}}">{{end}}
<meta name="twitter:card" content="summary">
<style>
:root{--navy:#002D62;--red:#CE1126}
*{box-sizing:border-box}body{margin:0;font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#F3F4F6;color:#111827}
header{background:var(--red);color:#fff;padding:28px 18px 22px}
.wrap{max-width:520px;margin:0 auto}
.top{display:flex;gap:14px;align-items:center}
.logo{width:72px;height:72px;border-radius:20px;background:#fff;color:var(--red);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:26px;flex:none;overflow:hidden}
.logo img{width:100%;height:100%;object-fit:cover}
h1{margin:0;font-size:24px;line-height:1.2}.sub{opacity:.92;font-size:14px;margin-top:2px}
.about{margin:14px 0 0;font-size:15px}
main{padding:14px 16px 32px}
.info{background:#fff;border-radius:16px;padding:6px 14px;margin-bottom:14px}
.info div{padding:9px 0;border-bottom:1px solid #EEF0F3;font-size:14.5px}.info div:last-child{border:0}
h2{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--red);margin:18px 4px 8px}
.item{display:flex;gap:12px;align-items:center;background:#fff;border-radius:14px;padding:10px;margin-bottom:8px}
.item img{width:56px;height:56px;border-radius:12px;object-fit:cover;flex:none;background:#EEF0F3}
.item b{display:block}.item small{color:#6B7280}.price{margin-left:auto;font-weight:700;white-space:nowrap}
.cta{background:var(--navy);color:#fff;border-radius:18px;padding:18px;margin-top:18px;text-align:center}
.cta p{margin:0 0 12px}
a.btn{display:block;text-decoration:none;font-weight:700;border-radius:999px;padding:12px;margin:8px 0;background:#fff;color:var(--navy)}
.more{color:#6B7280;font-size:14px;text-align:center}
</style></head><body>
<header><div class="wrap">
<div class="top">
<div class="logo">{{if .Logo}}<img src="{{.Logo}}" alt="">{{else}}{{.Initials}}{{end}}</div>
<div><h1>{{.Name}}{{if .Verified}} ✔︎{{end}}</h1>
<div class="sub">{{.Kind}}{{if .City}} · {{.City}}{{end}}</div></div>
</div>
{{if .About}}<p class="about">{{.About}}</p>{{end}}
</div></header>
<main class="wrap">
<div class="info">
{{if .Hours}}<div>🕒 {{.Hours}}</div>{{end}}
{{if .Address}}<div>📍 {{.Address}}</div>{{end}}
{{if .Delivery}}<div>🛵 {{.Delivery}}</div>{{end}}
</div>
{{if .Items}}<h2>Catálogo</h2>
{{range .Items}}<div class="item">{{if .Img}}<img src="{{.Img}}" alt="" loading="lazy">{{end}}
<div><b>{{.Name}}</b>{{if .Desc}}<small>{{.Desc}}</small>{{end}}</div>
<span class="price">{{.Price}}</span></div>
{{end}}{{if .More}}<p class="more">… y {{.More}} más en la app</p>{{end}}{{end}}
<div class="cta">
<p>Haz tu pedido por <b>KLK messenger</b>: busca «{{.Name}}» en <b>Comunidades → Negocios</b>.</p>
<a class="btn" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/download/android/KLK-messenger.apk">Descargar para Android</a>
<a class="btn" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/latest">Descargar para Windows</a>
</div>
</main></body></html>`))

// GET /n/{id}: la página pública del negocio.
func (s *Server) businessPage(w http.ResponseWriter, r *http.Request) {
	b, err := s.store.GetBusiness(r.Context(), r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	var d struct {
		About string `json:"about"`
		Addr  string `json:"addr"`
		Dlv   string `json:"dlv"`
		Cur   string `json:"cur"`
		Open  *int   `json:"open"`
		Close *int   `json:"close"`
		Days  []int  `json:"days"`
		Logo  string `json:"logo"`
		Items []struct {
			N   string   `json:"n"`
			P   *float64 `json:"p"`
			D   string   `json:"d"`
			Img string   `json:"img"`
		} `json:"items"`
	}
	json.Unmarshal(b.Data, &d)

	scheme := "https"
	if r.TLS == nil && r.Header.Get("X-Forwarded-Proto") == "" && strings.HasPrefix(r.Host, "localhost") {
		scheme = "http"
	}
	origin := scheme + "://" + r.Host
	img := func(id string) string {
		if _, err := uuid.Parse(id); err != nil {
			return ""
		}
		return origin + "/v1/business/img/" + id
	}
	cur := truncate(d.Cur, 4)
	if cur == "" {
		cur = "RD$"
	}
	p := bizPage{
		Name:     b.Name,
		Kind:     businessKindLabels[b.Kind],
		City:     b.City,
		About:    truncate(d.About, 300),
		Address:  truncate(d.Addr, 120),
		Delivery: truncate(d.Dlv, 80),
		Hours:    hoursLabel(d.Days, d.Open, d.Close),
		Initials: initials(b.Name),
		Logo:     img(d.Logo),
		URL:      origin + "/n/" + b.AccountID,
		Verified: b.Verified,
	}
	if p.Kind == "" {
		p.Kind = businessKindLabels["otro"]
	}
	p.Description = strings.TrimSpace(strings.Join(nonEmpty(p.Kind, p.City, p.Hours), " · "))
	if p.About != "" {
		p.Description = p.About
	}
	const show = 40
	for i, it := range d.Items {
		if i >= show {
			p.More = len(d.Items) - show
			break
		}
		price := "Consultar"
		if it.P != nil {
			price = money(*it.P, cur)
		}
		p.Items = append(p.Items, bizPageItem{Name: truncate(it.N, 60), Price: price, Desc: truncate(it.D, 200), Img: img(it.Img)})
	}

	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'")
	if err := businessTmpl.Execute(w, p); err != nil {
		slog.Warn("página de negocio", "err", err)
	}
}

func nonEmpty(xs ...string) []string {
	out := xs[:0:0]
	for _, x := range xs {
		if strings.TrimSpace(x) != "" {
			out = append(out, x)
		}
	}
	return out
}

func initials(name string) string {
	w := strings.Fields(name)
	switch len(w) {
	case 0:
		return "?"
	case 1:
		r := []rune(w[0])
		if len(r) > 2 {
			r = r[:2]
		}
		return strings.ToUpper(string(r))
	default:
		return strings.ToUpper(string([]rune(w[0])[:1]) + string([]rune(w[1])[:1]))
	}
}

func hourLabel(h int) string {
	switch {
	case h == 0 || h == 24:
		return "12:00 a. m."
	case h == 12:
		return "12:00 p. m."
	case h < 12:
		return fmt.Sprintf("%d:00 a. m.", h)
	default:
		return fmt.Sprintf("%d:00 p. m.", h-12)
	}
}

func hoursLabel(days []int, open, close *int) string {
	if open == nil || close == nil || *open < 0 || *open > 23 || *close < 1 || *close > 24 {
		return ""
	}
	seen := map[int]bool{}
	var ds []int
	for d := 1; d <= 7; d++ {
		for _, x := range days {
			if x == d && !seen[d] {
				seen[d] = true
				ds = append(ds, d)
			}
		}
	}
	var dl string
	switch {
	case len(ds) == 0:
		return ""
	case len(ds) == 7:
		dl = "Todos los días"
	case len(ds) > 2 && ds[len(ds)-1]-ds[0] == len(ds)-1:
		dl = dayShort[ds[0]] + " a " + dayShort[ds[len(ds)-1]]
	default:
		names := make([]string, len(ds))
		for i, d := range ds {
			names[i] = dayShort[d]
		}
		dl = strings.Join(names, ", ")
	}
	return dl + " · " + hourLabel(*open) + " – " + hourLabel(*close)
}

func money(v float64, cur string) string {
	if v == float64(int64(v)) {
		return cur + " " + groupThousands(fmt.Sprint(int64(v)))
	}
	s := fmt.Sprintf("%.2f", v)
	return cur + " " + groupThousands(s[:len(s)-3]) + "," + s[len(s)-2:]
}

func groupThousands(s string) string {
	if len(s) <= 3 {
		return s
	}
	var b strings.Builder
	pre := len(s) % 3
	if pre > 0 {
		b.WriteString(s[:pre])
	}
	for i := pre; i < len(s); i += 3 {
		if b.Len() > 0 {
			b.WriteByte('.')
		}
		b.WriteString(s[i : i+3])
	}
	return b.String()
}
