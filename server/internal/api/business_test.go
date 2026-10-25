package api_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

type bizOut struct {
	ID       string          `json:"id"`
	Name     string          `json:"name"`
	Kind     string          `json:"kind"`
	Country  string          `json:"country"`
	City     string          `json:"city"`
	Data     json.RawMessage `json:"data"`
	Verified bool            `json:"verified"`
}

func TestBusiness(t *testing.T) {
	e := newAdminEnv(t)
	a := e.register("+18095550101", 1)
	b := e.register("+34600000002", 2)

	if s := e.do("GET", "/v1/business/me", a.token, nil, nil); s != http.StatusNotFound {
		t.Fatalf("sin negocio: %d", s)
	}
	// Validaciones
	bad := []map[string]any{
		{"name": "X", "kind": "colmado"},
		{"name": "Colmado", "kind": "casino"},
		{"name": "Colmado", "kind": "colmado", "country": "rd"},
		{"name": "Colmado", "kind": "colmado", "data": []int{1}},
		{"name": "Colmado", "kind": "colmado", "data": map[string]string{"x": strings.Repeat("a", 70000)}},
	}
	for i, body := range bad {
		if s := e.do("PUT", "/v1/business/me", a.token, body, nil); s != http.StatusBadRequest {
			t.Fatalf("malo %d: %d", i, s)
		}
	}

	var got bizOut
	s := e.do("PUT", "/v1/business/me", a.token, map[string]any{
		"name": " Colmado Mi Gente ", "kind": "colmado", "country": "DO", "city": "Los Mina",
		"data": map[string]any{"hours": "8-23", "items": []map[string]any{{"id": "1", "n": "Arroz", "p": 35}}},
	}, &got)
	if s != 200 || got.Name != "Colmado Mi Gente" || got.ID != a.accountID || got.Verified {
		t.Fatalf("guardar: %d %+v", s, got)
	}
	e.do("PUT", "/v1/business/me", b.token, map[string]any{"name": "Barbería El Flow", "kind": "peluqueria", "country": "ES", "city": "Madrid"}, nil)

	// Cualquiera lo ve
	if s := e.do("GET", "/v1/business/"+a.accountID, b.token, nil, &got); s != 200 || !strings.Contains(string(got.Data), "Arroz") {
		t.Fatalf("ver: %d %s", s, got.Data)
	}
	if s := e.do("GET", "/v1/business/no-existe", b.token, nil, nil); s != 404 {
		t.Fatalf("no existe: %d", s)
	}

	var list struct {
		Businesses []bizOut `json:"businesses"`
	}
	tok := a.token
	search := func(q string) []bizOut {
		list.Businesses = nil
		if s := e.do("GET", "/v1/business?"+q, tok, nil, &list); s != 200 {
			t.Fatalf("buscar %q: %d", q, s)
		}
		return list.Businesses
	}
	if n := len(search("")); n != 2 {
		t.Fatalf("todos: %d", n)
	}
	if r := search("q=flow"); len(r) != 1 || r[0].ID != b.accountID {
		t.Fatalf("por nombre: %+v", r)
	}
	if r := search("q=los%20mina"); len(r) != 1 || r[0].ID != a.accountID {
		t.Fatalf("por ciudad: %+v", r)
	}
	if r := search("kind=peluqueria&country=ES"); len(r) != 1 {
		t.Fatalf("por tipo: %+v", r)
	}
	if r := search("q=50%25"); len(r) != 0 {
		t.Fatalf("comodín: %+v", r)
	}
	if s := e.do("GET", "/v1/business?kind=casino", a.token, nil, nil); s != 400 {
		t.Fatalf("tipo malo: %d", s)
	}

	// Verificar: solo el panel. Y el dueño no se lo puede quitar al guardar.
	if s := e.do("POST", "/admin/api/business/"+b.accountID+"/verify", "mala", nil, nil); s != 401 {
		t.Fatalf("verify sin clave: %d", s)
	}
	if s := e.do("POST", "/admin/api/business/"+b.accountID+"/verify", adminTok, nil, nil); s != 204 {
		t.Fatalf("verify: %d", s)
	}
	e.do("PUT", "/v1/business/me", b.token, map[string]any{"name": "Barbería El Flow 2", "kind": "peluqueria"}, &got)
	if !got.Verified {
		t.Fatal("guardar no debe quitar el sello")
	}
	if r := search(""); r[0].ID != b.accountID {
		t.Fatal("los verificados salen primero")
	}

	// Una cuenta bloqueada no sale
	if s := e.do("POST", "/admin/api/accounts/"+a.accountID+"/ban", adminTok, map[string]string{"reason": "spam"}, nil); s != 204 {
		t.Fatalf("ban: %d", s)
	}
	tok = b.token
	if n := len(search("")); n != 1 {
		t.Fatalf("bloqueado sigue saliendo: %d", n)
	}

	// Borrar
	if s := e.do("DELETE", "/v1/business/me", b.token, nil, nil); s != 204 {
		t.Fatalf("borrar: %d", s)
	}
	if s := e.do("GET", "/v1/business/me", b.token, nil, nil); s != 404 {
		t.Fatalf("tras borrar: %d", s)
	}
}
