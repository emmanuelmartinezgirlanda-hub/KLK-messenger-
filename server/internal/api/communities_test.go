package api_test

import (
	"net/http"
	"testing"
)

type commList struct {
	Communities []struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Members int    `json:"members"`
		Joined  bool   `json:"joined"`
	} `json:"communities"`
}

func TestCommunities(t *testing.T) {
	e := newEnv(t)
	a := e.register("+18095550101", 1)
	b := e.register("+34600000002", 2)

	var list commList
	if s := e.do("GET", "/v1/communities", a.token, nil, &list); s != http.StatusOK {
		t.Fatalf("lista: %d", s)
	}
	if len(list.Communities) == 0 || list.Communities[0].ID != "DO" {
		t.Fatalf("RD debe ir la primera: %+v", list.Communities)
	}
	for _, c := range list.Communities {
		if c.Members != 0 || c.Joined {
			t.Fatalf("al empezar no hay nadie: %+v", c)
		}
	}

	// Sin estar dentro no se ven los miembros.
	if s := e.do("GET", "/v1/communities/DO/members", a.token, nil, nil); s != http.StatusForbidden {
		t.Fatalf("miembros sin estar dentro: %d", s)
	}
	if s := e.do("POST", "/v1/communities/XX", a.token, nil, nil); s != http.StatusNotFound {
		t.Fatalf("comunidad inexistente: %d", s)
	}

	for _, u := range []user{a, b} {
		if s := e.do("POST", "/v1/communities/DO", u.token, nil, nil); s != http.StatusNoContent {
			t.Fatalf("unirse: %d", s)
		}
	}
	e.do("POST", "/v1/communities/ES", b.token, nil, nil)
	e.do("POST", "/v1/communities/ES", b.token, nil, nil) // dos veces no cuenta doble

	e.do("GET", "/v1/communities", a.token, nil, &list)
	got := map[string]int{}
	joined := map[string]bool{}
	for _, c := range list.Communities {
		got[c.ID] = c.Members
		joined[c.ID] = c.Joined
	}
	if got["DO"] != 2 || got["ES"] != 1 || !joined["DO"] || joined["ES"] {
		t.Fatalf("cuentas: %v unido: %v", got, joined)
	}

	var members struct {
		Members []string `json:"members"`
	}
	if s := e.do("GET", "/v1/communities/DO/members", a.token, nil, &members); s != http.StatusOK || len(members.Members) != 2 {
		t.Fatalf("miembros: %d %v", s, members.Members)
	}

	// Salirse
	if s := e.do("DELETE", "/v1/communities/DO", b.token, nil, nil); s != http.StatusNoContent {
		t.Fatalf("salir: %d", s)
	}
	e.do("GET", "/v1/communities", a.token, nil, &list)
	for _, c := range list.Communities {
		if c.ID == "DO" && c.Members != 1 {
			t.Fatalf("tras salir: %+v", c)
		}
	}
}
