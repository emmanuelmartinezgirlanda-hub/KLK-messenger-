package topup

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Checkout es la página de pago con tarjeta (Apple Pay y Google Pay incluidos).
type Checkout struct {
	URL string // donde paga el cliente
	Ref string // id de la sesión de pago
}

// PaidEvent: el cliente pagó.
type PaidEvent struct {
	Ref           string // id de la sesión
	OrderID       string
	PaymentIntent string
}

// Payments cobra al cliente.
type Payments interface {
	Checkout(ctx context.Context, orderID, title string, cents int64, currency, successURL, cancelURL string) (Checkout, error)
	Refund(ctx context.Context, paymentIntent string) error
	// Webhook lee y comprueba un aviso del banco. ok=false si no es un pago completado.
	Webhook(body []byte, signature string, now time.Time) (ev PaidEvent, ok bool, err error)
	Test() bool
}

// Stripe cobra con Stripe Checkout. Con claves sk_test_… no se cobra dinero de verdad.
type Stripe struct {
	SecretKey     string
	WebhookSecret string
	HTTP          *http.Client
	APIURL        string
}

var ErrBadSignature = errors.New("firma de Stripe incorrecta")

func (s *Stripe) Test() bool { return strings.HasPrefix(s.SecretKey, "sk_test_") || strings.HasPrefix(s.SecretKey, "rk_test_") }

func (s *Stripe) post(ctx context.Context, path string, form url.Values, idem string, out any) error {
	base := s.APIURL
	if base == "" {
		base = "https://api.stripe.com"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+path, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.SetBasicAuth(s.SecretKey, "")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if idem != "" {
		req.Header.Set("Idempotency-Key", idem)
	}
	c := s.HTTP
	if c == nil {
		c = &http.Client{Timeout: 30 * time.Second}
	}
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 300 {
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		return fmt.Errorf("stripe %d: %s", res.StatusCode, e.Error.Message)
	}
	return json.Unmarshal(data, out)
}

func (s *Stripe) Checkout(ctx context.Context, orderID, title string, cents int64, currency, successURL, cancelURL string) (Checkout, error) {
	f := url.Values{}
	f.Set("mode", "payment")
	f.Set("client_reference_id", orderID)
	f.Set("metadata[order_id]", orderID)
	f.Set("payment_intent_data[metadata][order_id]", orderID)
	f.Set("line_items[0][quantity]", "1")
	f.Set("line_items[0][price_data][currency]", strings.ToLower(currency))
	f.Set("line_items[0][price_data][unit_amount]", strconv.FormatInt(cents, 10))
	f.Set("line_items[0][price_data][product_data][name]", title)
	f.Set("success_url", successURL)
	f.Set("cancel_url", cancelURL)
	f.Set("expires_at", strconv.FormatInt(time.Now().Add(31*time.Minute).Unix(), 10))
	f.Set("locale", "es")
	var out struct {
		ID  string `json:"id"`
		URL string `json:"url"`
	}
	if err := s.post(ctx, "/v1/checkout/sessions", f, "checkout-"+orderID, &out); err != nil {
		return Checkout{}, err
	}
	return Checkout{URL: out.URL, Ref: out.ID}, nil
}

func (s *Stripe) Refund(ctx context.Context, pi string) error {
	if pi == "" {
		return errors.New("sin pago que devolver")
	}
	f := url.Values{}
	f.Set("payment_intent", pi)
	var out map[string]any
	return s.post(ctx, "/v1/refunds", f, "refund-"+pi, &out)
}

// Webhook comprueba la cabecera Stripe-Signature (t=…,v1=…) como dice Stripe.
func (s *Stripe) Webhook(body []byte, sig string, now time.Time) (PaidEvent, bool, error) {
	if s.WebhookSecret == "" {
		return PaidEvent{}, false, ErrBadSignature
	}
	var ts int64
	var sigs []string
	for _, part := range strings.Split(sig, ",") {
		k, v, _ := strings.Cut(strings.TrimSpace(part), "=")
		switch k {
		case "t":
			ts, _ = strconv.ParseInt(v, 10, 64)
		case "v1":
			sigs = append(sigs, v)
		}
	}
	if ts == 0 || len(sigs) == 0 {
		return PaidEvent{}, false, ErrBadSignature
	}
	if d := now.Sub(time.Unix(ts, 0)); d > 5*time.Minute || d < -5*time.Minute {
		return PaidEvent{}, false, ErrBadSignature
	}
	mac := hmac.New(sha256.New, []byte(s.WebhookSecret))
	mac.Write([]byte(strconv.FormatInt(ts, 10) + "."))
	mac.Write(body)
	want := mac.Sum(nil)
	okSig := false
	for _, v := range sigs {
		if got, err := hex.DecodeString(v); err == nil && hmac.Equal(got, want) {
			okSig = true
		}
	}
	if !okSig {
		return PaidEvent{}, false, ErrBadSignature
	}
	var ev struct {
		Type string `json:"type"`
		Data struct {
			Object struct {
				ID            string            `json:"id"`
				PaymentStatus string            `json:"payment_status"`
				PaymentIntent string            `json:"payment_intent"`
				ClientRef     string            `json:"client_reference_id"`
				Metadata      map[string]string `json:"metadata"`
			} `json:"object"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &ev); err != nil {
		return PaidEvent{}, false, err
	}
	o := ev.Data.Object
	if (ev.Type != "checkout.session.completed" && ev.Type != "checkout.session.async_payment_succeeded") ||
		o.PaymentStatus != "paid" {
		return PaidEvent{}, false, nil
	}
	order := o.Metadata["order_id"]
	if order == "" {
		order = o.ClientRef
	}
	return PaidEvent{Ref: o.ID, OrderID: order, PaymentIntent: o.PaymentIntent}, true, nil
}

// SignForTest firma un cuerpo como lo haría Stripe (solo para pruebas).
func SignForTest(secret string, body []byte, at time.Time) string {
	ts := strconv.FormatInt(at.Unix(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "."))
	mac.Write(body)
	return "t=" + ts + ",v1=" + hex.EncodeToString(mac.Sum(nil))
}
