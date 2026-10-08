// Package auth gestiona la verificación por SMS y los tokens de sesión.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"regexp"
	"sync"
	"time"
)

var (
	ErrInvalidPhone = errors.New("número inválido: usa formato E.164, p. ej. +18095551234")
	ErrTooSoon      = errors.New("espera un minuto antes de pedir otro código")
	ErrBadCode      = errors.New("código incorrecto o vencido")
)

var e164 = regexp.MustCompile(`^\+[1-9]\d{7,14}$`)

func ValidPhone(p string) bool { return e164.MatchString(p) }

// SMSSender envía el código. En producción: Twilio, Vonage, etc.
type SMSSender interface {
	Send(phone, message string) error
}

// LogSender imprime el código en el log (solo desarrollo).
type LogSender struct{}

func (LogSender) Send(phone, msg string) error {
	slog.Info("SMS (dev)", "to", phone, "msg", msg)
	return nil
}

const (
	codeTTL     = 10 * time.Minute
	resendAfter = time.Minute
	maxAttempts = 5
)

type pendingCode struct {
	hash     [32]byte
	expires  time.Time
	sentAt   time.Time
	attempts int
}

// OTP guarda los códigos en memoria. Para varias instancias, mover a Redis.
type OTP struct {
	mu     sync.Mutex
	codes  map[string]*pendingCode
	sender SMSSender
	now    func() time.Time
}

func NewOTP(sender SMSSender) *OTP {
	return &OTP{codes: map[string]*pendingCode{}, sender: sender, now: time.Now}
}

func (o *OTP) Request(phone string) error {
	if !ValidPhone(phone) {
		return ErrInvalidPhone
	}
	o.mu.Lock()
	if pc, ok := o.codes[phone]; ok && o.now().Sub(pc.sentAt) < resendAfter {
		o.mu.Unlock()
		return ErrTooSoon
	}
	code, err := randomDigits(6)
	if err != nil {
		o.mu.Unlock()
		return err
	}
	now := o.now()
	o.codes[phone] = &pendingCode{hash: sha256.Sum256([]byte(code)), expires: now.Add(codeTTL), sentAt: now}
	o.mu.Unlock()

	return o.sender.Send(phone, fmt.Sprintf("Tu código de KLK es %s. No lo compartas con nadie.", code))
}

// Verify comprueba el código. Cada código admite como máximo 5 intentos.
func (o *OTP) Verify(phone, code string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	pc, ok := o.codes[phone]
	if !ok || o.now().After(pc.expires) {
		delete(o.codes, phone)
		return ErrBadCode
	}
	pc.attempts++
	h := sha256.Sum256([]byte(code))
	if subtle.ConstantTimeCompare(h[:], pc.hash[:]) != 1 {
		if pc.attempts >= maxAttempts {
			delete(o.codes, phone)
		}
		return ErrBadCode
	}
	delete(o.codes, phone)
	return nil
}

// NewToken genera un token de sesión aleatorio (256 bits) y su hash.
// Al cliente se le da el token; en la BD solo se guarda el hash.
func NewToken() (token string, hash []byte, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return "", nil, err
	}
	token = base64.RawURLEncoding.EncodeToString(b)
	return token, HashToken(token), nil
}

func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

func randomDigits(n int) (string, error) {
	max := big.NewInt(1)
	for i := 0; i < n; i++ {
		max.Mul(max, big.NewInt(10))
	}
	v, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%0*d", n, v), nil
}
