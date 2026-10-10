package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// RemoteVerifier delega el envío y la comprobación del código en un servicio
// externo (Twilio Verify). Así el servidor nunca genera ni guarda el código.
type RemoteVerifier interface {
	Start(phone string) error
	Check(phone, code string) (bool, error)
}

// TwilioVerify usa la API de Twilio Verify v2.
//
//	TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN y TWILIO_VERIFY_SERVICE_SID ("VA…").
//
// Ventajas frente a TwilioSender: no hace falta comprar un número, funciona en
// casi todos los países y trae protección antifraude (Fraud Guard).
type TwilioVerify struct {
	AccountSID string
	AuthToken  string
	ServiceSID string
	Locale     string // idioma del SMS, p. ej. "es". Vacío = automático
	BaseURL    string // vacío = https://verify.twilio.com (se cambia en tests)
	Client     *http.Client
}

func (t TwilioVerify) post(path string, form url.Values) (*http.Response, error) {
	base := t.BaseURL
	if base == "" {
		base = "https://verify.twilio.com"
	}
	client := t.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	endpoint := fmt.Sprintf("%s/v2/Services/%s/%s", base, url.PathEscape(t.ServiceSID), path)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(t.AccountSID, t.AuthToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("twilio verify: %w", err)
	}
	return res, nil
}

// Start envía el código por SMS.
func (t TwilioVerify) Start(phone string) error {
	form := url.Values{"To": {phone}, "Channel": {"sms"}}
	if t.Locale != "" {
		form.Set("Locale", t.Locale)
	}
	res, err := t.post("Verifications", form)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
		return fmt.Errorf("twilio verify: estado %d: %s", res.StatusCode, body)
	}
	return nil
}

// Check devuelve true solo si Twilio aprueba el código.
func (t TwilioVerify) Check(phone, code string) (bool, error) {
	res, err := t.post("VerificationCheck", url.Values{"To": {phone}, "Code": {code}})
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	// 404: no hay verificación pendiente (vencida, ya usada o demasiados intentos).
	if res.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if res.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
		return false, fmt.Errorf("twilio verify: estado %d: %s", res.StatusCode, body)
	}
	var out struct {
		Status string `json:"status"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&out); err != nil {
		return false, fmt.Errorf("twilio verify: respuesta inválida: %w", err)
	}
	return out.Status == "approved", nil
}
