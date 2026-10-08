// Package relay enruta sobres cifrados entre dispositivos por WebSocket.
//
// Protocolo (JSON por frame):
//
//	cliente → servidor
//	  {"t":"send","ref":"<id cliente>","to":"<accountId>",
//	   "messages":[{"device":1,"type":3,"content":"<base64>"}],
//	   "deliverAt":"2026-12-24T23:59:00Z",   // opcional: mensaje programado
//	   "ephemeral":true}                      // opcional: escribiendo/grabando, no se guarda
//	  {"t":"ack","id":"<envelopeId>"}
//
//	servidor → cliente
//	  {"t":"msg","id","from","fromDevice","type","content","ts","ephemeral"}
//	  {"t":"sent","ref","ts","scheduled"}
//	  {"t":"synced"}                          // cola pendiente entregada
//	  {"t":"error","ref","code","message","devices"}
//
// El servidor nunca descifra "content". Las confirmaciones de lectura y los
// indicadores de escritura viajan también cifrados como mensajes normales,
// así que el servidor ni siquiera sabe qué tipo de mensaje es.
package relay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"github.com/klk-app/klk-server/internal/store"
)

const (
	MaxContentBytes   = 64 << 10 // 64 KB por mensaje cifrado (los medios van aparte)
	MaxMessagesPerReq = 50
	MaxScheduleAhead  = 366 * 24 * time.Hour
	pendingBatch      = 1000
	sendBuffer        = 256
	writeTimeout      = 10 * time.Second
)

// Pusher avisa a un dispositivo desconectado de que tiene mensajes (APNs/FCM).
// La notificación no lleva contenido.
type Pusher interface {
	Notify(ctx context.Context, accountID string, deviceID int)
}

type NoopPusher struct{}

func (NoopPusher) Notify(context.Context, string, int) {}

type devKey struct {
	acc string
	dev int
}

type Hub struct {
	store  store.Store
	pusher Pusher
	now    func() time.Time

	mu    sync.RWMutex
	conns map[devKey]*client
}

func NewHub(s store.Store, p Pusher) *Hub {
	return &Hub{store: s, pusher: p, now: time.Now, conns: map[devKey]*client{}}
}

type client struct {
	key    devKey
	out    chan []byte
	closed chan struct{}
	once   sync.Once
}

func (c *client) close() { c.once.Do(func() { close(c.closed) }) }

// enqueue no bloquea: si el cliente va demasiado lento se desconecta;
// los mensajes siguen en la cola y se reenvían al reconectar.
func (c *client) enqueue(b []byte) {
	select {
	case c.out <- b:
	case <-c.closed:
	default:
		c.close()
	}
}

// ---------- Frames ----------

type wireMsg struct {
	Device  int    `json:"device"`
	Type    int    `json:"type"`
	Content []byte `json:"content"`
}

type inFrame struct {
	T         string     `json:"t"`
	Ref       string     `json:"ref,omitempty"`
	To        string     `json:"to,omitempty"`
	Messages  []wireMsg  `json:"messages,omitempty"`
	DeliverAt *time.Time `json:"deliverAt,omitempty"`
	Ephemeral bool       `json:"ephemeral,omitempty"`
	ID        string     `json:"id,omitempty"`
}

type msgFrame struct {
	T          string    `json:"t"`
	ID         string    `json:"id"`
	From       string    `json:"from"`
	FromDevice int       `json:"fromDevice"`
	Type       int       `json:"type"`
	Content    []byte    `json:"content"`
	TS         time.Time `json:"ts"`
	Ephemeral  bool      `json:"ephemeral,omitempty"`
}

type sentFrame struct {
	T         string    `json:"t"`
	Ref       string    `json:"ref"`
	TS        time.Time `json:"ts"`
	Scheduled bool      `json:"scheduled,omitempty"`
}

type errFrame struct {
	T       string `json:"t"`
	Ref     string `json:"ref,omitempty"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Devices []int  `json:"devices,omitempty"`
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func envelopeFrame(e store.Envelope, ephemeral bool) []byte {
	return mustJSON(msgFrame{T: "msg", ID: e.ID, From: e.FromAccount, FromDevice: e.FromDevice,
		Type: e.Type, Content: e.Content, TS: e.DeliverAt, Ephemeral: ephemeral})
}

// ---------- Conexión ----------

// Serve atiende la conexión de un dispositivo autenticado hasta que se cierre.
func (h *Hub) Serve(ctx context.Context, conn *websocket.Conn, dev store.Device) {
	conn.SetReadLimit(MaxMessagesPerReq*MaxContentBytes*2 + 4096)
	c := &client{key: devKey{dev.AccountID, dev.DeviceID}, out: make(chan []byte, sendBuffer), closed: make(chan struct{})}

	h.mu.Lock()
	if old, ok := h.conns[c.key]; ok {
		old.close() // una sola conexión por dispositivo
	}
	h.conns[c.key] = c
	h.mu.Unlock()

	ctx, cancel := context.WithCancel(ctx)
	defer func() {
		cancel()
		h.mu.Lock()
		if h.conns[c.key] == c {
			delete(h.conns, c.key)
		}
		h.mu.Unlock()
		c.close()
	}()

	go h.writeLoop(ctx, conn, c)

	// Entregar la cola pendiente al conectar.
	pending, err := h.store.Pending(ctx, dev.AccountID, dev.DeviceID, h.now(), pendingBatch)
	if err != nil {
		slog.Error("leyendo pendientes", "err", err)
		return
	}
	for _, e := range pending {
		c.enqueue(envelopeFrame(e, false))
	}
	c.enqueue(mustJSON(map[string]string{"t": "synced"}))

	limiter := rate.NewLimiter(20, 40) // 20 frames/s, ráfagas de 40
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if !limiter.Allow() {
			c.enqueue(mustJSON(errFrame{T: "error", Code: "rate_limited", Message: "vas muy rápido"}))
			continue
		}
		var f inFrame
		if err := json.Unmarshal(data, &f); err != nil {
			c.enqueue(mustJSON(errFrame{T: "error", Code: "bad_frame", Message: "JSON inválido"}))
			continue
		}
		switch f.T {
		case "send":
			c.enqueue(h.handleSend(ctx, dev, f))
		case "ack":
			if err := h.store.Ack(ctx, dev.AccountID, dev.DeviceID, f.ID); err != nil && !errors.Is(err, store.ErrNotFound) {
				slog.Error("ack", "err", err)
			}
		default:
			c.enqueue(mustJSON(errFrame{T: "error", Ref: f.Ref, Code: "unknown_type", Message: "tipo de frame desconocido"}))
		}
	}
}

func (h *Hub) writeLoop(ctx context.Context, conn *websocket.Conn, c *client) {
	defer conn.CloseNow()
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.closed:
			conn.Close(websocket.StatusPolicyViolation, "conexión reemplazada o lenta")
			return
		case b := <-c.out:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := conn.Write(wctx, websocket.MessageText, b)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (h *Hub) handleSend(ctx context.Context, from store.Device, f inFrame) []byte {
	fail := func(code, msg string, devices []int) []byte {
		return mustJSON(errFrame{T: "error", Ref: f.Ref, Code: code, Message: msg, Devices: devices})
	}

	if f.To == "" || len(f.Messages) == 0 || len(f.Messages) > MaxMessagesPerReq {
		return fail("bad_request", "destinatario o mensajes inválidos", nil)
	}
	for _, m := range f.Messages {
		if len(m.Content) == 0 || len(m.Content) > MaxContentBytes {
			return fail("too_large", "mensaje vacío o demasiado grande", nil)
		}
	}

	// El remitente debe cifrar para TODOS los dispositivos del destinatario.
	want, err := h.store.DeviceIDs(ctx, f.To)
	if err != nil {
		return fail("internal", "error interno", nil)
	}
	if len(want) == 0 {
		return fail("unknown_recipient", "esa cuenta no existe", nil)
	}
	got := make([]int, 0, len(f.Messages))
	for _, m := range f.Messages {
		got = append(got, m.Device)
	}
	slices.Sort(got)
	if !slices.Equal(got, want) {
		return fail("mismatched_devices", "la lista de dispositivos cambió; vuelve a pedir las claves", want)
	}

	now := h.now()
	deliverAt := now
	scheduled := false
	if f.DeliverAt != nil && f.DeliverAt.After(now) {
		if f.Ephemeral {
			return fail("bad_request", "un mensaje efímero no se puede programar", nil)
		}
		if f.DeliverAt.Sub(now) > MaxScheduleAhead {
			return fail("bad_request", "solo se puede programar hasta un año vista", nil)
		}
		deliverAt = f.DeliverAt.UTC()
		scheduled = true
	}

	envs := make([]store.Envelope, len(f.Messages))
	for i, m := range f.Messages {
		envs[i] = store.Envelope{ID: uuid.NewString(), ToAccount: f.To, ToDevice: m.Device,
			FromAccount: from.AccountID, FromDevice: from.DeviceID,
			Type: m.Type, Content: m.Content, ServerTS: now, DeliverAt: deliverAt}
	}

	if f.Ephemeral {
		// Escribiendo/grabando: solo a quien esté conectado. Nunca se guarda.
		for _, e := range envs {
			h.deliver(e, true)
		}
		return mustJSON(sentFrame{T: "sent", Ref: f.Ref, TS: now})
	}

	if err := h.store.Enqueue(ctx, envs); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return fail("mismatched_devices", "la lista de dispositivos cambió", want)
		}
		slog.Error("enqueue", "err", err)
		return fail("internal", "error interno", nil)
	}
	if !scheduled {
		for _, e := range envs {
			if !h.deliver(e, false) {
				h.pusher.Notify(ctx, e.ToAccount, e.ToDevice)
			}
		}
	}
	return mustJSON(sentFrame{T: "sent", Ref: f.Ref, TS: now, Scheduled: scheduled})
}

// deliver envía al dispositivo si está conectado. Devuelve false si no lo está.
func (h *Hub) deliver(e store.Envelope, ephemeral bool) bool {
	h.mu.RLock()
	c, ok := h.conns[devKey{e.ToAccount, e.ToDevice}]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	c.enqueue(envelopeFrame(e, ephemeral))
	return true
}

// RunScheduler entrega los mensajes programados cuando vencen.
// Si el destinatario está desconectado, recibe un push y el mensaje
// le llegará con la cola pendiente al conectar.
func (h *Hub) RunScheduler(ctx context.Context, every time.Duration) {
	last := h.now()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			now := h.now()
			due, err := h.store.DueScheduled(ctx, last, now)
			if err != nil {
				slog.Error("scheduler", "err", err)
				continue
			}
			for _, e := range due {
				if !h.deliver(e, false) {
					h.pusher.Notify(ctx, e.ToAccount, e.ToDevice)
				}
			}
			last = now
		}
	}
}

// Online indica si un dispositivo tiene conexión abierta (para tests y métricas).
func (h *Hub) Online(accountID string, deviceID int) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.conns[devKey{accountID, deviceID}]
	return ok
}
