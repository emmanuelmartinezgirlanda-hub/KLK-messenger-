package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
	_ "time/tzdata" // para contar los días con la hora de Irlanda aunque la imagen no traiga zonas

	"github.com/klk-app/klk-server/internal/store"
)

// Visitas de la página web (klkmessenger.com). La web avisa con un «ping» al
// abrirse; aquí solo se guardan contadores por día. Nada de IP, cookies ni
// datos de la persona: «personas» = navegadores que entran por primera vez ese día.

const (
	webKey      = "web_visits"
	webKeepDays = 400
	webMaxKeys  = 40 // páginas/orígenes distintos por día (el resto va a «otros»)
)

type webDay struct {
	V     int            `json:"v"`            // visitas (páginas vistas)
	P     int            `json:"p"`            // personas distintas ese día
	Pages map[string]int `json:"pg,omitempty"` // por página
	Src   map[string]int `json:"s,omitempty"`  // de dónde vienen
	Dev   map[string]int `json:"d,omitempty"`  // móvil / ordenador
	Ev    map[string]int `json:"e,omitempty"`  // toques en «Descargar»
}

var webEvents = map[string]bool{"appstore": true, "android": true, "windows": true}

var dublin = func() *time.Location {
	if l, err := time.LoadLocation("Europe/Dublin"); err == nil {
		return l
	}
	return time.UTC
}()

func webToday(now time.Time) string { return now.In(dublin).Format("2006-01-02") }

func (s *Server) loadWeb(r *http.Request) (map[string]*webDay, error) {
	raw, err := s.store.OwnerSetting(r.Context(), webKey)
	if errors.Is(err, store.ErrNotFound) {
		return map[string]*webDay{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]*webDay{}
	if json.Unmarshal(raw, &m) != nil {
		return map[string]*webDay{}, nil
	}
	return m, nil
}

func bump(m *map[string]int, k string) {
	if k == "" {
		return
	}
	if *m == nil {
		*m = map[string]int{}
	}
	if _, ok := (*m)[k]; !ok && len(*m) >= webMaxKeys {
		k = "otros"
	}
	(*m)[k]++
}

// cleanKey deja solo letras, números y . - / _ (y corta lo largo).
func cleanKey(s string, max int) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || strings.ContainsRune(".-/_", c) {
			b.WriteRune(c)
		}
		if b.Len() >= max {
			break
		}
	}
	return b.String()
}

func isBot(ua string) bool {
	ua = strings.ToLower(ua)
	if ua == "" {
		return true
	}
	for _, w := range []string{"bot", "crawl", "spider", "slurp", "headless", "preview", "facebookexternalhit", "lighthouse", "curl", "wget", "python"} {
		if strings.Contains(ua, w) {
			return true
		}
	}
	return false
}

// POST /v1/visit (público, desde la web). Cuerpo: {"p":"/","r":"instagram.com","n":1,"m":1}
// o, al tocar un botón de descarga, {"e":"appstore"}.
func (s *Server) webVisit(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if isBot(r.UserAgent()) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var in struct {
		P string `json:"p"`
		R string `json:"r"`
		N int    `json:"n"`
		M int    `json:"m"`
		E string `json:"e"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "visita no válida")
		return
	}
	s.webMu.Lock()
	defer s.webMu.Unlock()
	all, err := s.loadWeb(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server", "no se pudo guardar")
		return
	}
	now := time.Now()
	key := webToday(now)
	d := all[key]
	if d == nil {
		d = &webDay{}
		all[key] = d
	}
	if in.E != "" {
		if !webEvents[in.E] {
			writeErr(w, http.StatusBadRequest, "bad_request", "evento no válido")
			return
		}
		bump(&d.Ev, in.E)
	} else {
		d.V++
		if in.N == 1 {
			d.P++
		}
		page := cleanKey(in.P, 60)
		if !strings.HasPrefix(page, "/") {
			page = "/"
		}
		bump(&d.Pages, page)
		src := strings.TrimPrefix(cleanKey(in.R, 60), "www.")
		switch {
		case src == "" || strings.Contains(src, "klkmessenger"):
			src = "directo"
		case strings.Contains(src, "google"):
			src = "google"
		case strings.Contains(src, "instagram"):
			src = "instagram"
		case strings.Contains(src, "facebook") || src == "fb.com" || src == "m.me":
			src = "facebook"
		case strings.Contains(src, "tiktok"):
			src = "tiktok"
		case strings.Contains(src, "whatsapp") || src == "wa.me":
			src = "whatsapp"
		case src == "t.co" || strings.Contains(src, "twitter") || src == "x.com":
			src = "x / twitter"
		}
		bump(&d.Src, src)
		if in.M == 1 {
			bump(&d.Dev, "móvil")
		} else {
			bump(&d.Dev, "ordenador")
		}
	}
	// Borra los días muy viejos.
	limit := now.AddDate(0, 0, -webKeepDays).In(dublin).Format("2006-01-02")
	for k := range all {
		if k < limit {
			delete(all, k)
		}
	}
	raw, _ := json.Marshal(all)
	if err := s.store.SetOwnerSetting(r.Context(), webKey, raw); err != nil {
		writeErr(w, http.StatusInternalServerError, "server", "no se pudo guardar")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type kv struct {
	K string `json:"k"`
	V int    `json:"v"`
}

func topList(m map[string]int, n int) []kv {
	out := make([]kv, 0, len(m))
	for k, v := range m {
		out = append(out, kv{k, v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].V != out[j].V {
			return out[i].V > out[j].V
		}
		return out[i].K < out[j].K
	})
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// GET /admin/api/web: visitas de la web para el panel.
func (s *Server) adminWeb(w http.ResponseWriter, r *http.Request) {
	s.webMu.Lock()
	all, err := s.loadWeb(r)
	s.webMu.Unlock()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server", "no se pudo leer")
		return
	}
	now := time.Now()
	type dayOut struct {
		Day   string `json:"day"`
		Count int    `json:"count"` // visitas
		P     int    `json:"p"`     // personas
	}
	days := make([]dayOut, 0, 30)
	var v7, p7, v30, p30, vAll, pAll int
	pages, src, dev, ev := map[string]int{}, map[string]int{}, map[string]int{}, map[string]int{}
	for i := 29; i >= 0; i-- {
		k := now.AddDate(0, 0, -i).In(dublin).Format("2006-01-02")
		d := all[k]
		if d == nil {
			d = &webDay{}
		}
		days = append(days, dayOut{k, d.V, d.P})
		v30 += d.V
		p30 += d.P
		if i < 7 {
			v7 += d.V
			p7 += d.P
		}
		for a, b := range d.Pages {
			pages[a] += b
		}
		for a, b := range d.Src {
			src[a] += b
		}
		for a, b := range d.Dev {
			dev[a] += b
		}
		for a, b := range d.Ev {
			ev[a] += b
		}
	}
	for _, d := range all {
		vAll += d.V
		pAll += d.P
	}
	today := days[len(days)-1]
	writeJSON(w, http.StatusOK, map[string]any{
		"days":   days,
		"today":  map[string]int{"v": today.Count, "p": today.P},
		"week":   map[string]int{"v": v7, "p": p7},
		"month":  map[string]int{"v": v30, "p": p30},
		"all":    map[string]int{"v": vAll, "p": pAll},
		"pages":  topList(pages, 10),
		"src":    topList(src, 10),
		"dev":    topList(dev, 5),
		"events": ev,
	})
}
