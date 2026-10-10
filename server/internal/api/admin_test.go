package api_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
)

const adminTok = "clave-del-dueno-de-prueba-123"

func newAdminEnv(t *testing.T) *env {
	e := newEnv(t)
	e.srv.Close()
	hub := relay.NewHub(e.st, relay.NoopPusher{})
	s := api.New(e.st, auth.NewOTP(e.sms), hub)
	s.AdminToken = adminTok
	s.SMSPrice = 0.10
	s.ServerCost = 7
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	return e
}

func TestAdminPanel(t *testing.T) {
	e := newAdminEnv(t)
	a := e.register("+18095550101", 1)
	b := e.register("+34600000002", 2)

	// Sin clave o con clave mala: fuera.
	if s := e.do("GET", "/admin/api/stats", "", nil, nil); s != http.StatusUnauthorized {
		t.Fatalf("sin clave: %d", s)
	}
	if s := e.do("GET", "/admin/api/stats", "mala", nil, nil); s != http.StatusUnauthorized {
		t.Fatalf("clave mala: %d", s)
	}
	// La página del panel se sirve.
	resp, err := http.Get(e.srv.URL + "/admin")
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("panel html: %v %v", err, resp.StatusCode)
	}
	resp.Body.Close()

	var st struct {
		Stats store.Stats `json:"stats"`
		Money struct {
			SMSCostMonth float64 `json:"smsCostMonth"`
			TotalMonth   float64 `json:"totalMonth"`
		} `json:"money"`
	}
	if s := e.do("GET", "/admin/api/stats", adminTok, nil, &st); s != 200 {
		t.Fatalf("stats: %d", s)
	}
	if st.Stats.Users != 2 || st.Stats.NewToday != 2 || st.Stats.SMSToday != 2 || st.Stats.Active24h != 2 {
		t.Fatalf("stats inesperadas: %+v", st.Stats)
	}
	if st.Stats.Signups[29].Count != 2 || len(st.Stats.Signups) != 30 {
		t.Fatalf("gráfica: %+v", st.Stats.Signups)
	}
	if st.Money.SMSCostMonth < 0.19 || st.Money.TotalMonth < 7.19 {
		t.Fatalf("dinero: %+v", st.Money)
	}

	// Denuncia de A contra B → aparece en el panel.
	if s := e.do("POST", "/v1/reports", a.token, map[string]any{"accountId": b.accountID, "reason": "estafa", "messages": []string{"mándame 100€"}}, nil); s != 201 {
		t.Fatalf("denuncia: %d", s)
	}
	var reps struct {
		Reports []store.ReportView `json:"reports"`
	}
	e.do("GET", "/admin/api/reports", adminTok, nil, &reps)
	if len(reps.Reports) != 1 || reps.Reports[0].Reported.Phone != "+34600000002" || reps.Reports[0].Messages[0] != "mándame 100€" {
		t.Fatalf("denuncias: %+v", reps.Reports)
	}
	if strings.Contains(reps.Reports[0].Reporter, "0101") {
		t.Fatalf("el denunciante debería ir enmascarado: %s", reps.Reports[0].Reporter)
	}

	// Bloquear a B: ya no puede usar la API ni pedir código.
	if s := e.do("POST", "/admin/api/accounts/"+b.accountID+"/ban", adminTok, map[string]string{"reason": "estafa"}, nil); s != 204 {
		t.Fatalf("ban: %d", s)
	}
	if s := e.do("GET", "/v1/keys/count", b.token, nil, nil); s != http.StatusForbidden {
		t.Fatalf("bloqueado debería dar 403: %d", s)
	}
	if s := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": "+34600000002"}, nil); s != http.StatusForbidden {
		t.Fatalf("número bloqueado pidiendo código: %d", s)
	}
	var banned struct {
		Accounts []store.AccountView `json:"accounts"`
	}
	e.do("GET", "/admin/api/banned", adminTok, nil, &banned)
	if len(banned.Accounts) != 1 || banned.Accounts[0].BannedReason != "estafa" {
		t.Fatalf("bloqueados: %+v", banned.Accounts)
	}

	// Resolver la denuncia.
	if s := e.do("POST", "/admin/api/reports/"+reps.Reports[0].ID+"/resolve", adminTok, nil, nil); s != 204 {
		t.Fatalf("resolver: %d", s)
	}
	e.do("GET", "/admin/api/reports", adminTok, nil, &reps)
	if len(reps.Reports) != 0 {
		t.Fatalf("no debería quedar ninguna pendiente: %+v", reps.Reports)
	}
	e.do("GET", "/admin/api/reports?all=1", adminTok, nil, &reps)
	if len(reps.Reports) != 1 || reps.Reports[0].ResolvedAt == nil {
		t.Fatalf("todas: %+v", reps.Reports)
	}

	// Desbloquear.
	if s := e.do("POST", "/admin/api/accounts/"+b.accountID+"/unban", adminTok, nil, nil); s != 204 {
		t.Fatalf("unban: %d", s)
	}
	if s := e.do("GET", "/v1/keys/count", b.token, nil, nil); s != 200 {
		t.Fatalf("desbloqueado: %d", s)
	}

	// Bloquear por número.
	if s := e.do("POST", "/admin/api/ban-phone", adminTok, map[string]string{"phone": "+34 600 000 002", "reason": "spam"}, nil); s != 204 {
		t.Fatalf("ban-phone: %d", s)
	}
	if s := e.do("POST", "/admin/api/ban-phone", adminTok, map[string]string{"phone": "+34699999999"}, nil); s != 404 {
		t.Fatalf("ban-phone sin cuenta: %d", s)
	}

	// Avisos: se crean, A los ve, se borran.
	if s := e.do("POST", "/admin/api/announcements", adminTok, map[string]string{"title": "", "body": "x"}, nil); s != 400 {
		t.Fatalf("aviso vacío: %d", s)
	}
	var n store.Announcement
	if s := e.do("POST", "/admin/api/announcements", adminTok, map[string]string{"title": "¡Hola!", "body": "Bienvenidos a KLK"}, &n); s != 201 {
		t.Fatalf("aviso: %d", s)
	}
	var news struct {
		Announcements []store.Announcement `json:"announcements"`
	}
	e.do("GET", "/v1/announcements", a.token, nil, &news)
	if len(news.Announcements) != 1 || news.Announcements[0].Title != "¡Hola!" {
		t.Fatalf("avisos en la app: %+v", news.Announcements)
	}
	if s := e.do("DELETE", "/admin/api/announcements/"+n.ID, adminTok, nil, nil); s != 204 {
		t.Fatalf("borrar aviso: %d", s)
	}
	e.do("GET", "/v1/announcements", a.token, nil, &news)
	if len(news.Announcements) != 0 {
		t.Fatalf("debería estar vacío: %+v", news.Announcements)
	}
}

func TestAdminDisabledWithoutToken(t *testing.T) {
	e := newEnv(t)
	if s := e.do("GET", "/admin/api/stats", "", nil, nil); s != http.StatusNotFound {
		t.Fatalf("panel sin clave configurada: %d", s)
	}
	resp, _ := http.Get(e.srv.URL + "/admin")
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("html: %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestMaskPhone(t *testing.T) {
	if got := store.MaskPhone("+18095551234"); got != "+180••••••34" {
		t.Fatalf("mask: %q", got)
	}
	if store.CountryOf("+18295551234") != "+1829" || store.CountryOf("+34600000000") != "+34" {
		t.Fatal("country")
	}
	_ = context.Background
	_ = time.Now
}
