package api_test

import (
	"context"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
)

type fakePusher struct {
	mu   sync.Mutex
	hits map[string]int
}

func (f *fakePusher) Notify(_ context.Context, acc string, _ int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hits[acc]++
}

func (f *fakePusher) count(acc string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[acc]
}

func TestAvisosPush(t *testing.T) {
	e := newEnv(t)
	p := &fakePusher{hits: map[string]int{}}
	hub := relay.NewHub(e.st, p)
	hub.SetAckWait(150 * time.Millisecond)
	e.srv = httptest.NewServer(api.New(e.st, auth.NewOTP(e.sms), hub).Routes())
	t.Cleanup(e.srv.Close)

	ana := e.register("+18095550101", 1)
	beto := e.register("+18095550102", 10)

	// Guardar el token: inválido → 400; válido → 204.
	if s := e.do("PUT", "/v1/push-token", beto.token, map[string]string{"platform": "apns", "token": "nope"}, nil); s != 400 {
		t.Fatalf("token inválido: %d", s)
	}
	tok := "AB12" + "cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	if s := e.do("PUT", "/v1/push-token", beto.token, map[string]string{"platform": "apns", "token": tok, "lang": "es-DO"}, nil); s != 204 {
		t.Fatalf("guardar token: %d", s)
	}
	got, err := e.st.GetPushToken(context.Background(), beto.accountID, 1)
	if err != nil || got.Lang != "es" || got.Token != "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12" {
		t.Fatalf("token guardado: %+v %v", got, err)
	}

	a := e.connect(ana)
	a.expect("synced")

	// Beto desconectado: un mensaje "de verdad" avisa al momento; una confirmación de lectura, no.
	a.send(sendFrame("r1", beto.accountID, "hola", map[string]any{"push": "msg"}))
	a.expect("sent")
	a.send(sendFrame("r2", beto.accountID, "leido", nil))
	a.expect("sent")
	time.Sleep(50 * time.Millisecond)
	if n := p.count(beto.accountID); n != 1 {
		t.Fatalf("avisos con Beto desconectado: %d", n)
	}

	// Beto conectado y confirma (app abierta): sin aviso.
	b := e.connect(beto)
	for {
		m := b.next(2 * time.Second)
		if m == nil {
			t.Fatal("no llegó synced")
		}
		if m["t"] == "msg" {
			b.send(map[string]any{"t": "ack", "id": m["id"]})
		}
		if m["t"] == "synced" {
			break
		}
	}
	a.send(sendFrame("r3", beto.accountID, "otra", map[string]any{"push": "msg"}))
	a.expect("sent")
	m := b.expect("msg")
	b.send(map[string]any{"t": "ack", "id": m["id"]})
	time.Sleep(300 * time.Millisecond)
	if n := p.count(beto.accountID); n != 1 {
		t.Fatalf("con la app abierta no debe avisar: %d", n)
	}

	// Beto conectado pero dormido (no confirma): aviso a los pocos segundos.
	a.send(sendFrame("r4", beto.accountID, "despierta", map[string]any{"push": "msg"}))
	a.expect("sent")
	b.expect("msg")
	time.Sleep(300 * time.Millisecond)
	if n := p.count(beto.accountID); n != 2 {
		t.Fatalf("app dormida: avisos %d", n)
	}

	// Borrar el token.
	if s := e.do("DELETE", "/v1/push-token", beto.token, nil, nil); s != 204 {
		t.Fatalf("borrar token: %d", s)
	}
	if _, err := e.st.GetPushToken(context.Background(), beto.accountID, 1); err != store.ErrNotFound {
		t.Fatalf("el token sigue: %v", err)
	}
}
