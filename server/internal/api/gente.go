package api

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/klk-app/klk-server/internal/store"
)

// KLK Mi Gente: el muro público dentro de KLK. La gente publica texto y fotos,
// da me gusta y comenta. Es PÚBLICO para los usuarios de KLK (no va cifrado
// como los chats); por eso se puede denunciar y el dueño puede borrar.

const (
	maxGenteText      = 2000
	maxGenteComment   = 1000
	maxGenteName      = 40
	maxGentePhotos    = 4
	maxGenteImage     = 1 << 20 // 1 MB (la app las reduce antes)
	maxGentePostsDay  = 30
	maxGenteCommsDay  = 300
	maxGenteLikesDay  = 2000
	maxGenteImagesDay = 120
	// Marca de las denuncias de Mi Gente (el panel la reconoce para poder borrar).
	genteReportPost    = "[Mi Gente] publicación "
	genteReportComment = "[Mi Gente] comentario "
)

func (s *Server) genteRoutes(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/gente/me", s.authed(s.genteSetProfile))
	mux.HandleFunc("GET /v1/gente/feed", s.authed(s.genteFeed))
	mux.HandleFunc("POST /v1/gente/posts", s.authed(s.genteCreatePost))
	mux.HandleFunc("GET /v1/gente/posts/{id}", s.authed(s.genteGetPost))
	mux.HandleFunc("DELETE /v1/gente/posts/{id}", s.authed(s.genteDeletePost))
	mux.HandleFunc("PUT /v1/gente/posts/{id}/sold", s.authed(s.genteSold))
	mux.HandleFunc("DELETE /v1/gente/posts/{id}/sold", s.authed(s.genteSold))
	mux.HandleFunc("PUT /v1/gente/posts/{id}/like", s.authed(s.genteLike))
	mux.HandleFunc("DELETE /v1/gente/posts/{id}/like", s.authed(s.genteLike))
	mux.HandleFunc("GET /v1/gente/posts/{id}/comments", s.authed(s.genteComments))
	mux.HandleFunc("POST /v1/gente/posts/{id}/comments", s.authed(s.genteAddComment))
	mux.HandleFunc("POST /v1/gente/posts/{id}/report", s.authed(s.genteReportPost))
	mux.HandleFunc("DELETE /v1/gente/comments/{id}", s.authed(s.genteDeleteComment))
	mux.HandleFunc("POST /v1/gente/comments/{id}/report", s.authed(s.genteReportComment))
	mux.HandleFunc("POST /v1/gente/images", s.authed(s.genteUploadImage))
	mux.HandleFunc("GET /v1/gente/blocks", s.authed(s.genteListBlocks))
	mux.HandleFunc("PUT /v1/gente/blocks/{id}", s.authed(s.genteBlock))
	mux.HandleFunc("DELETE /v1/gente/blocks/{id}", s.authed(s.genteBlock))
	mux.HandleFunc("GET /v1/gente/img/{id}", s.genteImage)

	mux.HandleFunc("GET /admin/api/gente", s.admin(s.adminGentePosts))
	mux.HandleFunc("DELETE /admin/api/gente/posts/{id}", s.admin(s.adminGenteDeletePost))
	mux.HandleFunc("DELETE /admin/api/gente/comments/{id}", s.admin(s.adminGenteDeleteComment))
}

func genteErr(w http.ResponseWriter, err error, what string) {
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", what+" ya no existe")
		return
	}
	slog.Error("mi gente", "what", what, "err", err)
	writeErr(w, http.StatusInternalServerError, "internal", "error interno")
}

// cleanText quita espacios de más y caracteres de control (deja los saltos de línea).
func cleanText(s string, max int) (string, bool) {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s))
	return s, utf8.ValidString(s) && utf8.RuneCountInString(s) <= max
}

// ---------- Perfil ----------

// PUT /v1/gente/me {name, photo}: cómo salgo yo en Mi Gente.
func (s *Server) genteSetProfile(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Name  string `json:"name"`
		Photo string `json:"photo"`
		Rules bool   `json:"rules"` // acepta las normas de Mi Gente
	}
	if !readJSON(w, r, &req) {
		return
	}
	name, ok := cleanText(req.Name, maxGenteName)
	name = strings.Join(strings.Fields(name), " ")
	if !ok || name == "" {
		writeErr(w, http.StatusBadRequest, "bad_name", "pon un nombre de hasta 40 letras")
		return
	}
	if req.Photo != "" {
		img, err := s.store.GetGenteImage(r.Context(), req.Photo)
		if err != nil || img.Owner != dev.AccountID {
			writeErr(w, http.StatusBadRequest, "bad_photo", "esa foto no es tuya")
			return
		}
	}
	p := store.GenteProfile{AccountID: dev.AccountID, Name: name, Photo: req.Photo, UpdatedAt: time.Now().UTC()}
	if req.Rules {
		p.RulesAt = p.UpdatedAt
	}
	if err := s.store.PutGenteProfile(r.Context(), p); err != nil {
		genteErr(w, err, "la cuenta")
		return
	}
	writeJSON(w, http.StatusOK, store.GenteAuthor{ID: p.AccountID, Name: p.Name, Photo: p.Photo})
}

// ---------- Normas y bloqueos ----------

// rulesOK exige haber aceptado las normas de Mi Gente para publicar o comentar.
func (s *Server) rulesOK(w http.ResponseWriter, r *http.Request, acc string) bool {
	p, err := s.store.GetGenteProfile(r.Context(), acc)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		genteErr(w, err, "la cuenta")
		return false
	}
	if err != nil || p.RulesAt.IsZero() {
		writeErr(w, http.StatusForbidden, "rules_required", "acepta las normas de Mi Gente para publicar")
		return false
	}
	return true
}

// hiddenFor: cuentas que [acc] no ve ni con las que se cruza (bloqueó o le bloquearon).
func (s *Server) hiddenFor(r *http.Request, acc string) (map[string]bool, error) {
	blocked, by, err := s.store.GenteBlocks(r.Context(), acc)
	if err != nil {
		return nil, err
	}
	h := map[string]bool{}
	for _, x := range append(blocked, by...) {
		h[x] = true
	}
	return h, nil
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// GET /v1/gente/blocks: a quién bloqueé.
func (s *Server) genteListBlocks(w http.ResponseWriter, r *http.Request) {
	blocked, _, err := s.store.GenteBlocks(r.Context(), deviceFrom(r).AccountID)
	if err != nil {
		genteErr(w, err, "la lista")
		return
	}
	out := []store.GenteAuthor{}
	for _, id := range blocked {
		a := store.GenteAuthor{ID: id}
		if p, err := s.store.GetGenteProfile(r.Context(), id); err == nil {
			a.Name, a.Photo = p.Name, p.Photo
		}
		out = append(out, a)
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": out})
}

// PUT/DELETE /v1/gente/blocks/{id}: bloquear o desbloquear a alguien en Mi Gente.
// Ya no ves lo suyo, no ve lo tuyo y no puede comentar ni dar me gusta a lo tuyo.
func (s *Server) genteBlock(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	id := r.PathValue("id")
	if id == dev.AccountID {
		writeErr(w, http.StatusBadRequest, "self", "no puedes bloquearte a ti mismo")
		return
	}
	if err := s.store.SetGenteBlock(r.Context(), dev.AccountID, id, r.Method == http.MethodPut); err != nil {
		genteErr(w, err, "esa cuenta")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Publicaciones ----------

// GET /v1/gente/feed?country=DO&author=…&before=2026-…: el muro, lo más nuevo primero.
func (s *Server) genteFeed(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	query := store.GenteQuery{Viewer: deviceFrom(r).AccountID, Country: q.Get("country"), Author: q.Get("author"),
		Sale: q.Get("sale") == "1", Limit: 20}
	if query.Country != "" && !countryRe.MatchString(query.Country) {
		writeErr(w, http.StatusBadRequest, "bad_country", "país no válido")
		return
	}
	if b := q.Get("before"); b != "" {
		t, err := time.Parse(time.RFC3339Nano, b)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_before", "fecha no válida")
			return
		}
		query.Before = t
	}
	hidden, err := s.hiddenFor(r, query.Viewer)
	if err != nil {
		genteErr(w, err, "el muro")
		return
	}
	if hidden[query.Author] {
		writeJSON(w, http.StatusOK, map[string]any{"posts": []store.GentePost{}})
		return
	}
	query.Hide = keys(hidden)
	list, err := s.store.ListGentePosts(r.Context(), query)
	if err != nil {
		genteErr(w, err, "el muro")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": list})
}

// POST /v1/gente/posts {text, photos, country}
func (s *Server) genteCreatePost(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Text    string   `json:"text"`
		Photos  []string `json:"photos"`
		Country string   `json:"country"`
		Sale    *struct {
			Price    float64 `json:"price"`
			Currency string  `json:"currency"`
		} `json:"sale"` // «Vendo»: precio y moneda
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if !readJSON(w, r, &req) {
		return
	}
	text, ok := cleanText(req.Text, maxGenteText)
	switch {
	case !ok:
		writeErr(w, http.StatusBadRequest, "too_long", "el texto es demasiado largo (máximo 2000 letras)")
		return
	case len(req.Photos) > maxGentePhotos:
		writeErr(w, http.StatusBadRequest, "too_many_photos", "máximo 4 fotos por publicación")
		return
	case text == "" && len(req.Photos) == 0:
		writeErr(w, http.StatusBadRequest, "empty", "escribe algo o pon una foto")
		return
	case req.Country != "" && !countryRe.MatchString(req.Country):
		writeErr(w, http.StatusBadRequest, "bad_country", "país no válido")
		return
	}
	if req.Sale != nil {
		switch {
		case text == "":
			writeErr(w, http.StatusBadRequest, "sale_text", "di qué vendes")
			return
		case req.Sale.Price <= 0 || req.Sale.Price > 10_000_000:
			writeErr(w, http.StatusBadRequest, "bad_price", "pon un precio válido")
			return
		case !saleCurrencies[req.Sale.Currency]:
			writeErr(w, http.StatusBadRequest, "bad_currency", "moneda no válida")
			return
		}
	}
	if !s.rulesOK(w, r, dev.AccountID) {
		return
	}
	seen := map[string]bool{}
	for _, id := range req.Photos {
		img, err := s.store.GetGenteImage(r.Context(), id)
		if err != nil || img.Owner != dev.AccountID || seen[id] {
			writeErr(w, http.StatusBadRequest, "bad_photo", "una de las fotos no vale; vuelve a elegirla")
			return
		}
		seen[id] = true
	}
	if !s.gentePosts.take(dev.AccountID, 1, maxGentePostsDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has publicado mucho hoy; sigue mañana")
		return
	}
	p := store.GentePost{
		ID:        uuid.NewString(),
		Author:    store.GenteAuthor{ID: dev.AccountID},
		Country:   req.Country,
		Text:      text,
		Photos:    append([]string{}, req.Photos...),
		CreatedAt: time.Now().UTC(),
	}
	if req.Sale != nil {
		p.Sale, p.Price, p.Currency = true, math.Round(req.Sale.Price*100)/100, req.Sale.Currency
	}
	if err := s.store.AddGentePost(r.Context(), p); err != nil {
		genteErr(w, err, "la cuenta")
		return
	}
	out, err := s.store.GetGentePost(r.Context(), p.ID, dev.AccountID)
	if err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) genteGetPost(w http.ResponseWriter, r *http.Request) {
	p, ok := s.visiblePost(w, r, r.PathValue("id"))
	if ok {
		writeJSON(w, http.StatusOK, p)
	}
}

// visiblePost: la publicación, si existe y no hay un bloqueo entre su autor y yo.
func (s *Server) visiblePost(w http.ResponseWriter, r *http.Request, id string) (store.GentePost, bool) {
	me := deviceFrom(r).AccountID
	p, err := s.store.GetGentePost(r.Context(), id, me)
	if err != nil {
		genteErr(w, err, "la publicación")
		return p, false
	}
	hidden, err := s.hiddenFor(r, me)
	if err != nil {
		genteErr(w, err, "la publicación")
		return p, false
	}
	if hidden[p.Author.ID] {
		writeErr(w, http.StatusNotFound, "not_found", "la publicación ya no existe")
		return p, false
	}
	return p, true
}

// DELETE /v1/gente/posts/{id}: solo quien la publicó.
func (s *Server) genteDeletePost(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	p, err := s.store.GetGentePost(r.Context(), r.PathValue("id"), "")
	if err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	if p.Author.ID != dev.AccountID {
		writeErr(w, http.StatusForbidden, "forbidden", "solo puedes borrar lo que publicaste tú")
		return
	}
	if err := s.store.DeleteGentePost(r.Context(), p.ID); err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

var saleCurrencies = map[string]bool{"RD$": true, "US$": true, "€": true, "£": true}

// PUT/DELETE /v1/gente/posts/{id}/sold: quien vende marca (o quita) «Vendido».
func (s *Server) genteSold(w http.ResponseWriter, r *http.Request) {
	p, err := s.store.GetGentePost(r.Context(), r.PathValue("id"), "")
	if err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	if p.Author.ID != deviceFrom(r).AccountID {
		writeErr(w, http.StatusForbidden, "forbidden", "solo quien vende puede marcarlo")
		return
	}
	if !p.Sale {
		writeErr(w, http.StatusBadRequest, "not_sale", "esta publicación no es una venta")
		return
	}
	if err := s.store.SetGenteSold(r.Context(), p.ID, r.Method == http.MethodPut); err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// PUT/DELETE /v1/gente/posts/{id}/like
func (s *Server) genteLike(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	on := r.Method == http.MethodPut
	if on && !s.genteLikes.take(dev.AccountID, 1, maxGenteLikesDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "demasiados me gusta hoy")
		return
	}
	id := r.PathValue("id")
	if _, ok := s.visiblePost(w, r, id); !ok {
		return
	}
	n, err := s.store.SetGenteLike(r.Context(), id, dev.AccountID, on)
	if err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"likes": n, "liked": on})
}

// ---------- Comentarios ----------

func (s *Server) genteComments(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.visiblePost(w, r, id); !ok {
		return
	}
	list, err := s.store.ListGenteComments(r.Context(), id, 200)
	if err != nil {
		genteErr(w, err, "los comentarios")
		return
	}
	hidden, err := s.hiddenFor(r, deviceFrom(r).AccountID)
	if err != nil {
		genteErr(w, err, "los comentarios")
		return
	}
	out := list[:0]
	for _, c := range list {
		if !hidden[c.Author.ID] {
			out = append(out, c)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": out})
}

func (s *Server) genteAddComment(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Text string `json:"text"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if !readJSON(w, r, &req) {
		return
	}
	text, ok := cleanText(req.Text, maxGenteComment)
	if !ok || text == "" {
		writeErr(w, http.StatusBadRequest, "bad_text", "escribe un comentario de hasta 1000 letras")
		return
	}
	id := r.PathValue("id")
	if _, ok := s.visiblePost(w, r, id); !ok {
		return
	}
	if !s.rulesOK(w, r, dev.AccountID) {
		return
	}
	if !s.genteComms.take(dev.AccountID, 1, maxGenteCommsDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has comentado mucho hoy; sigue mañana")
		return
	}
	c := store.GenteComment{ID: uuid.NewString(), PostID: id, Author: store.GenteAuthor{ID: dev.AccountID}, Text: text,
		CreatedAt: time.Now().UTC()}
	if err := s.store.AddGenteComment(r.Context(), c); err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	out, err := s.store.GetGenteComment(r.Context(), c.ID)
	if err != nil {
		genteErr(w, err, "el comentario")
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

// DELETE /v1/gente/comments/{id}: quien lo escribió o el dueño de la publicación.
func (s *Server) genteDeleteComment(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	c, err := s.store.GetGenteComment(r.Context(), r.PathValue("id"))
	if err != nil {
		genteErr(w, err, "el comentario")
		return
	}
	if c.Author.ID != dev.AccountID {
		p, err := s.store.GetGentePost(r.Context(), c.PostID, "")
		if err != nil || p.Author.ID != dev.AccountID {
			writeErr(w, http.StatusForbidden, "forbidden", "no puedes borrar este comentario")
			return
		}
	}
	if err := s.store.DeleteGenteComment(r.Context(), c.ID); err != nil {
		genteErr(w, err, "el comentario")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Denuncias ----------

func (s *Server) genteReport(w http.ResponseWriter, r *http.Request, reported string, messages []string) {
	dev := deviceFrom(r)
	var req struct {
		Reason string `json:"reason"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !reportReasons[req.Reason] {
		writeErr(w, http.StatusBadRequest, "bad_reason", "motivo no válido")
		return
	}
	if reported == dev.AccountID {
		writeErr(w, http.StatusBadRequest, "self", "no puedes denunciarte a ti mismo")
		return
	}
	n, err := s.store.ReportsBy(r.Context(), dev.AccountID, time.Now().Add(-24*time.Hour))
	if err != nil {
		genteErr(w, err, "la denuncia")
		return
	}
	if n >= maxReportsPerDay {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has enviado demasiadas denuncias hoy")
		return
	}
	for i, m := range messages {
		messages[i] = truncate(m, maxReportMessageLen)
	}
	rep := store.Report{ID: uuid.NewString(), Reporter: dev.AccountID, Reported: reported, Reason: req.Reason,
		Messages: messages, CreatedAt: time.Now()}
	if err := s.store.AddReport(r.Context(), rep); err != nil {
		genteErr(w, err, "la denuncia")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) genteReportPost(w http.ResponseWriter, r *http.Request) {
	p, err := s.store.GetGentePost(r.Context(), r.PathValue("id"), "")
	if err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	msgs := []string{genteReportPost + p.ID}
	if p.Text != "" {
		msgs = append(msgs, p.Text)
	}
	if len(p.Photos) > 0 {
		msgs = append(msgs, fmt.Sprintf("(%d foto%s)", len(p.Photos), map[bool]string{true: "s"}[len(p.Photos) > 1]))
	}
	s.genteReport(w, r, p.Author.ID, msgs)
}

func (s *Server) genteReportComment(w http.ResponseWriter, r *http.Request) {
	c, err := s.store.GetGenteComment(r.Context(), r.PathValue("id"))
	if err != nil {
		genteErr(w, err, "el comentario")
		return
	}
	s.genteReport(w, r, c.Author.ID, []string{genteReportComment + c.ID, c.Text})
}

// ---------- Fotos ----------

// POST /v1/gente/images: sube una foto (para una publicación o la foto de perfil).
func (s *Server) genteUploadImage(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if r.ContentLength > maxGenteImage {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "la foto es demasiado grande")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxGenteImage))
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
	if !s.genteImages.take(dev.AccountID, 1, maxGenteImagesDay, now) ||
		!s.uploadBytes.take(dev.AccountID, int64(len(data)), maxUploadBytesPerDay, now) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has subido demasiadas fotos hoy; prueba mañana")
		return
	}
	img := store.BusinessImage{ID: uuid.NewString(), Owner: dev.AccountID, Mime: mime, Data: data, CreatedAt: now.UTC()}
	if err := s.store.PutGenteImage(r.Context(), img); err != nil {
		genteErr(w, err, "la cuenta")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": img.ID})
}

// GET /v1/gente/img/{id}: la foto (id imposible de adivinar; caché larga).
func (s *Server) genteImage(w http.ResponseWriter, r *http.Request) {
	img, err := s.store.GetGenteImage(r.Context(), r.PathValue("id"))
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
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'")
	w.Write(img.Data)
}

// ---------- Panel del dueño ----------

// GET /admin/api/gente: las últimas publicaciones (para revisar y borrar).
func (s *Server) adminGentePosts(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.ListGentePosts(r.Context(), store.GenteQuery{Limit: 50})
	if err != nil {
		genteErr(w, err, "el muro")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": list})
}

func (s *Server) adminGenteDeletePost(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteGentePost(r.Context(), r.PathValue("id")); err != nil {
		genteErr(w, err, "la publicación")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminGenteDeleteComment(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteGenteComment(r.Context(), r.PathValue("id")); err != nil {
		genteErr(w, err, "el comentario")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
