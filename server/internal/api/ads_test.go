package api_test

import (
	"testing"
)

func TestAnuncios(t *testing.T) {
	e := newAdminEnv(t)
	a := e.register("+18095550101", 1)

	if s := e.do("POST", "/admin/api/ads", adminTok, map[string]any{"title": "", "body": "x"}, nil); s != 400 {
		t.Fatalf("anuncio vacío: %d", s)
	}
	png := []byte("\x89PNG\r\n\x1a\n0000")
	var made struct {
		ID       string `json:"id"`
		URL      string `json:"url"`
		HasImage bool   `json:"hasImage"`
	}
	body := map[string]any{"title": "Colmado La Esquina", "body": "Pide por KLK", "cta": "Pedir", "url": "colmado.do", "color": "navy", "days": 30, "image": png}
	if s := e.do("POST", "/admin/api/ads", adminTok, body, &made); s != 201 {
		t.Fatalf("anuncio: %d", s)
	}
	if made.URL != "https://colmado.do" || !made.HasImage {
		t.Fatalf("anuncio creado: %+v", made)
	}
	var list struct {
		Ads []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"ads"`
	}
	e.do("GET", "/v1/ads", a.token, nil, &list)
	if len(list.Ads) != 1 || list.Ads[0].Title != "Colmado La Esquina" {
		t.Fatalf("anuncios en la app: %+v", list.Ads)
	}
	if s := e.do("GET", "/v1/ads/"+made.ID+"/image", "", nil, nil); s != 200 {
		t.Fatalf("foto del anuncio: %d", s)
	}
	if s := e.do("POST", "/v1/ads/"+made.ID+"/click", a.token, nil, nil); s != 204 {
		t.Fatalf("toque: %d", s)
	}
	if s := e.do("DELETE", "/admin/api/ads/"+made.ID, adminTok, nil, nil); s != 204 {
		t.Fatalf("quitar: %d", s)
	}
	e.do("GET", "/v1/ads", a.token, nil, &list)
	if len(list.Ads) != 0 {
		t.Fatalf("debería estar vacío: %+v", list.Ads)
	}
}
