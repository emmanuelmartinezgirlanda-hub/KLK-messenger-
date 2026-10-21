// Package topup hace recargas de móvil a RD: el cliente paga con tarjeta
// (Stripe) y un proveedor autorizado (Reloadly) pone el saldo en el número.
package topup

import (
	"context"
	"errors"
	"math"
	"strings"
)

// Operator es la compañía del número (Claro, Altice, Viva) y lo que se puede recargar.
type Operator struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	// Rate: cuántos pesos (moneda local) da el proveedor por cada unidad de la moneda de la cuenta.
	Rate float64 `json:"-"`
	// Amounts: montos fijos en pesos (si el operador solo acepta montos fijos).
	Amounts []float64 `json:"-"`
	// Min/Max en pesos (si acepta cualquier monto en ese rango).
	Min, Max float64 `json:"-"`
	// LocalAmounts: se puede pedir la recarga directamente en pesos.
	LocalAmounts  bool   `json:"-"`
	LocalCurrency string `json:"localCurrency"`
}

// SendRequest pide poner [LocalAmount] pesos en [Phone].
type SendRequest struct {
	OrderID     string
	Phone       string // E.164, p. ej. +18095551234
	OperatorID  int64
	LocalAmount float64
	// SenderAmount: lo mismo en la moneda de la cuenta (si el operador no admite pesos).
	SenderAmount float64
}

// SendResult es lo que contestó el proveedor.
type SendResult struct {
	Ref       string
	CostCents int64 // lo que cobró el proveedor, en céntimos de la moneda de la cuenta
}

// Provider pone el saldo en el móvil.
type Provider interface {
	Detect(ctx context.Context, phone string) (Operator, error)
	Send(ctx context.Context, r SendRequest) (SendResult, error)
	Sandbox() bool
}

var (
	ErrUnsupportedCountry = errors.New("todavía no hacemos recargas a números de ese país")
	ErrNoOperator         = errors.New("no encontramos la compañía de ese número")
	// ErrRejected: el proveedor dijo que no (no se cobra; se devuelve el pago).
	ErrRejected = errors.New("la compañía no aceptó la recarga")
)

// IsDominican dice si es un móvil de RD (+1 809/829/849 + 7 cifras).
func IsDominican(phone string) bool {
	if len(phone) != 12 || !strings.HasPrefix(phone, "+1") {
		return false
	}
	for _, c := range phone[1:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	a := phone[2:5]
	return a == "809" || a == "829" || a == "849"
}

// Presets: los montos en pesos que se ofrecen en la app (RD).
var Presets = []float64{50, 100, 150, 200, 300, 500, 1000}

// senderPresets: para otros países, montos parecidos a 5, 10, 15… en la moneda
// de la cuenta (euros/dólares), pasados a la moneda del país y redondeados.
var senderPresets = []float64{5, 10, 15, 20, 30, 50}

func (o Operator) presets() []float64 {
	if o.LocalCurrency == "" || o.LocalCurrency == "DOP" || o.Rate <= 0 {
		return Presets
	}
	var out []float64
	for _, p := range senderPresets {
		v := niceRound(p * o.Rate)
		if len(out) == 0 || v > out[len(out)-1] {
			out = append(out, v)
		}
	}
	return out
}

// Choices devuelve los montos (en pesos) que se pueden ofrecer para este operador.
func (o Operator) Choices(maxLocal float64) []float64 {
	var out []float64
	if len(o.Amounts) > 0 {
		for _, a := range o.Amounts {
			if a > 0 && (maxLocal <= 0 || a <= maxLocal) {
				out = append(out, a)
			}
		}
		if len(out) > 8 {
			out = out[:8]
		}
		return out
	}
	for _, a := range o.presets() {
		if (o.Min <= 0 || a >= o.Min) && (o.Max <= 0 || a <= o.Max) && (maxLocal <= 0 || a <= maxLocal) {
			out = append(out, a)
		}
	}
	return out
}

// Allows dice si se puede recargar ese monto.
func (o Operator) Allows(local float64) bool {
	for _, a := range o.Choices(0) {
		if math.Abs(a-local) < 0.001 {
			return true
		}
	}
	return false
}

// Pricing calcula lo que paga el cliente.
type Pricing struct {
	Currency string  // moneda del cobro (la de la cuenta del proveedor), p. ej. "EUR" o "USD"
	Margin   float64 // ganancia de KLK, p. ej. 0.08 = 8 %
	Fee      float64 // cargo fijo por recarga (cubre la comisión de la tarjeta), p. ej. 0.30
	MaxPrice float64 // tope por recarga, p. ej. 40
}

// Cost: lo que cuesta al proveedor, en la moneda de la cuenta.
func (o Operator) Cost(local float64) float64 {
	if o.Rate <= 0 {
		return 0
	}
	return local / o.Rate
}

// PriceCents: lo que paga el cliente, en céntimos (redondeado hacia arriba).
func (p Pricing) PriceCents(cost float64) int64 {
	if cost <= 0 {
		return 0
	}
	return int64(math.Ceil((cost*(1+p.Margin) + p.Fee) * 100))
}
