package topup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Reloadly es el proveedor de recargas (https://www.reloadly.com).
// En modo prueba (sandbox) no se pone saldo de verdad ni se gasta dinero.
type Reloadly struct {
	ClientID, ClientSecret string
	Test                   bool
	HTTP                   *http.Client
	// Para pruebas: direcciones de la API.
	AuthURL, APIURL string

	mu      sync.Mutex
	token   string
	expires time.Time
}

func (r *Reloadly) Sandbox() bool { return r.Test }

func (r *Reloadly) api() string {
	if r.APIURL != "" {
		return r.APIURL
	}
	if r.Test {
		return "https://topups-sandbox.reloadly.com"
	}
	return "https://topups.reloadly.com"
}

func (r *Reloadly) client() *http.Client {
	if r.HTTP != nil {
		return r.HTTP
	}
	return &http.Client{Timeout: 45 * time.Second}
}

func (r *Reloadly) accessToken(ctx context.Context) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.token != "" && time.Now().Before(r.expires) {
		return r.token, nil
	}
	authURL := r.AuthURL
	if authURL == "" {
		authURL = "https://auth.reloadly.com/oauth/token"
	}
	body, _ := json.Marshal(map[string]string{
		"client_id": r.ClientID, "client_secret": r.ClientSecret,
		"grant_type": "client_credentials", "audience": r.api(),
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, authURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := r.do(req, &out); err != nil {
		return "", fmt.Errorf("reloadly auth: %w", err)
	}
	if out.AccessToken == "" {
		return "", errors.New("reloadly auth: sin token")
	}
	r.token = out.AccessToken
	life := time.Duration(out.ExpiresIn) * time.Second
	if life <= 0 || life > 24*time.Hour {
		life = time.Hour
	}
	r.expires = time.Now().Add(life - time.Minute)
	return r.token, nil
}

type reloadlyErr struct {
	Status    int
	Message   string `json:"message"`
	ErrorCode string `json:"errorCode"`
}

func (e *reloadlyErr) Error() string {
	return fmt.Sprintf("reloadly %d %s: %s", e.Status, e.ErrorCode, e.Message)
}

func (r *Reloadly) do(req *http.Request, out any) error {
	res, err := r.client().Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if res.StatusCode >= 300 {
		e := &reloadlyErr{Status: res.StatusCode}
		_ = json.Unmarshal(data, e)
		if e.Message == "" {
			e.Message = strings.TrimSpace(string(data))
			if len(e.Message) > 200 {
				e.Message = e.Message[:200]
			}
		}
		return e
	}
	return json.Unmarshal(data, out)
}

func (r *Reloadly) call(ctx context.Context, method, path string, in, out any) error {
	tok, err := r.accessToken(ctx)
	if err != nil {
		return err
	}
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, r.api()+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/com.reloadly.topups-v1+json")
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	err = r.do(req, out)
	var re *reloadlyErr
	if errors.As(err, &re) && re.Status == http.StatusUnauthorized {
		r.mu.Lock()
		r.token = ""
		r.mu.Unlock()
	}
	return err
}

type reloadlyOperator struct {
	OperatorID           int64     `json:"operatorId"`
	Name                 string    `json:"name"`
	DenominationType     string    `json:"denominationType"`
	SupportsLocalAmounts bool      `json:"supportsLocalAmounts"`
	DestinationCurrency  string    `json:"destinationCurrencyCode"`
	LocalMinAmount       *float64  `json:"localMinAmount"`
	LocalMaxAmount       *float64  `json:"localMaxAmount"`
	MinAmount            *float64  `json:"minAmount"`
	MaxAmount            *float64  `json:"maxAmount"`
	LocalFixedAmounts    []float64 `json:"localFixedAmounts"`
	FixedAmounts         []float64 `json:"fixedAmounts"`
	FX                   struct {
		Rate float64 `json:"rate"`
	} `json:"fx"`
}

func val(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}

func (o reloadlyOperator) toOperator() Operator {
	op := Operator{ID: o.OperatorID, Name: o.Name, Rate: o.FX.Rate, LocalAmounts: o.SupportsLocalAmounts,
		LocalCurrency: o.DestinationCurrency}
	if op.LocalCurrency == "" {
		op.LocalCurrency = "DOP"
	}
	if o.DenominationType == "FIXED" {
		if len(o.LocalFixedAmounts) > 0 {
			op.Amounts = o.LocalFixedAmounts
		} else {
			for _, a := range o.FixedAmounts {
				op.Amounts = append(op.Amounts, math.Round(a*o.FX.Rate))
			}
		}
		return op
	}
	if o.SupportsLocalAmounts && o.LocalMinAmount != nil {
		op.Min, op.Max = val(o.LocalMinAmount), val(o.LocalMaxAmount)
	} else {
		op.Min, op.Max = val(o.MinAmount)*o.FX.Rate, val(o.MaxAmount)*o.FX.Rate
	}
	return op
}

func (r *Reloadly) Detect(ctx context.Context, phone string) (Operator, error) {
	iso := CountryOf(phone)
	if iso == "" {
		return Operator{}, ErrUnsupportedCountry
	}
	var o reloadlyOperator
	path := "/operators/auto-detect/phone/" + url.PathEscape(strings.TrimPrefix(phone, "+")) + "/countries/" + iso
	if err := r.call(ctx, http.MethodGet, path, nil, &o); err != nil {
		var re *reloadlyErr
		if errors.As(err, &re) && (re.Status == http.StatusNotFound || re.Status == http.StatusBadRequest) {
			return Operator{}, ErrNoOperator
		}
		return Operator{}, err
	}
	if o.OperatorID == 0 {
		return Operator{}, ErrNoOperator
	}
	return o.toOperator(), nil
}

func (r *Reloadly) Send(ctx context.Context, s SendRequest) (SendResult, error) {
	in := map[string]any{
		"operatorId":       s.OperatorID,
		"customIdentifier": s.OrderID, // evita recargas dobles si se reintenta
		"recipientPhone":   map[string]string{"countryCode": CountryOf(s.Phone), "number": strings.TrimPrefix(s.Phone, "+")},
	}
	if s.SenderAmount > 0 {
		in["amount"] = math.Round(s.SenderAmount*100) / 100
		in["useLocalAmount"] = false
	} else {
		in["amount"] = s.LocalAmount
		in["useLocalAmount"] = true
	}
	var out struct {
		TransactionID   int64   `json:"transactionId"`
		Status          string  `json:"status"`
		RequestedAmount float64 `json:"requestedAmount"`
		Discount        float64 `json:"discount"`
		Balance         struct {
			Cost float64 `json:"cost"`
		} `json:"balanceInfo"`
	}
	if err := r.call(ctx, http.MethodPost, "/topups", in, &out); err != nil {
		var re *reloadlyErr
		if errors.As(err, &re) && re.Status >= 400 && re.Status < 500 && re.Status != http.StatusUnauthorized &&
			re.Status != http.StatusTooManyRequests {
			return SendResult{}, fmt.Errorf("%w: %s", ErrRejected, re.Message)
		}
		return SendResult{}, err
	}
	if out.Status != "" && out.Status != "SUCCESSFUL" && out.Status != "PROCESSING" && out.Status != "PENDING" {
		return SendResult{}, fmt.Errorf("%w: estado %s", ErrRejected, out.Status)
	}
	cost := out.Balance.Cost
	if cost == 0 {
		cost = out.RequestedAmount - out.Discount
	}
	return SendResult{Ref: fmt.Sprint(out.TransactionID), CostCents: int64(math.Round(cost * 100))}, nil
}
