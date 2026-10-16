package api_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// recPusher apunta a quién se le habría enviado una notificación.
type recPusher struct {
	mu  sync.Mutex
	got []string
}

func (p *recPusher) Notify(_ context.Context, acc string, _ int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.got = append(p.got, acc)
}

func (p *recPusher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.got)
}

func TestPushTokenEndpoints(t *testing.T) {
	e := newEnv(t)
	ana := e.register("+18095550001", 10)
	tok := strings.Repeat("ab", 32)

	if s := e.do("PUT", "/v1/push-token", ana.token, map[string]string{"token": tok}, nil); s != 204 {
		t.Fatalf("guardar token: %d", s)
	}
	got, err := e.st.PushToken(context.Background(), ana.accountID, 1)
	if err != nil || got != tok {
		t.Fatalf("token guardado = %q, %v", got, err)
	}
	if s := e.do("PUT", "/v1/push-token", ana.token, map[string]string{"token": "no-es-hex"}, nil); s != 400 {
		t.Fatalf("token inválido: %d", s)
	}
	if s := e.do("PUT", "/v1/push-token", "", map[string]string{"token": tok}, nil); s != 401 {
		t.Fatalf("sin sesión: %d", s)
	}

	// El mismo iPhone con otra cuenta: el token pasa a la cuenta nueva.
	luis := e.register("+18095550002", 20)
	if s := e.do("PUT", "/v1/push-token", luis.token, map[string]string{"token": tok}, nil); s != 204 {
		t.Fatalf("token en otra cuenta: %d", s)
	}
	if got, _ := e.st.PushToken(context.Background(), ana.accountID, 1); got != "" {
		t.Fatalf("la cuenta vieja conserva el token: %q", got)
	}

	if s := e.do("DELETE", "/v1/push-token", luis.token, nil, nil); s != 204 {
		t.Fatalf("borrar token: %d", s)
	}
	if got, _ := e.st.PushToken(context.Background(), luis.accountID, 1); got != "" {
		t.Fatalf("token no borrado: %q", got)
	}

	// Al borrar la cuenta, su token desaparece.
	e.do("PUT", "/v1/push-token", luis.token, map[string]string{"token": tok}, nil)
	if s := e.do("DELETE", "/v1/account", luis.token, nil, nil); s != 204 {
		t.Fatalf("borrar cuenta: %d", s)
	}
	if got, _ := e.st.PushToken(context.Background(), luis.accountID, 1); got != "" {
		t.Fatalf("token tras borrar cuenta: %q", got)
	}
}

func TestPushOnlyForRealMessagesToOfflineDevices(t *testing.T) {
	p := &recPusher{}
	e := newEnvWith(t, p)
	ana := e.register("+18095550011", 30)
	luis := e.register("+18095550012", 40)
	a := e.connect(ana)

	// Luis desconectado + mensaje con push → aviso.
	a.send(sendFrame("r1", luis.accountID, "hola", map[string]any{"push": true}))
	a.expect("sent")
	// Confirmación de leído (sin push) → ningún aviso.
	a.send(sendFrame("r2", luis.accountID, "leido", nil))
	a.expect("sent")
	if n := p.count(); n != 1 {
		t.Fatalf("avisos = %d, esperaba 1", n)
	}

	// Luis conectado → recibe el mensaje directo, sin aviso.
	l := e.connect(luis)
	time.Sleep(100 * time.Millisecond)
	for l.next(300*time.Millisecond) != nil { // vacía la cola pendiente
	}
	a.send(sendFrame("r3", luis.accountID, "otra", map[string]any{"push": true}))
	a.expect("sent")
	l.expect("msg")
	if n := p.count(); n != 1 {
		t.Fatalf("avisó a alguien conectado: %d", n)
	}
}
