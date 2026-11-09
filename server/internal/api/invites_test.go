package api_test

import "testing"

func TestInvitarAmigos(t *testing.T) {
	e := newEnv(t)
	ana := e.register("+18095550401", 1)
	var v struct {
		Code     string `json:"code"`
		Count    int    `json:"count"`
		Months   int    `json:"months"`
		Next     int    `json:"next"`
		CanClaim bool   `json:"canClaim"`
	}
	if s := e.do("GET", "/v1/invite", ana.token, nil, &v); s != 200 || len(v.Code) != 9 || v.Count != 0 || v.Next != 3 || !v.CanClaim {
		t.Fatalf("mi código: %d %+v", s, v)
	}
	code := v.Code
	var again struct {
		Code string `json:"code"`
	}
	e.do("GET", "/v1/invite", ana.token, nil, &again)
	if again.Code != code {
		t.Fatalf("el código cambia: %s %s", code, again.Code)
	}
	if s := e.do("POST", "/v1/invite/claim", ana.token, map[string]string{"code": code}, nil); s != 400 {
		t.Fatalf("propio código: %d", s)
	}
	if s := e.do("POST", "/v1/invite/claim", ana.token, map[string]string{"code": "KLKZZZZZZ"}, nil); s != 400 {
		t.Fatalf("código malo: %d", s)
	}
	var plus struct {
		Active bool `json:"active"`
	}
	for i, phone := range []string{"+18095550402", "+18095550403", "+18095550404"} {
		f := e.register(phone, 1)
		// Sin «KLK» delante y en minúsculas también vale.
		if s := e.do("POST", "/v1/invite/claim", f.token, map[string]string{"code": " " + code[3:] + " "}, nil); s != 200 {
			t.Fatalf("amigo %d: %d", i, s)
		}
		if s := e.do("POST", "/v1/invite/claim", f.token, map[string]string{"code": code}, nil); s != 409 {
			t.Fatalf("dos veces: %d", s)
		}
		e.do("GET", "/v1/plus", f.token, nil, &plus)
		if !plus.Active {
			t.Fatalf("el invitado debe tener 7 días de Plus")
		}
		e.do("GET", "/v1/plus", ana.token, nil, &plus)
		if plus.Active != (i == 2) {
			t.Fatalf("Plus de Ana tras %d amigos: %v", i+1, plus.Active)
		}
	}
	e.do("GET", "/v1/invite", ana.token, nil, &v)
	if v.Count != 3 || v.Months != 1 || v.Next != 3 {
		t.Fatalf("tras 3 amigos: %+v", v)
	}
}
