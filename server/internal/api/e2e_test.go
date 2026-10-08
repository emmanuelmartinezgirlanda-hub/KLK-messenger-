package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
)

// ---------- Utilidades de test ----------

type fakeSMS struct {
	mu    sync.Mutex
	codes map[string]string
}

var codeRe = regexp.MustCompile(`\d{6}`)

func (f *fakeSMS) Send(phone, msg string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.codes[phone] = codeRe.FindString(msg)
	return nil
}

func (f *fakeSMS) code(phone string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.codes[phone]
}

type env struct {
	t   *testing.T
	srv *httptest.Server
	sms *fakeSMS
	st  store.Store
}

// newEnv usa el almacén en memoria, o Postgres si KLK_TEST_DATABASE_URL está definida.
func newEnv(t *testing.T) *env {
	var st store.Store = store.NewMemory()
	if url := os.Getenv("KLK_TEST_DATABASE_URL"); url != "" {
		pg, err := store.NewPostgres(context.Background(), url)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pg.Close)
		if err := pg.Migrate(context.Background()); err != nil {
			t.Fatal(err)
		}
		if err := pg.Reset(context.Background()); err != nil {
			t.Fatal(err)
		}
		st = pg
	}
	sms := &fakeSMS{codes: map[string]string{}}
	hub := relay.NewHub(st, relay.NoopPusher{})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go hub.RunScheduler(ctx, 50*time.Millisecond)
	srv := httptest.NewServer(api.New(st, auth.NewOTP(sms), hub).Routes())
	t.Cleanup(srv.Close)
	return &env{t: t, srv: srv, sms: sms, st: st}
}

func pubKey(seed byte) []byte {
	k := bytes.Repeat([]byte{seed}, 33)
	k[0] = 0x05
	return k
}

func (e *env) do(method, path, token string, body any, out any) int {
	e.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

type user struct {
	accountID, token string
}

func (e *env) register(phone string, seed byte) user {
	e.t.Helper()
	if s := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": phone}, nil); s != 204 {
		e.t.Fatalf("request code: %d", s)
	}
	var out struct {
		AccountID string `json:"accountId"`
		Token     string `json:"token"`
	}
	s := e.do("POST", "/v1/verification/verify", "", map[string]any{
		"phone": phone, "code": e.sms.code(phone), "deviceName": "test",
		"registrationId": 1234, "identityKey": pubKey(seed),
	}, &out)
	if s != 200 {
		e.t.Fatalf("verify: %d", s)
	}
	// Publicar claves
	s = e.do("PUT", "/v1/keys", out.Token, map[string]any{
		"signedPreKey": map[string]any{"keyId": 1, "publicKey": pubKey(seed + 1), "signature": bytes.Repeat([]byte{7}, 64)},
		"preKeys": []map[string]any{
			{"keyId": 1, "publicKey": pubKey(seed + 2)},
			{"keyId": 2, "publicKey": pubKey(seed + 3)},
		},
	}, nil)
	if s != 204 {
		e.t.Fatalf("put keys: %d", s)
	}
	return user{out.AccountID, out.Token}
}

type wsClient struct {
	t      *testing.T
	conn   *websocket.Conn
	frames chan map[string]any
}

func (e *env) connect(u user) *wsClient {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(e.srv.URL, "http") + "/v1/ws"
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + u.token}},
	})
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { conn.CloseNow() })
	c := &wsClient{t: e.t, conn: conn, frames: make(chan map[string]any, 64)}
	// Lector en segundo plano: en coder/websocket, cancelar un Read cierra la conexión.
	go func() {
		defer close(c.frames)
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				return
			}
			var m map[string]any
			json.Unmarshal(data, &m)
			c.frames <- m
		}
	}()
	return c
}

func (c *wsClient) send(v any) {
	c.t.Helper()
	b, _ := json.Marshal(v)
	if err := c.conn.Write(context.Background(), websocket.MessageText, b); err != nil {
		c.t.Fatal(err)
	}
}

// next lee el siguiente frame; devuelve nil si no llega nada en `wait`.
func (c *wsClient) next(wait time.Duration) map[string]any {
	c.t.Helper()
	select {
	case m := <-c.frames:
		return m
	case <-time.After(wait):
		return nil
	}
}

func (c *wsClient) expect(typ string) map[string]any {
	c.t.Helper()
	m := c.next(3 * time.Second)
	if m == nil || m["t"] != typ {
		c.t.Fatalf("esperaba frame %q, llegó %v", typ, m)
	}
	return m
}

func sendFrame(ref, to string, content string, extra map[string]any) map[string]any {
	f := map[string]any{"t": "send", "ref": ref, "to": to,
		"messages": []map[string]any{{"device": 1, "type": 1, "content": []byte(content)}}}
	for k, v := range extra {
		f[k] = v
	}
	return f
}

func decodeContent(t *testing.T, m map[string]any) string {
	var b []byte
	raw, _ := json.Marshal(m["content"])
	json.Unmarshal(raw, &b)
	return string(b)
}

// ---------- Tests ----------

func TestFlujoCompleto(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550001", 10) // Santo Domingo
	bob := e.register("+34600000001", 20)   // Madrid

	// Búsqueda por número
	var look struct {
		AccountID string `json:"accountId"`
	}
	if s := e.do("POST", "/v1/accounts/lookup", alice.token, map[string]string{"phone": "+34600000001"}, &look); s != 200 || look.AccountID != bob.accountID {
		t.Fatalf("lookup: %d %v", s, look)
	}

	// Alice pide las claves de Bob: consume una prekey
	var bundles struct {
		Devices []store.Bundle `json:"devices"`
	}
	if s := e.do("GET", "/v1/keys/"+bob.accountID, alice.token, nil, &bundles); s != 200 {
		t.Fatalf("bundles: %d", s)
	}
	if len(bundles.Devices) != 1 || bundles.Devices[0].PreKey == nil || bundles.Devices[0].PreKey.KeyID != 1 {
		t.Fatalf("bundle inesperado: %+v", bundles)
	}
	var count struct{ Count int }
	e.do("GET", "/v1/keys/count", bob.token, nil, &count)
	if count.Count != 1 {
		t.Fatalf("debían quedar 1 prekey, hay %d", count.Count)
	}

	// Entrega en vivo
	bw := e.connect(bob)
	bw.expect("synced")
	aw := e.connect(alice)
	aw.expect("synced")

	aw.send(sendFrame("c1", bob.accountID, "klk manito", nil))
	aw.expect("sent")
	msg := bw.expect("msg")
	if decodeContent(t, msg) != "klk manito" || msg["from"] != alice.accountID {
		t.Fatalf("mensaje incorrecto: %v", msg)
	}
	bw.send(map[string]any{"t": "ack", "id": msg["id"]})

	// Entrega diferida: Bob desconectado
	bw.conn.Close(websocket.StatusNormalClosure, "")
	waitOffline(t, e, bob)
	aw.send(sendFrame("c2", bob.accountID, "¿y tú dónde tá?", nil))
	aw.expect("sent")

	bw2 := e.connect(bob)
	msg2 := bw2.expect("msg")
	if decodeContent(t, msg2) != "¿y tú dónde tá?" {
		t.Fatalf("pendiente incorrecto: %v", msg2)
	}
	bw2.expect("synced") // el primer mensaje no reaparece porque se confirmó
}

func TestDispositivosNoCoinciden(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550002", 30)
	bob := e.register("+18295550002", 40)
	aw := e.connect(alice)
	aw.expect("synced")

	aw.send(map[string]any{"t": "send", "ref": "x", "to": bob.accountID,
		"messages": []map[string]any{{"device": 2, "type": 1, "content": []byte("hola")}}})
	m := aw.expect("error")
	if m["code"] != "mismatched_devices" {
		t.Fatalf("código inesperado: %v", m)
	}
}

func TestEfimeroNoSeGuarda(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550003", 50)
	bob := e.register("+18495550003", 60)
	aw := e.connect(alice)
	aw.expect("synced")

	// "escribiendo..." a Bob desconectado: se descarta
	aw.send(sendFrame("typing", bob.accountID, "typing", map[string]any{"ephemeral": true}))
	aw.expect("sent")

	bw := e.connect(bob)
	bw.expect("synced") // nada pendiente
}

func TestMensajeProgramado(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550004", 70)
	bob := e.register("+12125550004", 80) // Nueva York
	aw := e.connect(alice)
	aw.expect("synced")
	bw := e.connect(bob)
	bw.expect("synced")

	at := time.Now().Add(700 * time.Millisecond).UTC()
	aw.send(sendFrame("feliz", bob.accountID, "¡Feliz Navidad!", map[string]any{"deliverAt": at}))
	if s := aw.expect("sent"); s["scheduled"] != true {
		t.Fatalf("debía marcarse como programado: %v", s)
	}
	if m := bw.next(300 * time.Millisecond); m != nil {
		t.Fatalf("llegó antes de tiempo: %v", m)
	}
	m := bw.expect("msg")
	if decodeContent(t, m) != "¡Feliz Navidad!" {
		t.Fatalf("contenido: %v", m)
	}
}

func TestReRegistroInvalidaTokenAnterior(t *testing.T) {
	e := newEnv(t)
	old := e.register("+18095550005", 90)
	time.Sleep(10 * time.Millisecond)

	// Simula un móvil nuevo con el mismo número (saltando la espera de reenvío).
	newer := registerAgain(t, e, "+18095550005")
	if newer.accountID != old.accountID {
		t.Fatal("la cuenta debía conservarse")
	}
	if s := e.do("GET", "/v1/keys/count", old.token, nil, nil); s != 401 {
		t.Fatalf("token viejo debía ser rechazado, status %d", s)
	}
}

func TestOTPAgotaIntentos(t *testing.T) {
	sms := &fakeSMS{codes: map[string]string{}}
	otp := auth.NewOTP(sms)
	if err := otp.Request("+18095550006"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		otp.Verify("+18095550006", "000000x")
	}
	if err := otp.Verify("+18095550006", sms.code("+18095550006")); err == nil {
		t.Fatal("tras 5 fallos el código correcto ya no debía valer")
	}
}

func TestTelefonoInvalido(t *testing.T) {
	e := newEnv(t)
	if s := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": "809-555-0000"}, nil); s != 400 {
		t.Fatalf("esperaba 400, llegó %d", s)
	}
}

// ---------- Ayudas ----------

func waitOffline(t *testing.T, _ *env, _ user) {
	t.Helper()
	// Da margen al servidor para procesar el cierre. Aunque no lo hiciera,
	// el mensaje sigue en la cola hasta el ack y se reenvía al reconectar.
	time.Sleep(200 * time.Millisecond)
}

func registerAgain(t *testing.T, e *env, phone string) user {
	t.Helper()
	// El OTP real exige 1 minuto entre envíos; aquí usamos un servidor nuevo
	// que comparte el mismo almacén para no esperar.
	sms := &fakeSMS{codes: map[string]string{}}
	srv := httptest.NewServer(api.New(e.st, auth.NewOTP(sms), relay.NewHub(e.st, relay.NoopPusher{})).Routes())
	t.Cleanup(srv.Close)
	e2 := &env{t: t, srv: srv, sms: sms, st: e.st}
	u := e2.register(phone, 99)
	return u
}

func TestAdjuntos(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550007", 110)
	bob := e.register("+34600000007", 120)

	upload := func(token string, body []byte) (int, string) {
		req, _ := http.NewRequest("POST", e.srv.URL+"/v1/attachments", bytes.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out struct{ ID string }
		json.NewDecoder(res.Body).Decode(&out)
		return res.StatusCode, out.ID
	}

	// Sin sesión: rechazado
	if s, _ := upload("", []byte("x")); s != 401 {
		t.Fatalf("sin token esperaba 401, llegó %d", s)
	}

	// Alice sube un archivo cifrado; Bob lo descarga idéntico
	cifrado := bytes.Repeat([]byte{0xAB, 0xCD}, 50_000)
	s, id := upload(alice.token, cifrado)
	if s != 201 || id == "" {
		t.Fatalf("subida: %d %q", s, id)
	}
	req, _ := http.NewRequest("GET", e.srv.URL+"/v1/attachments/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+bob.token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !bytes.Equal(got, cifrado) {
		t.Fatalf("descarga: %d, %d bytes", res.StatusCode, len(got))
	}

	// Inexistente
	if s := e.do("GET", "/v1/attachments/00000000-0000-0000-0000-000000000000", bob.token, nil, nil); s != 404 {
		t.Fatalf("esperaba 404, llegó %d", s)
	}

	// Demasiado grande
	if s, _ := upload(alice.token, make([]byte, api.MaxAttachmentBytes+1)); s != 413 {
		t.Fatalf("esperaba 413, llegó %d", s)
	}

	// Caducidad
	if n, err := e.st.PurgeAttachments(context.Background(), time.Now().Add(time.Minute)); err != nil || n != 1 {
		t.Fatalf("purga: n=%d err=%v", n, err)
	}
}

func TestBuscarContactosEnLote(t *testing.T) {
	e := newEnv(t)
	alice := e.register("+18095550008", 130)
	bob := e.register("+34600000008", 140)

	var out struct {
		Found map[string]string `json:"found"`
	}
	s := e.do("POST", "/v1/accounts/lookup-batch", alice.token, map[string]any{
		"phones": []string{"+34600000008", "+12125559999", "no-es-un-numero"},
	}, &out)
	if s != 200 || len(out.Found) != 1 || out.Found["+34600000008"] != bob.accountID {
		t.Fatalf("lote: %d %v", s, out.Found)
	}

	demasiados := make([]string, api.MaxLookupBatch+1)
	if s := e.do("POST", "/v1/accounts/lookup-batch", alice.token, map[string]any{"phones": demasiados}, nil); s != 400 {
		t.Fatalf("esperaba 400, llegó %d", s)
	}
}

func TestDenuncias(t *testing.T) {
	e := newEnv(t)
	ana := e.register("+18095550101", 1)
	beto := e.register("+34611000202", 9)

	// Motivo no válido
	if s := e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": beto.accountID, "reason": "porque sí"}, nil); s != 400 {
		t.Fatalf("motivo inválido: %d", s)
	}
	// A uno mismo no
	if s := e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": ana.accountID, "reason": "spam"}, nil); s != 400 {
		t.Fatalf("a sí mismo: %d", s)
	}
	// Cuenta inexistente
	if s := e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": "00000000-0000-0000-0000-000000000000", "reason": "spam"}, nil); s != 404 {
		t.Fatalf("inexistente: %d", s)
	}
	// Sin token
	if s := e.do("POST", "/v1/reports", "", map[string]any{"accountId": beto.accountID, "reason": "spam"}, nil); s != 401 {
		t.Fatalf("sin token: %d", s)
	}
	// Correcta, con más mensajes de la cuenta: se guardan solo los 5 últimos
	msgs := []string{"1", "2", "3", "4", "5", "6", "7"}
	var out struct {
		ID string `json:"id"`
	}
	if s := e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": beto.accountID, "reason": "estafa", "messages": msgs}, &out); s != 201 || out.ID == "" {
		t.Fatalf("denuncia: %d %q", s, out.ID)
	}
	if mem, ok := e.st.(*store.Memory); ok {
		reps := mem.Reports()
		if len(reps) != 1 || len(reps[0].Messages) != 5 || reps[0].Messages[0] != "3" || reps[0].Reason != "estafa" {
			t.Fatalf("guardada mal: %+v", reps)
		}
	}
	// Límite diario
	for i := 1; i < 20; i++ {
		e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": beto.accountID, "reason": "spam"}, nil)
	}
	if s := e.do("POST", "/v1/reports", ana.token, map[string]any{"accountId": beto.accountID, "reason": "spam"}, nil); s != 429 {
		t.Fatalf("límite: %d", s)
	}
}
