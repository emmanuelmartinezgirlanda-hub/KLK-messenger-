package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/klk-app/klk-server/internal/store"
)

// Gastos del dueño: apps y suscripciones que paga (panel → Gastos).
// Se guarda como un solo documento JSON; solo lo ve quien tiene la clave del panel.

const (
	expensesKey      = "expenses"
	maxExpenseItems  = 200
	maxExpensesBytes = 64 << 10
)

type expenseItem struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	What     string   `json:"what,omitempty"`
	Amount   *float64 `json:"amount"` // nil = por confirmar
	Currency string   `json:"currency"`
	Every    string   `json:"every"` // month | year | once
	Next     string   `json:"next,omitempty"`
	Notes    string   `json:"notes,omitempty"`
	Paid     bool     `json:"paid,omitempty"` // pagos únicos ya hechos
	Active   bool     `json:"active"`
}

type expensesDoc struct {
	UsdToEur  float64       `json:"usdToEur"`
	Items     []expenseItem `json:"items"`
	UpdatedAt string        `json:"updatedAt,omitempty"`
}

func fptr(v float64) *float64 { return &v }

// Lo que ya sabemos que paga KLK; el resto queda «por confirmar» para que el dueño lo rellene.
func defaultExpenses() expensesDoc {
	return expensesDoc{UsdToEur: 0.9, Items: []expenseItem{
		{ID: "apple", Name: "Apple Developer Program", What: "Publicar en la App Store", Amount: fptr(99), Currency: "USD", Every: "year", Active: true},
		{ID: "gplay", Name: "Google Play Console", What: "Publicar en Google Play", Amount: fptr(25), Currency: "USD", Every: "once", Paid: true, Active: true},
		{ID: "testers", Name: "Testers Community (Starter)", What: "15 testers para Google Play", Amount: fptr(14), Currency: "EUR", Every: "once", Paid: true, Next: "2026-11-05", Active: true},
		{ID: "render", Name: "Render", What: "Servidor de KLK", Currency: "USD", Every: "month", Active: true},
		{ID: "twilio", Name: "Twilio", What: "SMS de los códigos (según uso)", Currency: "USD", Every: "month", Active: true},
		{ID: "codemagic", Name: "Codemagic", What: "Compilar iPhone y TestFlight", Currency: "USD", Every: "month", Active: true},
		{ID: "gemini", Name: "Google AI Pro", What: "Gemini y Flow (vídeos de los anuncios)", Currency: "EUR", Every: "month", Active: true},
		{ID: "suno", Name: "Suno", What: "Música de los anuncios", Currency: "USD", Every: "month", Active: true},
		{ID: "claude", Name: "Claude", What: "Asistente para la app", Currency: "EUR", Every: "month", Active: true},
		{ID: "dominio", Name: "Dominio klkmessenger.com", What: "La página web", Currency: "EUR", Every: "year", Active: true},
	}}
}

func (s *Server) adminExpenses(w http.ResponseWriter, r *http.Request) {
	raw, err := s.store.OwnerSetting(r.Context(), expensesKey)
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusOK, defaultExpenses())
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(raw)
}

func (s *Server) adminSaveExpenses(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxExpensesBytes+1))
	if err != nil || len(body) > maxExpensesBytes {
		writeErr(w, http.StatusBadRequest, "too_big", "la lista es demasiado grande")
		return
	}
	var doc expensesDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "datos no válidos")
		return
	}
	if len(doc.Items) > maxExpenseItems {
		writeErr(w, http.StatusBadRequest, "too_many", "como mucho 200 gastos")
		return
	}
	if doc.UsdToEur <= 0 || doc.UsdToEur > 10 {
		doc.UsdToEur = 0.9
	}
	clip := func(v string, n int) string {
		v = strings.TrimSpace(v)
		for utf8.RuneCountInString(v) > n {
			_, sz := utf8.DecodeLastRuneInString(v)
			v = v[:len(v)-sz]
		}
		return v
	}
	for i := range doc.Items {
		it := &doc.Items[i]
		it.Name, it.What, it.Notes = clip(it.Name, 80), clip(it.What, 120), clip(it.Notes, 300)
		it.ID = clip(it.ID, 40)
		if it.Name == "" {
			writeErr(w, http.StatusBadRequest, "empty", "cada gasto necesita un nombre")
			return
		}
		if it.Currency != "USD" {
			it.Currency = "EUR"
		}
		if it.Every != "year" && it.Every != "once" {
			it.Every = "month"
		}
		if it.Amount != nil && (*it.Amount < 0 || *it.Amount > 1e6) {
			writeErr(w, http.StatusBadRequest, "amount", "importe no válido")
			return
		}
		if it.Next != "" {
			if _, err := time.Parse("2006-01-02", it.Next); err != nil {
				it.Next = ""
			}
		}
	}
	doc.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	out, _ := json.Marshal(doc)
	if err := s.store.SetOwnerSetting(r.Context(), expensesKey, out); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(out)
}
