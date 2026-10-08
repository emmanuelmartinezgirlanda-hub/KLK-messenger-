package auth

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// TwilioSender envía SMS reales con la API REST de Twilio.
//
//	TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN y TWILIO_FROM (número o MessagingServiceSid "MG…").
type TwilioSender struct {
	AccountSID string
	AuthToken  string
	From       string
	BaseURL    string // vacío = https://api.twilio.com (se cambia en tests)
	Client     *http.Client
}

func (t TwilioSender) Send(phone, message string) error {
	base := t.BaseURL
	if base == "" {
		base = "https://api.twilio.com"
	}
	client := t.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}

	form := url.Values{"To": {phone}, "Body": {message}}
	if strings.HasPrefix(t.From, "MG") {
		form.Set("MessagingServiceSid", t.From)
	} else {
		form.Set("From", t.From)
	}

	endpoint := fmt.Sprintf("%s/2010-04-01/Accounts/%s/Messages.json", base, url.PathEscape(t.AccountSID))
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.SetBasicAuth(t.AccountSID, t.AuthToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("twilio: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
		return fmt.Errorf("twilio: estado %d: %s", res.StatusCode, body)
	}
	return nil
}
