package api_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
	"github.com/klk-app/klk-server/internal/topup"
)

func newTopupEnv(t *testing.T, pay func(base string) topup.Payments) (*env, *topup.Fake) {
	e := newEnv(t)
	e.srv.Close()
	hub := relay.NewHub(e.st, relay.NoopPusher{})
	s := api.New(e.st, auth.NewOTP(e.sms), hub)
	s.AdminToken = adminTok
	fake := &topup.Fake{}
	tp := &api.Topups{Provider: fake, Pricing: topup.Pricing{Currency: "EUR", Margin: 0.08, Fee: 0.35, MaxPrice: 40}, DailyMax: 3}
	s.Topups = tp
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	tp.PublicURL = e.srv.URL
	tp.Payments = pay(e.srv.URL)
	return e, fake
}

type quote struct {
	Operator string `json:"operator"`
	Test     bool   `json:"test"`
	Options  []struct {
		Amount     float64 `json:"amount"`
		PriceCents int64   `json:"priceCents"`
	} `json:"options"`
}

type created struct {
	Topup  store.Topup `json:"topup"`
	PayURL string      `json:"payUrl"`
}

func (e *env) waitTopup(tok, id, want string) store.Topup {
	e.t.Helper()
	var out struct {
		Topup store.Topup `json:"topup"`
	}
	for i := 0; i < 100; i++ {
		if s := e.do("GET", "/v1/topups/"+id, tok, nil, &out); s != 200 {
			e.t.Fatalf("estado recarga: %d", s)
		}
		if out.Topup.Status == want {
			return out.Topup
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.t.Fatalf("la recarga quedó en %q, esperaba %q (%s)", out.Topup.Status, want, out.Topup.Error)
	return out.Topup
}

func TestTopupsOffByDefault(t *testing.T) {
	e := newEnv(t)
	a := e.register("+18095550101", 1)
	if s := e.do("GET", "/v1/topups/quote?phone=%2B18095550123", a.token, nil, nil); s != http.StatusServiceUnavailable {
		t.Fatalf("sin configurar debería estar apagado: %d", s)
	}
}

func TestTopupDemoFlow(t *testing.T) {
	e, fake := newTopupEnv(t, func(base string) topup.Payments { return &topup.FakePay{BaseURL: base} })
	a := e.register("+34600000001", 1)
	b := e.register("+34600000002", 2)

	// Solo números de RD.
	if s := e.do("GET", "/v1/topups/quote?phone=%2B34600000009", a.token, nil, nil); s != 400 {
		t.Fatalf("número no dominicano: %d", s)
	}
	var q quote
	if s := e.do("GET", "/v1/topups/quote?phone=%2B18295551231", a.token, nil, &q); s != 200 {
		t.Fatalf("quote: %d", s)
	}
	if !strings.Contains(q.Operator, "Altice") || !q.Test || len(q.Options) == 0 {
		t.Fatalf("quote raro: %+v", q)
	}
	// 200 pesos / 63.5 = 3.15 € → ×1.08 + 0.35 = 3.75 €
	for _, o := range q.Options {
		if o.Amount == 200 && o.PriceCents != 376 && o.PriceCents != 375 {
			t.Fatalf("precio de 200 pesos: %d", o.PriceCents)
		}
	}
	if s := e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18295551231", "amount": 77}, nil); s != 400 {
		t.Fatalf("monto inventado: %d", s)
	}
	var c created
	if s := e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18295551231", "amount": 200}, &c); s != 201 {
		t.Fatalf("crear: %d", s)
	}
	if c.Topup.Status != store.TopupAwaitingPayment || !strings.Contains(c.PayURL, "/topup/test-pay/") {
		t.Fatalf("creada: %+v %s", c.Topup, c.PayURL)
	}
	// Otra cuenta no la ve.
	if s := e.do("GET", "/v1/topups/"+c.Topup.ID, b.token, nil, nil); s != 404 {
		t.Fatalf("otra cuenta ve la recarga: %d", s)
	}
	// Página de pago de prueba.
	res, err := http.Get(c.PayURL)
	if err != nil || res.StatusCode != 200 {
		t.Fatalf("página de pago: %v", err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !strings.Contains(string(body), "MODO PRUEBA") {
		t.Fatal("la página no dice que es de prueba")
	}
	// Pagar dos veces: solo una recarga.
	for i := 0; i < 2; i++ {
		res, err = http.PostForm(c.PayURL, url.Values{})
		if err != nil || res.StatusCode != 200 {
			t.Fatalf("pagar: %v %d", err, res.StatusCode)
		}
		res.Body.Close()
	}
	done := e.waitTopup(a.token, c.Topup.ID, store.TopupDone)
	if done.CostCents == 0 {
		t.Fatal("sin coste apuntado")
	}
	time.Sleep(50 * time.Millisecond)
	if len(fake.Sent) != 1 || fake.Sent[0].OrderID != c.Topup.ID {
		t.Fatalf("recargas enviadas: %+v", fake.Sent)
	}

	// Un número que el operador rechaza: queda devuelta.
	if s := e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18095550000", "amount": 100}, &c); s != 201 {
		t.Fatalf("crear 2: %d", s)
	}
	res, _ = http.PostForm(c.PayURL, url.Values{})
	res.Body.Close()
	e.waitTopup(a.token, c.Topup.ID, store.TopupRefunded)

	// Historial.
	var list struct {
		Topups []store.Topup `json:"topups"`
	}
	if s := e.do("GET", "/v1/topups", a.token, nil, &list); s != 200 || len(list.Topups) != 2 {
		t.Fatalf("historial: %d %d", s, len(list.Topups))
	}
	// Tope diario (3).
	e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18095550123", "amount": 100}, nil)
	if s := e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18095550123", "amount": 100}, nil); s != 429 {
		t.Fatalf("tope diario: %d", s)
	}

	// Panel del dueño.
	var st struct {
		Topups struct {
			Mode  string           `json:"mode"`
			Stats store.TopupStats `json:"stats"`
		} `json:"topups"`
	}
	if s := e.do("GET", "/admin/api/stats", adminTok, nil, &st); s != 200 {
		t.Fatalf("stats: %d", s)
	}
	if st.Topups.Mode != "test" || st.Topups.Stats.TestDoneMonth != 1 {
		t.Fatalf("panel recargas: %+v", st.Topups)
	}
	var pl struct {
		Topups []map[string]any `json:"topups"`
	}
	if s := e.do("GET", "/admin/api/topups", adminTok, nil, &pl); s != 200 || len(pl.Topups) != 3 {
		t.Fatalf("lista panel: %d %d", s, len(pl.Topups))
	}
	if p := pl.Topups[0]["phone"].(string); strings.Contains(p, "0123") {
		t.Fatalf("el panel enseña el número entero: %s", p)
	}
}

// fakeStripe imita lo justo de la API de Stripe.
type fakeStripe struct {
	mu       sync.Mutex
	sessions map[string]url.Values
	refunds  []string
}

func (f *fakeStripe) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if u, _, _ := r.BasicAuth(); u != "sk_test_abc" {
		w.WriteHeader(401)
		return
	}
	r.ParseForm()
	switch r.URL.Path {
	case "/v1/checkout/sessions":
		id := "cs_test_" + r.Form.Get("client_reference_id")
		f.sessions[id] = r.Form
		json.NewEncoder(w).Encode(map[string]string{"id": id, "url": "https://checkout.stripe.com/c/pay/" + id})
	case "/v1/refunds":
		f.refunds = append(f.refunds, r.Form.Get("payment_intent"))
		w.Write([]byte(`{"id":"re_1"}`))
	default:
		w.WriteHeader(404)
	}
}

func TestTopupStripeWebhook(t *testing.T) {
	fs := &fakeStripe{sessions: map[string]url.Values{}}
	stripeSrv := httptest.NewServer(fs)
	defer stripeSrv.Close()
	const whsec = "whsec_prueba"
	e, _ := newTopupEnv(t, func(string) topup.Payments {
		return &topup.Stripe{SecretKey: "sk_test_abc", WebhookSecret: whsec, APIURL: stripeSrv.URL}
	})
	a := e.register("+34600000001", 1)
	var c created
	if s := e.do("POST", "/v1/topups", a.token, map[string]any{"phone": "+18095550123", "amount": 500}, &c); s != 201 {
		t.Fatalf("crear: %d", s)
	}
	sess := "cs_test_" + c.Topup.ID
	form := fs.sessions[sess]
	if form.Get("line_items[0][price_data][unit_amount]") != json.Number(jsonInt(c.Topup.PriceCents)).String() ||
		form.Get("line_items[0][price_data][currency]") != "eur" {
		t.Fatalf("checkout mal: %v", form)
	}
	ev := func(id string) []byte {
		b, _ := json.Marshal(map[string]any{"type": "checkout.session.completed", "data": map[string]any{"object": map[string]any{
			"id": id, "payment_status": "paid", "payment_intent": "pi_123", "client_reference_id": c.Topup.ID,
			"metadata": map[string]string{"order_id": c.Topup.ID}}}})
		return b
	}
	post := func(body []byte, sig string) int {
		req, _ := http.NewRequest("POST", e.srv.URL+"/v1/topups/stripe-webhook", bytes.NewReader(body))
		req.Header.Set("Stripe-Signature", sig)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	body := ev(sess)
	// Firma falsa o vieja: fuera.
	if s := post(body, topup.SignForTest("otra", body, time.Now())); s != 400 {
		t.Fatalf("firma falsa: %d", s)
	}
	if s := post(body, topup.SignForTest(whsec, body, time.Now().Add(-time.Hour))); s != 400 {
		t.Fatalf("firma vieja: %d", s)
	}
	// Pago de otra sesión para esta recarga: no.
	other := ev("cs_test_otra")
	if s := post(other, topup.SignForTest(whsec, other, time.Now())); s == 200 {
		t.Fatal("aceptó un pago de otra sesión")
	}
	if s := post(body, topup.SignForTest(whsec, body, time.Now())); s != 200 {
		t.Fatalf("aviso bueno: %d", s)
	}
	if s := post(body, topup.SignForTest(whsec, body, time.Now())); s != 200 { // Stripe repite
		t.Fatalf("aviso repetido: %d", s)
	}
	e.waitTopup(a.token, c.Topup.ID, store.TopupDone)
}

func jsonInt(n int64) string { b, _ := json.Marshal(n); return string(b) }
