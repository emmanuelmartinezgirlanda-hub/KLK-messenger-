package auth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Entrar con correo: el servidor genera un código de 6 cifras, lo manda por
// correo y guarda solo su hash (10 minutos, 5 intentos), igual que con SMS.

var (
	ErrInvalidEmail = errors.New("ese correo no es válido")
	emailRe         = regexp.MustCompile(`^[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}$`)
)

// NormalizeEmail: en minúsculas y sin espacios.
func NormalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

func ValidEmail(e string) bool { return len(e) <= 254 && emailRe.MatchString(e) }

// MailIdentity es como se guarda una cuenta creada con correo (en el sitio
// del número de teléfono). Nunca empieza por "+", así que no choca con números.
func MailIdentity(email string) string { return "mail:" + NormalizeEmail(email) }

// IsMailIdentity: ¿la cuenta se creó con correo?
func IsMailIdentity(id string) bool { return strings.HasPrefix(id, "mail:") }

// EmailSender manda un correo.
type EmailSender interface {
	Send(to, subject, text, html string) error
}

// LogMail escribe el correo en el log (solo pruebas).
type LogMail struct{}

func (LogMail) Send(to, subject, text, _ string) error {
	slog.Info("correo (pruebas, no se envía)", "to", to, "subject", subject, "text", text)
	return nil
}

// Resend manda correos con https://resend.com (KLK_RESEND_KEY, KLK_MAIL_FROM).
type Resend struct {
	Key     string
	From    string // p. ej. "KLK messenger <codigo@klkmessenger.com>"
	BaseURL string // vacío = https://api.resend.com (se cambia en tests)
	Client  *http.Client
}

func (r Resend) Send(to, subject, text, html string) error {
	base := r.BaseURL
	if base == "" {
		base = "https://api.resend.com"
	}
	body, _ := json.Marshal(map[string]any{"from": r.From, "to": []string{to}, "subject": subject, "text": text, "html": html})
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, base+"/emails", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+r.Key)
	req.Header.Set("Content-Type", "application/json")
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("resend: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 1024))
		return fmt.Errorf("resend: estado %d: %s", res.StatusCode, b)
	}
	return nil
}

// MailOTP guarda los códigos de correo en memoria.
type MailOTP struct {
	mu     sync.Mutex
	codes  map[string]*pendingCode
	sender EmailSender
	now    func() time.Time
}

func NewMailOTP(sender EmailSender) *MailOTP {
	return &MailOTP{codes: map[string]*pendingCode{}, sender: sender, now: time.Now}
}

func (o *MailOTP) SetNow(now func() time.Time) { o.now = now }

// Request manda un código a [email]. [purpose] separa los códigos de entrar de
// los de añadir el correo a una cuenta (un código no vale para lo otro).
func (o *MailOTP) Request(purpose, email string) error {
	email = NormalizeEmail(email)
	if !ValidEmail(email) {
		return ErrInvalidEmail
	}
	key := purpose + "|" + email
	o.mu.Lock()
	now := o.now()
	if pc, ok := o.codes[key]; ok && now.Sub(pc.sentAt) < resendAfter {
		o.mu.Unlock()
		return ErrTooSoon
	}
	for k, pc := range o.codes { // purga los caducados
		if now.After(pc.expires) {
			delete(o.codes, k)
		}
	}
	code, err := randomDigits(6)
	if err != nil {
		o.mu.Unlock()
		return err
	}
	o.codes[key] = &pendingCode{hash: sha256.Sum256([]byte(code)), expires: now.Add(codeTTL), sentAt: now}
	o.mu.Unlock()

	text := fmt.Sprintf("Tu código de KLK messenger es %s\n\nCaduca en 10 minutos. No se lo des a nadie: nadie de KLK te lo va a pedir.\n\nSi no lo pediste tú, ignora este correo.", code)
	html := fmt.Sprintf(`<div style="font-family:Arial,sans-serif;max-width:420px;margin:auto;padding:24px;color:#0B1B33">
<div style="font-weight:900;font-size:22px;color:#CE1126">¡KLK! <span style="color:#002D62">messenger</span></div>
<p style="font-size:16px">Tu código para entrar es:</p>
<div style="font-size:34px;font-weight:900;letter-spacing:6px;background:#EEF3FA;border-radius:12px;padding:14px;text-align:center;color:#002D62">%s</div>
<p style="font-size:13px;color:#667781">Caduca en 10 minutos. No se lo des a nadie: nadie de KLK te lo va a pedir. Si no lo pediste tú, ignora este correo.</p></div>`, code)
	if err := o.sender.Send(email, fmt.Sprintf("Tu código de KLK: %s", code), text, html); err != nil {
		o.mu.Lock()
		delete(o.codes, key) // que se pueda pedir otro enseguida
		o.mu.Unlock()
		return err
	}
	return nil
}

// Verify comprueba el código (5 intentos como máximo).
func (o *MailOTP) Verify(purpose, email, code string) error {
	key := purpose + "|" + NormalizeEmail(email)
	o.mu.Lock()
	defer o.mu.Unlock()
	pc, ok := o.codes[key]
	if !ok || o.now().After(pc.expires) {
		delete(o.codes, key)
		return ErrBadCode
	}
	pc.attempts++
	h := sha256.Sum256([]byte(strings.TrimSpace(code)))
	if subtle.ConstantTimeCompare(h[:], pc.hash[:]) != 1 {
		if pc.attempts >= maxAttempts {
			delete(o.codes, key)
		}
		return ErrBadCode
	}
	delete(o.codes, key)
	return nil
}
