package api_test

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/appstore"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
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

func TestAnuncioDeNegocio(t *testing.T) {
	e := newEnv(t)
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	signer := appstore.NewTestSigner()
	s.Apple = appstore.NewWithRoots(signer.Roots)
	s.AppleBundleID = "com.klkapp.klk"
	s.AdminToken = adminTok
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	ana := e.register("+18095550401", 1)
	luis := e.register("+18095550402", 1)

	buy := func(product, token string) string {
		return signer.Sign(appstore.Transaction{OriginalTransactionID: "ad-1", BundleID: "com.klkapp.klk",
			ProductID: product, ExpiresDate: time.Now().Add(30 * 24 * time.Hour).UnixMilli(), AppAccountToken: token})
	}
	ad := map[string]any{"title": "Colmado Ana", "body": "Te lo llevamos", "cta": "Pedir", "color": "green"}

	// Sin pagar: no.
	if st := e.do("POST", "/v1/ads/mine", ana.token, ad, nil); st != 402 {
		t.Fatalf("sin pagar: %d", st)
	}
	// Con la suscripción de Plus tampoco (es aparte).
	ad["jws"] = []string{buy("klk.plus.mensual", ana.accountID)}
	if st := e.do("POST", "/v1/ads/mine", ana.token, ad, nil); st != 402 {
		t.Fatalf("con Plus: %d", st)
	}
	// Con la de anuncios: queda pendiente de aprobar.
	ad["jws"] = []string{buy("klk.ads.mensual", ana.accountID)}
	var mine struct {
		Ad struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"ad"`
	}
	if st := e.do("POST", "/v1/ads/mine", ana.token, ad, &mine); st != 200 || mine.Ad.Status != "pending" {
		t.Fatalf("anuncio pagado: %d %+v", st, mine)
	}
	var list struct {
		Ads []struct {
			ID string `json:"id"`
		} `json:"ads"`
	}
	e.do("GET", "/v1/ads", luis.token, nil, &list)
	if len(list.Ads) != 0 {
		t.Fatalf("no debería salir antes de aprobarlo: %+v", list.Ads)
	}
	// Otra cuenta no puede usar esa suscripción.
	if st := e.do("POST", "/v1/ads/mine", luis.token, ad, nil); st != 409 {
		t.Fatalf("suscripción de otra cuenta: %d", st)
	}
	// El dueño lo aprueba y sale.
	if st := e.do("POST", "/admin/api/ads/"+mine.Ad.ID+"/approve", adminTok, nil, nil); st != 200 {
		t.Fatalf("aprobar: %d", st)
	}
	e.do("GET", "/v1/ads", luis.token, nil, &list)
	if len(list.Ads) != 1 || list.Ads[0].ID != mine.Ad.ID {
		t.Fatalf("debería salir: %+v", list.Ads)
	}
	// Si lo cambia, vuelve a revisión (ya sin pagar otra vez).
	delete(ad, "jws")
	ad["body"] = "Ahora con ñapa"
	if st := e.do("POST", "/v1/ads/mine", ana.token, ad, &mine); st != 200 || mine.Ad.Status != "pending" {
		t.Fatalf("cambio: %d %+v", st, mine)
	}
	if st := e.do("DELETE", "/v1/ads/mine", ana.token, nil, nil); st != 204 {
		t.Fatalf("quitar: %d", st)
	}
}
