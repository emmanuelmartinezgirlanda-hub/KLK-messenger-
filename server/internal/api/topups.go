package api

import (
	"context"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/klk-app/klk-server/internal/store"
	"github.com/klk-app/klk-server/internal/topup"
)

// Topups son las recargas de móvil a RD. nil = apagadas.
type Topups struct {
	Provider topup.Provider
	Payments topup.Payments
	Pricing  topup.Pricing
	// PublicURL del servidor para las páginas de "pago hecho" (vacío = la del Host).
	PublicURL string
	// DailyMax: recargas por cuenta al día (por defecto 5).
	DailyMax int
}

const (
	topupExpireAfter = 2 * time.Hour
	topupStuckAfter  = 10 * time.Minute
)

// test: modo prueba (no se mueve dinero de verdad).
func (t *Topups) test() bool { return t.Provider.Sandbox() || t.Payments.Test() }

func (s *Server) topupRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/topups/quote", s.authed(s.topupQuote))
	mux.HandleFunc("POST /v1/topups", s.limited(s.authed(s.topupCreate)))
	mux.HandleFunc("GET /v1/topups", s.authed(s.topupList))
	mux.HandleFunc("GET /v1/topups/{id}", s.authed(s.topupGet))
	mux.HandleFunc("POST /v1/topups/stripe-webhook", s.topupWebhook)
	mux.HandleFunc("GET /topup/done", s.topupPage(true))
	mux.HandleFunc("GET /topup/cancel", s.topupPage(false))
	mux.HandleFunc("GET /topup/test-pay/{id}", s.topupTestPay)
	mux.HandleFunc("POST /topup/test-pay/{id}", s.topupTestPay)
}

func (s *Server) topupsOn(w http.ResponseWriter) bool {
	if s.Topups == nil {
		writeErr(w, http.StatusServiceUnavailable, "topups_off", "las recargas todavía no están disponibles")
		return false
	}
	return true
}

func (s *Server) detect(w http.ResponseWriter, r *http.Request, phone string) (topup.Operator, bool) {
	op, err := s.Topups.Provider.Detect(r.Context(), phone)
	switch {
	case errors.Is(err, topup.ErrNotDominican):
		writeErr(w, http.StatusBadRequest, "not_dominican", err.Error())
	case errors.Is(err, topup.ErrNoOperator):
		writeErr(w, http.StatusNotFound, "no_operator", err.Error())
	case err != nil:
		slog.Error("recargas: detectar operador", "err", err)
		writeErr(w, http.StatusBadGateway, "provider_down", "el servicio de recargas no responde, prueba en un rato")
	default:
		if op.Rate <= 0 {
			writeErr(w, http.StatusBadGateway, "provider_down", "el servicio de recargas no responde, prueba en un rato")
			return op, false
		}
		return op, true
	}
	return op, false
}

type topupOption struct {
	Amount     float64 `json:"amount"`
	PriceCents int64   `json:"priceCents"`
}

func (s *Server) options(op topup.Operator) []topupOption {
	t := s.Topups
	var out []topupOption
	for _, a := range op.Choices(0) {
		p := t.Pricing.PriceCents(op.Cost(a))
		if p <= 0 || (t.Pricing.MaxPrice > 0 && float64(p) > t.Pricing.MaxPrice*100) {
			continue
		}
		out = append(out, topupOption{Amount: a, PriceCents: p})
	}
	return out
}

func (s *Server) topupQuote(w http.ResponseWriter, r *http.Request) {
	if !s.topupsOn(w) {
		return
	}
	phone := strings.TrimSpace(r.URL.Query().Get("phone"))
	op, ok := s.detect(w, r, phone)
	if !ok {
		return
	}
	opts := s.options(op)
	if len(opts) == 0 {
		writeErr(w, http.StatusNotFound, "no_amounts", "no hay montos disponibles para ese número")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"phone": phone, "operator": op.Name, "operatorId": op.ID,
		"localCurrency": op.LocalCurrency, "currency": s.Topups.Pricing.Currency,
		"test": s.Topups.test(), "options": opts,
	})
}

func (s *Server) baseURL(r *http.Request) string {
	if s.Topups.PublicURL != "" {
		return strings.TrimRight(s.Topups.PublicURL, "/")
	}
	return "https://" + r.Host
}

func (s *Server) topupCreate(w http.ResponseWriter, r *http.Request) {
	if !s.topupsOn(w) {
		return
	}
	dev := deviceFrom(r)
	var req struct {
		Phone  string  `json:"phone"`
		Amount float64 `json:"amount"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	max := s.Topups.DailyMax
	if max <= 0 {
		max = 5
	}
	if n, err := s.store.TopupsBy(r.Context(), dev.AccountID, time.Now().Add(-24*time.Hour)); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	} else if n >= max {
		writeErr(w, http.StatusTooManyRequests, "topup_limit", fmt.Sprintf("puedes hacer como mucho %d recargas al día", max))
		return
	}
	op, ok := s.detect(w, r, strings.TrimSpace(req.Phone))
	if !ok {
		return
	}
	var price int64
	for _, o := range s.options(op) {
		if math.Abs(o.Amount-req.Amount) < 0.001 {
			price = o.PriceCents
		}
	}
	if price == 0 {
		writeErr(w, http.StatusBadRequest, "bad_amount", "ese monto no está disponible")
		return
	}
	t := store.Topup{
		ID: uuid.NewString(), AccountID: dev.AccountID, Phone: strings.TrimSpace(req.Phone),
		OperatorID: op.ID, OperatorName: op.Name, LocalAmount: req.Amount, LocalCurrency: op.LocalCurrency,
		PriceCents: price, Currency: s.Topups.Pricing.Currency, Status: store.TopupAwaitingPayment,
		Test: s.Topups.test(), CreatedAt: time.Now(),
	}
	if err := s.store.CreateTopup(r.Context(), t); err != nil {
		slog.Error("recargas: crear", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	base := s.baseURL(r)
	title := fmt.Sprintf("Recarga %s RD$%.0f · %s", shortOperator(op.Name), req.Amount, maskPhone(t.Phone))
	co, err := s.Topups.Payments.Checkout(r.Context(), t.ID, title, price, t.Currency,
		base+"/topup/done?id="+t.ID, base+"/topup/cancel?id="+t.ID)
	if err != nil {
		slog.Error("recargas: página de pago", "err", err)
		s.store.MoveTopup(context.WithoutCancel(r.Context()), t.ID, store.TopupAwaitingPayment, store.TopupExpired,
			store.TopupUpdate{Error: "no se pudo abrir el pago"}, time.Now())
		writeErr(w, http.StatusBadGateway, "payment_down", "no se pudo abrir el pago, prueba en un rato")
		return
	}
	if err := s.store.MoveTopup(r.Context(), t.ID, store.TopupAwaitingPayment, store.TopupAwaitingPayment,
		store.TopupUpdate{PaymentRef: co.Ref}, time.Now()); err != nil {
		slog.Error("recargas: guardar pago", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"topup": t, "payUrl": co.URL})
}

func (s *Server) topupGet(w http.ResponseWriter, r *http.Request) {
	t, err := s.store.GetTopup(r.Context(), r.PathValue("id"))
	if err != nil || t.AccountID != deviceFrom(r).AccountID {
		writeErr(w, http.StatusNotFound, "not_found", "no existe esa recarga")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"topup": t})
}

func (s *Server) topupList(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.TopupsOf(r.Context(), deviceFrom(r).AccountID, 30)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if list == nil {
		list = []store.Topup{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"topups": list})
}

// topupWebhook recibe de Stripe el aviso de "pagado".
func (s *Server) topupWebhook(w http.ResponseWriter, r *http.Request) {
	if s.Topups == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	ev, ok, err := s.Topups.Payments.Webhook(body, r.Header.Get("Stripe-Signature"), time.Now())
	if err != nil {
		slog.Warn("recargas: aviso de pago rechazado", "err", err)
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if !ok {
		w.WriteHeader(http.StatusOK) // otro tipo de aviso: no nos interesa
		return
	}
	if err := s.markPaid(context.WithoutCancel(r.Context()), ev); err != nil && !errors.Is(err, store.ErrWrongState) {
		slog.Error("recargas: marcar pagada", "err", err, "order", ev.OrderID)
		w.WriteHeader(http.StatusInternalServerError) // Stripe lo reintentará
		return
	}
	w.WriteHeader(http.StatusOK)
}

// markPaid pasa la recarga a "pagada" (una sola vez) y la manda al operador.
func (s *Server) markPaid(ctx context.Context, ev topup.PaidEvent) error {
	t, err := s.store.GetTopup(ctx, ev.OrderID)
	if errors.Is(err, store.ErrNotFound) {
		t, err = s.store.TopupByPaymentRef(ctx, ev.Ref)
	}
	if err != nil {
		return err
	}
	if t.PaymentRef != "" && ev.Ref != "" && t.PaymentRef != ev.Ref {
		return fmt.Errorf("el pago %s no es de la recarga %s", ev.Ref, t.ID)
	}
	u := store.TopupUpdate{PaymentIntent: ev.PaymentIntent}
	err = s.store.MoveTopup(ctx, t.ID, store.TopupAwaitingPayment, store.TopupPaid, u, time.Now())
	if errors.Is(err, store.ErrWrongState) {
		// Pagó justo cuando caducaba: se hace igual.
		err = s.store.MoveTopup(ctx, t.ID, store.TopupExpired, store.TopupPaid, u, time.Now())
	}
	if err != nil {
		return err
	}
	t.PaymentIntent = ev.PaymentIntent
	go s.fulfil(context.WithoutCancel(ctx), t)
	return nil
}

// fulfil pide al proveedor que ponga el saldo.
func (s *Server) fulfil(ctx context.Context, t store.Topup) {
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	req := topup.SendRequest{OrderID: t.ID, Phone: t.Phone, OperatorID: t.OperatorID, LocalAmount: t.LocalAmount}
	if op, err := s.Topups.Provider.Detect(ctx, t.Phone); err == nil && !op.LocalAmounts && op.Rate > 0 {
		req.SenderAmount = op.Cost(t.LocalAmount)
	}
	res, err := s.Topups.Provider.Send(ctx, req)
	now := time.Now()
	switch {
	case err == nil:
		if err := s.store.MoveTopup(ctx, t.ID, store.TopupPaid, store.TopupDone,
			store.TopupUpdate{ProviderRef: res.Ref, CostCents: res.CostCents}, now); err != nil {
			slog.Error("recargas: guardar hecha", "err", err, "order", t.ID)
		}
		slog.Info("recarga hecha", "order", t.ID, "test", t.Test)
	case errors.Is(err, topup.ErrRejected):
		slog.Warn("recarga rechazada: se devuelve el dinero", "order", t.ID, "err", err)
		if err := s.store.MoveTopup(ctx, t.ID, store.TopupPaid, store.TopupFailed,
			store.TopupUpdate{Error: truncate(err.Error(), 200)}, now); err != nil {
			slog.Error("recargas: guardar fallida", "err", err, "order", t.ID)
			return
		}
		if err := s.Topups.Payments.Refund(ctx, t.PaymentIntent); err != nil {
			slog.Error("recargas: DEVOLUCIÓN PENDIENTE (hazla a mano en Stripe)", "err", err, "order", t.ID)
			return
		}
		s.store.MoveTopup(ctx, t.ID, store.TopupFailed, store.TopupRefunded, store.TopupUpdate{}, time.Now())
	default:
		// No sabemos si llegó (se cortó la conexión): se deja "pagada" para revisarla
		// en el panel. No se reintenta solo para no recargar dos veces.
		slog.Error("recargas: sin respuesta del proveedor, revisar a mano", "err", err, "order", t.ID)
		s.store.MoveTopup(ctx, t.ID, store.TopupPaid, store.TopupPaid,
			store.TopupUpdate{Error: "sin respuesta del proveedor: revísala en Reloadly"}, now)
	}
}

// SweepTopups caduca las recargas que nadie pagó. Se llama cada pocos minutos.
func (s *Server) SweepTopups(ctx context.Context, now time.Time) {
	if s.Topups == nil {
		return
	}
	list, err := s.store.StaleTopups(ctx, store.TopupAwaitingPayment, now.Add(-topupExpireAfter), 200)
	if err != nil {
		slog.Warn("recargas: limpieza", "err", err)
		return
	}
	for _, t := range list {
		s.store.MoveTopup(ctx, t.ID, store.TopupAwaitingPayment, store.TopupExpired, store.TopupUpdate{}, now)
	}
}

func shortOperator(n string) string {
	n = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(n), "República Dominicana"))
	n = strings.TrimSpace(strings.TrimSuffix(n, "Dominican Republic"))
	if n == "" {
		return "RD"
	}
	return n
}

func maskPhone(p string) string {
	if len(p) < 6 {
		return p
	}
	return p[:len(p)-4] + "••" + p[len(p)-2:]
}

// ---------- Páginas que ve el cliente en el navegador ----------

var topupPageTmpl = template.Must(template.New("p").Parse(`<!doctype html><html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>KLK messenger</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#f3f6fb;color:#0b1b33;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center}
.c{background:#fff;border-radius:22px;padding:28px 24px;max-width:380px;margin:16px;text-align:center;box-shadow:0 6px 30px #0b1b3314}
h1{font-size:22px;margin:10px 0}p{color:#4a5a72;line-height:1.45}.e{font-size:56px}
button{background:#002D62;color:#fff;border:0;border-radius:999px;padding:14px 26px;font-size:17px;font-weight:700;width:100%;margin-top:10px}
.t{display:inline-block;background:#FFD60A;color:#000;border-radius:999px;padding:4px 10px;font-size:12px;font-weight:700}</style>
</head><body><div class="c">{{if .Test}}<span class="t">MODO PRUEBA</span>{{end}}
<div class="e">{{.Emoji}}</div><h1>{{.Title}}</h1><p>{{.Body}}</p>
{{if .Form}}<form method="post"><button type="submit">Pagar {{.Price}} (prueba)</button></form>
<p style="font-size:13px">No se cobra nada: es solo para probar.</p>{{end}}
</div></body></html>`))

type topupPageData struct {
	Test               bool
	Emoji, Title, Body string
	Form               bool
	Price              string
}

func renderTopupPage(w http.ResponseWriter, status int, d topupPageData) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
	w.WriteHeader(status)
	topupPageTmpl.Execute(w, d)
}

func (s *Server) topupPage(done bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		test := s.Topups != nil && s.Topups.test()
		if done {
			renderTopupPage(w, http.StatusOK, topupPageData{Test: test, Emoji: "✅", Title: "¡Pago hecho!",
				Body: "Vuelve a KLK messenger: en unos segundos verás la recarga en el chat."})
			return
		}
		renderTopupPage(w, http.StatusOK, topupPageData{Test: test, Emoji: "↩️", Title: "Pago cancelado",
			Body: "No se cobró nada. Vuelve a KLK messenger para intentarlo otra vez."})
	}
}

// topupTestPay es la página de pago de mentira del modo prueba.
func (s *Server) topupTestPay(w http.ResponseWriter, r *http.Request) {
	if s.Topups == nil {
		http.NotFound(w, r)
		return
	}
	if _, fake := s.Topups.Payments.(*topup.FakePay); !fake {
		http.NotFound(w, r)
		return
	}
	t, err := s.store.GetTopup(r.Context(), r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	price := fmt.Sprintf("%.2f %s", float64(t.PriceCents)/100, t.Currency)
	if r.Method == http.MethodPost {
		err := s.markPaid(context.WithoutCancel(r.Context()),
			topup.PaidEvent{Ref: t.PaymentRef, OrderID: t.ID, PaymentIntent: "fake_pi_" + t.ID})
		if err != nil && !errors.Is(err, store.ErrWrongState) {
			slog.Error("recargas: pago de prueba", "err", err)
			renderTopupPage(w, http.StatusInternalServerError, topupPageData{Test: true, Emoji: "⚠️",
				Title: "Algo falló", Body: "Prueba otra vez."})
			return
		}
		renderTopupPage(w, http.StatusOK, topupPageData{Test: true, Emoji: "✅", Title: "¡Pago hecho!",
			Body: "Vuelve a KLK messenger: en unos segundos verás la recarga en el chat."})
		return
	}
	if t.Status != store.TopupAwaitingPayment {
		renderTopupPage(w, http.StatusOK, topupPageData{Test: true, Emoji: "ℹ️", Title: "Esta recarga ya se pagó",
			Body: "Vuelve a KLK messenger."})
		return
	}
	renderTopupPage(w, http.StatusOK, topupPageData{Test: true, Emoji: "📱",
		Title: fmt.Sprintf("Recarga %s RD$%.0f", shortOperator(t.OperatorName), t.LocalAmount),
		Body:  "Para el número " + maskPhone(t.Phone) + ".", Form: true, Price: price})
}
