package topup

import (
	"context"
	"fmt"
	"math"
	"strings"
	"sync"
)

// Fake es un proveedor de mentira para probar la app sin cuentas reales.
// Los números que acaban en 0000 fallan (para probar la devolución del dinero).
type Fake struct {
	mu   sync.Mutex
	Sent []SendRequest
}

func (*Fake) Sandbox() bool { return true }

func (*Fake) Detect(_ context.Context, phone string) (Operator, error) {
	if !IsDominican(phone) {
		return Operator{}, ErrNotDominican
	}
	name := "Claro República Dominicana"
	switch phone[len(phone)-1] {
	case '1', '4', '7':
		name = "Altice República Dominicana"
	case '2', '5':
		name = "Viva República Dominicana"
	}
	return Operator{ID: 100 + int64(phone[len(phone)-1]-'0'), Name: name, Rate: 63.5, Min: 50, Max: 2000,
		LocalAmounts: true, LocalCurrency: "DOP"}, nil
}

func (f *Fake) Send(_ context.Context, r SendRequest) (SendResult, error) {
	if strings.HasSuffix(r.Phone, "0000") {
		return SendResult{}, fmt.Errorf("%w: número de prueba que falla", ErrRejected)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Sent = append(f.Sent, r)
	return SendResult{Ref: fmt.Sprintf("fake-%d", len(f.Sent)), CostCents: int64(math.Round(r.LocalAmount / 63.5 * 100))}, nil
}
