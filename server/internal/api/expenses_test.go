package api_test

import "testing"

// Panel → Gastos: lista por defecto, guardar y volver a leer; sin clave no se ve.
func TestGastosDelPanel(t *testing.T) {
	e := newAdminEnv(t)
	var doc struct {
		UsdToEur float64 `json:"usdToEur"`
		Items    []struct {
			ID     string   `json:"id"`
			Name   string   `json:"name"`
			Amount *float64 `json:"amount"`
			Every  string   `json:"every"`
		} `json:"items"`
	}
	if s := e.do("GET", "/admin/api/expenses", "mala", nil, nil); s != 401 {
		t.Fatalf("sin clave: %d", s)
	}
	if s := e.do("GET", "/admin/api/expenses", adminTok, nil, &doc); s != 200 || len(doc.Items) == 0 {
		t.Fatalf("por defecto: %d %d", s, len(doc.Items))
	}
	body := map[string]any{"usdToEur": 0.93, "items": []map[string]any{
		{"id": "x", "name": "Render", "amount": 7, "currency": "USD", "every": "month", "active": true},
		{"id": "y", "name": "Dominio", "amount": 12, "currency": "EUR", "every": "year", "active": true},
	}}
	if s := e.do("PUT", "/admin/api/expenses", adminTok, body, nil); s != 200 {
		t.Fatalf("guardar: %d", s)
	}
	doc.Items = nil
	e.do("GET", "/admin/api/expenses", adminTok, nil, &doc)
	if len(doc.Items) != 2 || doc.UsdToEur != 0.93 || doc.Items[0].Amount == nil || *doc.Items[0].Amount != 7 {
		t.Fatalf("releer: %+v", doc)
	}
	bad := map[string]any{"items": []map[string]any{{"name": "", "every": "month"}}}
	if s := e.do("PUT", "/admin/api/expenses", adminTok, bad, nil); s != 400 {
		t.Fatalf("sin nombre: %d", s)
	}
}
