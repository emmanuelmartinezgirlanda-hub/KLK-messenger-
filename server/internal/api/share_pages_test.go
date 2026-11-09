package api_test

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPaginasParaCompartir(t *testing.T) {
	e := newEnv(t)
	ana := e.register("+18095550601", 1)
	get := func(path string) (int, string) {
		res, err := http.Get(e.srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(b)
	}
	e.do("PUT", "/v1/account/username", ana.token, map[string]string{"username": "anaklk"}, nil)
	var inv struct {
		Code string `json:"code"`
	}
	e.do("GET", "/v1/invite", ana.token, nil, &inv)
	var c struct {
		ID string `json:"id"`
	}
	e.do("POST", "/v1/channels", ana.token, map[string]string{"name": "Noticias RD", "emoji": "📰"}, &c)
	e.do("POST", "/v1/channels/"+c.ID+"/posts", ana.token, map[string]string{"body": "Primera noticia"}, nil)

	for path, want := range map[string][]string{
		"/i/" + inv.Code:     {"og:title", "@anaklk te invita", inv.Code, "apps.apple.com"},
		"/i/" + inv.Code[3:]: {inv.Code},
		"/k/" + c.ID:         {"Noticias RD", "Primera noticia", "og:image"},
		"/u/anaklk":          {"@anaklk", "og:description"},
	} {
		s, body := get(path)
		if s != 200 {
			t.Fatalf("%s: %d", path, s)
		}
		for _, w := range want {
			if !strings.Contains(body, w) {
				t.Fatalf("%s: falta %q", path, w)
			}
		}
	}
	for _, path := range []string{"/i/KLKZZZZZZ", "/k/no-existe", "/u/nadie123", "/u/a"} {
		if s, _ := get(path); s != 404 {
			t.Fatalf("%s: %d", path, s)
		}
	}
}
