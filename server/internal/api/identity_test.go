package api_test

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
)

// Buzón falso: guarda el último código que se mandó a cada correo.
type fakeMail struct {
	mu    sync.Mutex
	codes map[string]string
}

var sixDigits = regexp.MustCompile(`\d{6}`)

func (f *fakeMail) Send(to, _, text, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.codes[to] = sixDigits.FindString(text)
	return nil
}

func (f *fakeMail) code(to string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.codes[to]
}

func newMailEnv(t *testing.T) (*env, *fakeMail) {
	e := newEnv(t)
	e.srv.Close()
	mail := &fakeMail{codes: map[string]string{}}
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	s.AdminToken = adminTok
	s.Mail = auth.NewMailOTP(mail)
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	return e, mail
}

func (e *env) loginEmail(mail *fakeMail, email string, seed byte) (int, user) {
	e.t.Helper()
	if s := e.do("POST", "/v1/verification/email/request", "", map[string]string{"email": email}, nil); s != 204 {
		e.t.Fatalf("pedir código por correo: %d", s)
	}
	var out struct {
		AccountID string `json:"accountId"`
		Token     string `json:"token"`
	}
	s := e.do("POST", "/v1/verification/email/verify", "", map[string]any{
		"email": email, "code": mail.code(strings.ToLower(strings.TrimSpace(email))), "deviceName": "test",
		"registrationId": 1234, "identityKey": pubKey(seed),
	}, &out)
	return s, user{out.AccountID, out.Token}
}

func TestUsername(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550501", 1)
	luis := e.register("+18095550502", 2)

	for _, bad := range []string{"ab", "Ana Pérez", "klkoficial", "soporte", "ana..b", "_ana", strings.Repeat("a", 21)} {
		if s := e.do("PUT", "/v1/account/username", ana.token, map[string]string{"username": bad}, nil); s != 400 {
			t.Fatalf("usuario malo %q: %d", bad, s)
		}
	}
	var out struct {
		Username string `json:"username"`
	}
	if s := e.do("PUT", "/v1/account/username", ana.token, map[string]string{"username": "@Ana.Perez"}, &out); s != 200 ||
		out.Username != "ana.perez" {
		t.Fatalf("poner usuario: %d %+v", s, out)
	}
	if s := e.do("PUT", "/v1/account/username", luis.token, map[string]string{"username": "ana.perez"}, nil); s != 409 {
		t.Fatalf("usuario repetido: %d", s)
	}
	var found struct {
		AccountID string `json:"accountId"`
	}
	if s := e.do("GET", "/v1/accounts/by-username/@ANA.perez", luis.token, nil, &found); s != 200 || found.AccountID != ana.accountID {
		t.Fatalf("buscar: %d %+v", s, found)
	}
	if s := e.do("GET", "/v1/accounts/by-username/nadie", luis.token, nil, nil); s != 404 {
		t.Fatalf("buscar inexistente: %d", s)
	}
	if res, _ := http.Get(e.srv.URL + "/u/ana.perez"); res.StatusCode != 200 {
		t.Fatalf("página del usuario: %d", res.StatusCode)
	}
	// Cambiarlo libera el anterior
	e.do("PUT", "/v1/account/username", ana.token, map[string]string{"username": "anita"}, nil)
	if s := e.do("PUT", "/v1/account/username", luis.token, map[string]string{"username": "ana.perez"}, nil); s != 200 {
		t.Fatalf("coger usuario liberado: %d", s)
	}
	var me struct {
		Username string `json:"username"`
	}
	e.do("GET", "/v1/account/me", ana.token, nil, &me)
	if me.Username != "anita" {
		t.Fatalf("mi cuenta: %+v", me)
	}
	// Una cuenta bloqueada no sale al buscarla
	e.do("POST", "/admin/api/accounts/"+ana.accountID+"/ban", adminTok, map[string]string{"reason": "spam"}, nil)
	if s := e.do("GET", "/v1/accounts/by-username/anita", luis.token, nil, nil); s != 404 {
		t.Fatalf("bloqueado encontrado: %d", s)
	}
}

func TestEmailLogin(t *testing.T) {
	// Sin correo configurado, la opción está apagada
	plain := newEnv(t)
	var m struct {
		Email bool `json:"email"`
	}
	if plain.do("GET", "/v1/verification/methods", "", nil, &m); m.Email {
		t.Fatal("correo encendido sin configurar")
	}
	if s := plain.do("POST", "/v1/verification/email/request", "", map[string]string{"email": "a@b.com"}, nil); s != 503 {
		t.Fatalf("correo apagado: %d", s)
	}

	e, mail := newMailEnv(t)
	if e.do("GET", "/v1/verification/methods", "", nil, &m); !m.Email {
		t.Fatal("correo apagado con configuración")
	}
	if s := e.do("POST", "/v1/verification/email/request", "", map[string]string{"email": "no-es-correo"}, nil); s != 400 {
		t.Fatalf("correo malo: %d", s)
	}
	// Código mal: no entra
	e.do("POST", "/v1/verification/email/request", "", map[string]string{"email": "rosa@correo.com"}, nil)
	if s := e.do("POST", "/v1/verification/email/verify", "", map[string]any{"email": "rosa@correo.com", "code": "000000",
		"deviceName": "t", "registrationId": 1, "identityKey": pubKey(9)}, nil); s != 403 {
		t.Fatalf("código malo: %d", s)
	}
	if s := e.do("POST", "/v1/verification/email/request", "", map[string]string{"email": "rosa@correo.com"}, nil); s != 429 {
		t.Fatalf("otro código antes del minuto: %d", s)
	}

	// Cuenta nueva con correo
	s, rosa := e.loginEmail(mail, "otra@correo.com", 10)
	if s != 200 || rosa.accountID == "" {
		t.Fatalf("entrar con correo: %d", s)
	}
	var me struct {
		Email string `json:"email"`
	}
	e.do("GET", "/v1/account/me", rosa.token, nil, &me)
	if me.Email != "otra@correo.com" {
		t.Fatalf("correo de la cuenta: %+v", me)
	}
	// Quien entra con correo no puede quitarlo
	if s := e.do("DELETE", "/v1/account/email", rosa.token, nil, nil); s != 400 {
		t.Fatalf("quitar el correo de entrar: %d", s)
	}
	// Volver a entrar con el mismo correo: misma cuenta
	if s, again := e.loginEmail(mail, " OTRA@correo.com", 11); s != 200 || again.accountID != rosa.accountID {
		t.Fatalf("volver a entrar: %d %s %s", s, again.accountID, rosa.accountID)
	}

	// Una cuenta de número añade su correo y luego entra con él (perdió el número)
	luis := e.register("+18095550601", 20)
	if s := e.do("POST", "/v1/account/email/request", luis.token, map[string]string{"email": "otra@correo.com"}, nil); s != 409 {
		t.Fatalf("correo de otro: %d", s)
	}
	if s := e.do("POST", "/v1/account/email/request", luis.token, map[string]string{"email": "luis@correo.com"}, nil); s != 204 {
		t.Fatalf("pedir código para añadir: %d", s)
	}
	// El código de añadir no vale para entrar
	if s := e.do("POST", "/v1/verification/email/verify", "", map[string]any{"email": "luis@correo.com",
		"code": mail.code("luis@correo.com"), "deviceName": "t", "registrationId": 1, "identityKey": pubKey(21)}, nil); s != 403 {
		t.Fatalf("código de añadir usado para entrar: %d", s)
	}
	e.do("POST", "/v1/account/email/request", luis.token, map[string]string{"email": "luis@correo.com"}, nil) // demasiado pronto: sigue el anterior
	if s := e.do("POST", "/v1/account/email/verify", luis.token, map[string]string{"email": "luis@correo.com", "code": mail.code("luis@correo.com")}, nil); s != 200 {
		t.Fatalf("añadir correo: %d", s)
	}
	if s, viaMail := e.loginEmail(mail, "luis@correo.com", 22); s != 200 || viaMail.accountID != luis.accountID {
		t.Fatalf("entrar a la cuenta de número con su correo: %d %s %s", s, viaMail.accountID, luis.accountID)
	}

	// Bloquear por correo desde el panel
	if s := e.do("POST", "/admin/api/ban-phone", adminTok, map[string]string{"phone": "otra@correo.com", "reason": "spam"}, nil); s != 204 {
		t.Fatalf("bloquear por correo: %d", s)
	}
	if s := e.do("POST", "/v1/verification/email/request", "", map[string]string{"email": "otra@correo.com"}, nil); s != 403 {
		t.Fatalf("cuenta bloqueada pide código: %d", s)
	}
}
