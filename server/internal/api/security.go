package api

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// ---------- Antifraude de SMS ----------
//
// Cada SMS cuesta dinero. Hay robots que piden miles de códigos a números de
// pago para cobrar comisiones ("SMS pumping"). Por eso:
//   - solo se envían SMS a los países permitidos (KLK_SMS_COUNTRIES),
//   - hay un tope diario total, por país y por conexión (IP).

// SMSGuard son los límites de envío de códigos.
type SMSGuard struct {
	Countries  []string // prefijos permitidos (+1, +34…); vacío = todos
	DailyMax   int      // SMS al día en total (0 = sin tope)
	CountryMax int      // SMS al día por país
	PerIPMax   int      // SMS al día por conexión
	mu         sync.Mutex
	ipDay      string
	ipCount    map[string]int
}

// DefaultSMSCountries: República Dominicana y los países con más dominicanos.
var DefaultSMSCountries = []string{
	"+1", "+34", "+353", "+44", "+39", "+33", "+49", "+41", "+31", "+32", "+351",
	"+52", "+57", "+58", "+507", "+506", "+509", "+56", "+54", "+51",
}

func (g *SMSGuard) allowedCountry(phone string) bool {
	if len(g.Countries) == 0 {
		return true
	}
	for _, c := range g.Countries {
		if strings.HasPrefix(phone, c) {
			return true
		}
	}
	return false
}

// takeIP cuenta un SMS para esa conexión hoy. false = ya llegó al tope.
func (g *SMSGuard) takeIP(ip string, now time.Time) bool {
	if g.PerIPMax <= 0 {
		return true
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	day := now.UTC().Format("2006-01-02")
	if g.ipDay != day || g.ipCount == nil {
		g.ipDay, g.ipCount = day, map[string]int{}
	}
	if g.ipCount[ip] >= g.PerIPMax {
		return false
	}
	g.ipCount[ip]++
	return true
}

func (g *SMSGuard) giveBackIP(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ipCount[ip] > 0 {
		g.ipCount[ip]--
	}
}

func (s *Server) clientIP(r *http.Request) string {
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	if s.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			ip = strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return ip
}

// smsAllowed comprueba los límites antes de mandar un código.
// Devuelve el código y el mensaje de error, o "" si se puede enviar.
func (s *Server) smsAllowed(ctx context.Context, phone, ip string) (string, string) {
	g := s.SMS
	if g == nil {
		return "", ""
	}
	if !g.allowedCountry(phone) {
		slog.Warn("SMS a país no permitido", "country", store.CountryOf(phone))
		return "country_blocked", "KLK todavía no está disponible en tu país"
	}
	today := time.Now().UTC().Truncate(24 * time.Hour)
	if g.DailyMax > 0 {
		if n, err := s.store.SMSCount(ctx, "", today); err == nil && n >= g.DailyMax {
			slog.Warn("tope diario de SMS alcanzado", "n", n)
			return "sms_limit", "hoy no se pueden enviar más códigos; prueba mañana"
		}
	}
	if g.CountryMax > 0 {
		if n, err := s.store.SMSCount(ctx, store.CountryOf(phone), today); err == nil && n >= g.CountryMax {
			slog.Warn("tope diario de SMS por país", "country", store.CountryOf(phone), "n", n)
			return "sms_limit", "hoy no se pueden enviar más códigos a tu país; prueba mañana"
		}
	}
	if !g.takeIP(ip, time.Now()) {
		return "sms_limit", "has pedido demasiados códigos hoy; prueba mañana"
	}
	return "", ""
}

// ---------- PIN de registro ----------
//
// Si la cuenta tiene PIN, registrarla en otro móvil exige el SMS Y el PIN.
// Si el dueño no usa KLK desde hace 7 días, ya no se pide (como WhatsApp),
// para que nadie se quede fuera para siempre por olvidarlo.

const (
	pinIterations  = 210_000
	pinMaxFailures = 10
	pinGrace       = 7 * 24 * time.Hour
	regTokenTTL    = 10 * time.Minute
)

var pinRe = regexp.MustCompile(`^\d{6}$`)

func hashPin(pin string, salt []byte) ([]byte, error) {
	return pbkdf2.Key(sha256.New, pin, salt, pinIterations, 32)
}

// pinNeeded dice si hay que pedir el PIN para registrar este número ahora.
func pinNeeded(st store.PinState, now time.Time) bool {
	if !st.Enabled() {
		return false
	}
	return st.LastSeen != nil && now.Sub(*st.LastSeen) < pinGrace
}

// regTokens guarda, unos minutos, los números que ya pasaron el SMS y solo
// les falta el PIN (así no hay que mandar otro SMS si se equivocan de PIN).
type regTokens struct {
	mu sync.Mutex
	m  map[string]regToken
}

type regToken struct {
	phone   string
	expires time.Time
}

func (t *regTokens) issue(phone string) string {
	b := make([]byte, 24)
	rand.Read(b)
	tok := base64.RawURLEncoding.EncodeToString(b)
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.m == nil {
		t.m = map[string]regToken{}
	}
	now := time.Now()
	for k, v := range t.m {
		if now.After(v.expires) {
			delete(t.m, k)
		}
	}
	t.m[tok] = regToken{phone: phone, expires: now.Add(regTokenTTL)}
	return tok
}

func (t *regTokens) valid(tok, phone string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	v, ok := t.m[tok]
	if !ok || time.Now().After(v.expires) {
		delete(t.m, tok)
		return false
	}
	return subtle.ConstantTimeCompare([]byte(v.phone), []byte(phone)) == 1
}

func (t *regTokens) drop(tok string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.m, tok)
}

var errPinWrong = errors.New("pin incorrecto")

// checkPin comprueba el PIN y lleva la cuenta de fallos.
// Devuelve (fallos restantes, error).
func (s *Server) checkPin(ctx context.Context, phone, pin string, st store.PinState) (int, error) {
	if st.Failures >= pinMaxFailures {
		return 0, errPinWrong
	}
	got, err := hashPin(pin, st.Salt)
	if err == nil && pinRe.MatchString(pin) && subtle.ConstantTimeCompare(got, st.Hash) == 1 {
		_ = s.store.PinOK(ctx, phone)
		return pinMaxFailures, nil
	}
	n, _ := s.store.PinFailed(ctx, phone)
	left := pinMaxFailures - n
	if left < 0 {
		left = 0
	}
	return left, errPinWrong
}

func (s *Server) pinStatus(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	acc, err := s.store.AccountPhone(r.Context(), dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	st, err := s.store.PinState(r.Context(), acc)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": st.Enabled()})
}

func (s *Server) setPin(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Pin string `json:"pin"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !pinRe.MatchString(req.Pin) {
		writeErr(w, http.StatusBadRequest, "bad_pin", "el PIN tiene que tener 6 números")
		return
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	h, err := hashPin(req.Pin, salt)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if err := s.store.SetPin(r.Context(), dev.AccountID, h, salt); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) clearPin(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if err := s.store.SetPin(r.Context(), dev.AccountID, nil, nil); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
