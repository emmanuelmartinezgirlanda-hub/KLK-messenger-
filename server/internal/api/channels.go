package api

import (
	"bytes"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/klk-app/klk-server/internal/store"
)

// Canales: el dueño publica y quien lo sigue lo lee. Son públicos.
const (
	maxOwnedChannels = 5
	maxChanName      = 60
	maxChanDesc      = 300
	maxChanPost      = 4000
	maxChanImage     = 400 << 10 // la app la reduce antes de subirla
)

func validJPEGorPNG(b []byte) bool {
	return bytes.HasPrefix(b, []byte{0xFF, 0xD8, 0xFF}) || bytes.HasPrefix(b, []byte("\x89PNG"))
}

func cleanEmoji(e string) string {
	e = strings.TrimSpace(e)
	if e == "" || utf8.RuneCountInString(e) > 8 {
		return "📢"
	}
	return e
}

// GET /v1/channels?q=: buscar canales (sin q, los más seguidos).
// GET /v1/channels?mine=1: los que sigo y los míos.
func (s *Server) listChannels(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var out []store.Channel
	var err error
	if r.URL.Query().Get("mine") == "1" {
		out, err = s.store.MyChannels(r.Context(), dev.AccountID)
	} else {
		q := r.URL.Query().Get("q")
		if utf8.RuneCountInString(q) > 60 {
			q = string([]rune(q)[:60])
		}
		out, err = s.store.Channels(r.Context(), q, dev.AccountID, 50)
	}
	if err != nil {
		slog.Error("canales", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": out})
}

type channelReq struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Emoji       string `json:"emoji"`
}

func (s *Server) checkChannelReq(w http.ResponseWriter, req *channelReq) bool {
	req.Name = strings.TrimSpace(req.Name)
	req.Description = strings.TrimSpace(req.Description)
	if n := utf8.RuneCountInString(req.Name); n < 2 || n > maxChanName {
		writeErr(w, http.StatusBadRequest, "bad_name", "el nombre del canal debe tener entre 2 y 60 letras")
		return false
	}
	if utf8.RuneCountInString(req.Description) > maxChanDesc {
		writeErr(w, http.StatusBadRequest, "bad_description", "la descripción es demasiado larga")
		return false
	}
	return !rejectOffensive(w, req.Name, req.Description)
}

// POST /v1/channels {name, description, emoji}: crear un canal.
func (s *Server) createChannel(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req channelReq
	if !readJSON(w, r, &req) || !s.checkChannelReq(w, &req) {
		return
	}
	n, err := s.store.CountOwnedChannels(r.Context(), dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if n >= maxOwnedChannels {
		writeErr(w, http.StatusConflict, "too_many", "puedes tener hasta 5 canales")
		return
	}
	c, err := s.store.CreateChannel(r.Context(), store.Channel{
		OwnerID: dev.AccountID, Name: req.Name, Description: req.Description, Emoji: cleanEmoji(req.Emoji),
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, c)
}

// ownChannel devuelve el canal si es de quien llama (si no, ya respondió).
func (s *Server) ownChannel(w http.ResponseWriter, r *http.Request) (store.Channel, bool) {
	dev := deviceFrom(r)
	c, err := s.store.Channel(r.Context(), r.PathValue("id"), dev.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese canal no existe")
		return c, false
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return c, false
	}
	if !c.Mine {
		writeErr(w, http.StatusForbidden, "not_owner", "solo el dueño del canal puede hacer eso")
		return c, false
	}
	return c, true
}

// GET /v1/channels/{id}
func (s *Server) getChannel(w http.ResponseWriter, r *http.Request) {
	c, err := s.store.Channel(r.Context(), r.PathValue("id"), deviceFrom(r).AccountID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese canal no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, c)
}

// PUT /v1/channels/{id}: cambiar nombre, descripción o emoji.
func (s *Server) updateChannel(w http.ResponseWriter, r *http.Request) {
	c, ok := s.ownChannel(w, r)
	if !ok {
		return
	}
	var req channelReq
	if !readJSON(w, r, &req) || !s.checkChannelReq(w, &req) {
		return
	}
	c.Name, c.Description, c.Emoji = req.Name, req.Description, cleanEmoji(req.Emoji)
	if err := s.store.UpdateChannel(r.Context(), c); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, c)
}

// DELETE /v1/channels/{id}: borrar mi canal.
func (s *Server) deleteChannel(w http.ResponseWriter, r *http.Request) {
	c, ok := s.ownChannel(w, r)
	if !ok {
		return
	}
	if err := s.store.DeleteChannel(r.Context(), c.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /v1/channels/{id}/follow: seguir.  DELETE: dejar de seguir.
func (s *Server) followChannel(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	c, err := s.store.Channel(r.Context(), r.PathValue("id"), dev.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese canal no existe")
		return
	}
	if err == nil {
		err = s.store.FollowChannel(r.Context(), c.ID, dev.AccountID, r.Method != http.MethodDelete)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/channels/{id}/posts?before=RFC3339
func (s *Server) channelPosts(w http.ResponseWriter, r *http.Request) {
	c, err := s.store.Channel(r.Context(), r.PathValue("id"), deviceFrom(r).AccountID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese canal no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	var before time.Time
	if b := r.URL.Query().Get("before"); b != "" {
		before, _ = time.Parse(time.RFC3339Nano, b)
	}
	posts, err := s.store.ChanPosts(r.Context(), c.ID, before, 50)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
}

// POST /v1/channels/{id}/posts {body, image(base64)}: publicar (solo el dueño).
func (s *Server) addChannelPost(w http.ResponseWriter, r *http.Request) {
	c, ok := s.ownChannel(w, r)
	if !ok {
		return
	}
	var req struct {
		Body  string `json:"body"`
		Image []byte `json:"image"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.Body = strings.TrimSpace(req.Body)
	if (req.Body == "" && len(req.Image) == 0) || utf8.RuneCountInString(req.Body) > maxChanPost {
		writeErr(w, http.StatusBadRequest, "bad_body", "escribe algo (hasta 4000 letras)")
		return
	}
	if len(req.Image) > 0 && (len(req.Image) > maxChanImage || !validJPEGorPNG(req.Image)) {
		writeErr(w, http.StatusBadRequest, "bad_image", "esa foto no vale (JPEG o PNG, hasta 400 KB)")
		return
	}
	if rejectOffensive(w, req.Body) {
		return
	}
	p, err := s.store.AddChanPost(r.Context(), store.ChanPost{ChannelID: c.ID, Body: req.Body, Image: req.Image})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// DELETE /v1/channels/{id}/posts/{pid}
func (s *Server) deleteChannelPost(w http.ResponseWriter, r *http.Request) {
	c, ok := s.ownChannel(w, r)
	if !ok {
		return
	}
	err := s.store.DeleteChanPost(r.Context(), c.ID, r.PathValue("pid"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "esa publicación ya no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/channels/{id}/posts/{pid}/image
func (s *Server) channelPostImage(w http.ResponseWriter, r *http.Request) {
	img, err := s.store.ChanPostImage(r.Context(), r.PathValue("id"), r.PathValue("pid"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no hay foto")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	ct := "image/jpeg"
	if bytes.HasPrefix(img, []byte("\x89PNG")) {
		ct = "image/png"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	_, _ = w.Write(img)
}

// PUT /v1/channels/{id}/logo {"image": base64}: poner el logo (solo el dueño).
// DELETE /v1/channels/{id}/logo: quitarlo (vuelve el emoji).
func (s *Server) setChannelLogo(w http.ResponseWriter, r *http.Request) {
	c, ok := s.ownChannel(w, r)
	if !ok {
		return
	}
	var img []byte
	if r.Method != http.MethodDelete {
		var req struct {
			Image []byte `json:"image"`
		}
		if !readJSON(w, r, &req) {
			return
		}
		if len(req.Image) == 0 || len(req.Image) > maxChanImage || !validJPEGorPNG(req.Image) {
			writeErr(w, http.StatusBadRequest, "bad_image", "ese logo no vale (JPEG o PNG, hasta 400 KB)")
			return
		}
		img = req.Image
	}
	v, err := s.store.SetChannelLogo(r.Context(), c.ID, img)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"logoV": v})
}

// GET /v1/channels/{id}/logo
func (s *Server) channelLogo(w http.ResponseWriter, r *http.Request) {
	img, err := s.store.ChannelLogo(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "sin logo")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	ct := "image/jpeg"
	if bytes.HasPrefix(img, []byte("\x89PNG")) {
		ct = "image/png"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = w.Write(img)
}
