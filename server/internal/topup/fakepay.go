package topup

import (
	"context"
	"strings"
	"time"
)

// FakePay es un cobro de mentira para el modo prueba: abre una página del
// propio servidor con un botón "Pagar (prueba)". No se cobra nada.
type FakePay struct {
	// BaseURL del servidor, p. ej. https://klk-server.onrender.com
	BaseURL string
}

func (*FakePay) Test() bool { return true }

func (f *FakePay) Checkout(_ context.Context, orderID, _ string, _ int64, _, _, _ string) (Checkout, error) {
	return Checkout{URL: strings.TrimRight(f.BaseURL, "/") + "/topup/test-pay/" + orderID, Ref: "fake_" + orderID}, nil
}

func (*FakePay) Refund(context.Context, string) error { return nil }

func (*FakePay) Webhook([]byte, string, time.Time) (PaidEvent, bool, error) {
	return PaidEvent{}, false, ErrBadSignature
}
