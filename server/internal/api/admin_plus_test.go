package api_test

import "testing"

func TestAdminPlusGifts(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550401", 1)
	luis := e.register("+18095550402", 2)

	// El dueño crea un código de 90 días.
	var gift struct {
		Code string `json:"code"`
		Days int    `json:"days"`
	}
	if s := e.do("POST", "/admin/api/plus/codes", adminTok, map[string]int{"days": 90}, &gift); s != 200 || gift.Code == "" || gift.Days != 90 {
		t.Fatalf("crear código: %d %+v", s, gift)
	}
	if s := e.do("POST", "/admin/api/plus/codes", ana.token, map[string]int{"days": 90}, nil); s != 401 {
		t.Fatalf("solo el dueño crea códigos: %d", s)
	}

	// Ana lo canjea; Luis ya no puede.
	var v struct {
		Active bool `json:"active"`
	}
	if s := e.do("POST", "/v1/plus/redeem", ana.token, map[string]string{"code": gift.Code}, &v); s != 200 || !v.Active {
		t.Fatalf("canjear: %d %+v", s, v)
	}
	if s := e.do("POST", "/v1/plus/redeem", luis.token, map[string]string{"code": gift.Code}, nil); s != 400 {
		t.Fatalf("código ya usado: %d", s)
	}

	// El panel ve a Ana con Plus y el código gastado.
	var p struct {
		Accounts []struct {
			ID string `json:"id"`
		} `json:"accounts"`
		Codes []struct {
			Code   string  `json:"code"`
			UsedAt *string `json:"usedAt"`
		} `json:"codes"`
	}
	if s := e.do("GET", "/admin/api/plus", adminTok, nil, &p); s != 200 || len(p.Accounts) != 1 || len(p.Codes) != 1 || p.Codes[0].UsedAt == nil {
		t.Fatalf("panel plus: %d %+v", s, p)
	}

	// El dueño le quita el Plus.
	if s := e.do("POST", "/admin/api/accounts/"+p.Accounts[0].ID+"/plus/remove", adminTok, nil, nil); s != 204 {
		t.Fatalf("quitar plus: %d", s)
	}
	v.Active = true
	if s := e.do("GET", "/v1/plus", ana.token, nil, &v); s != 200 || v.Active {
		t.Fatalf("sin Plus después de quitarlo: %d %+v", s, v)
	}
}
