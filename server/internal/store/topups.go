package store

import (
	"errors"
	"time"
)

// Estados de una recarga.
const (
	TopupAwaitingPayment = "awaiting_payment" // creada, falta pagar
	TopupPaid            = "paid"             // pagada, se está mandando al operador
	TopupDone            = "done"             // el saldo llegó
	TopupFailed          = "failed"           // el operador no la aceptó (se devuelve el dinero)
	TopupRefunded        = "refunded"         // dinero devuelto al cliente
	TopupExpired         = "expired"          // no se pagó a tiempo
)

// ErrWrongState: la recarga ya no está en el estado esperado (otro proceso la movió).
var ErrWrongState = errors.New("la recarga cambió de estado")

type Topup struct {
	ID            string    `json:"id"`
	AccountID     string    `json:"-"`
	Phone         string    `json:"phone"`
	OperatorID    int64     `json:"operatorId"`
	OperatorName  string    `json:"operator"`
	LocalAmount   float64   `json:"localAmount"`
	LocalCurrency string    `json:"localCurrency"`
	PriceCents    int64     `json:"priceCents"`
	CostCents     int64     `json:"costCents"`
	Currency      string    `json:"currency"`
	Status        string    `json:"status"`
	PaymentRef    string    `json:"-"`
	PaymentIntent string    `json:"-"`
	ProviderRef   string    `json:"-"`
	Error         string    `json:"error,omitempty"`
	Test          bool      `json:"test"`
	CreatedAt     time.Time `json:"createdAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

// TopupUpdate son los campos que se cambian al pasar de estado (vacío = no tocar).
type TopupUpdate struct {
	PaymentRef    string
	PaymentIntent string
	ProviderRef   string
	Error         string
	CostCents     int64
}

// TopupStats para el panel del dueño (solo recargas reales, no de prueba, salvo Test*).
type TopupStats struct {
	DoneMonth     int   `json:"doneMonth"`
	FailedMonth   int   `json:"failedMonth"`
	IncomeMonth   int64 `json:"incomeCents"` // lo que pagaron los clientes
	CostMonth     int64 `json:"costCents"`   // lo que cobró el proveedor
	TestDoneMonth int   `json:"testDoneMonth"`
}

// TopupView es una fila del panel.
type TopupView struct {
	Topup
	PhoneMasked string `json:"phoneMasked"`
}
