package api_test

import "testing"

func TestVisitasWeb(t *testing.T) {
	e := newAdminEnv(t)
	// Una persona nueva desde Instagram en el móvil, luego otra página, y un toque en el App Store.
	if s := e.do("POST", "/v1/visit", "", map[string]any{"p": "/", "r": "l.instagram.com", "n": 1, "m": 1}, nil); s != 204 {
		t.Fatalf("visita: %d", s)
	}
	e.do("POST", "/v1/visit", "", map[string]any{"p": "/borrar-cuenta.html", "r": "klkmessenger.com"}, nil)
	e.do("POST", "/v1/visit", "", map[string]any{"e": "appstore"}, nil)
	if s := e.do("POST", "/v1/visit", "", map[string]any{"e": "rm -rf"}, nil); s != 400 {
		t.Fatalf("evento raro: %d", s)
	}
	if s := e.do("GET", "/admin/api/web", "", nil, nil); s != 401 {
		t.Fatalf("sin clave: %d", s)
	}
	var out struct {
		Today struct{ V, P int } `json:"today"`
		Days  []struct {
			Count int `json:"count"`
		} `json:"days"`
		Src []struct {
			K string `json:"k"`
			V int    `json:"v"`
		} `json:"src"`
		Events map[string]int `json:"events"`
	}
	if s := e.do("GET", "/admin/api/web", adminTok, nil, &out); s != 200 {
		t.Fatalf("panel: %d", s)
	}
	if out.Today.V != 2 || out.Today.P != 1 || len(out.Days) != 30 || out.Days[29].Count != 2 {
		t.Fatalf("contadores: %+v", out)
	}
	if out.Events["appstore"] != 1 {
		t.Fatalf("descargas: %+v", out.Events)
	}
	got := map[string]int{}
	for _, s := range out.Src {
		got[s.K] = s.V
	}
	if got["instagram"] != 1 || got["directo"] != 1 {
		t.Fatalf("orígenes: %+v", out.Src)
	}
}
