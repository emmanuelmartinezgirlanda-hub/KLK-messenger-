// Package store define el modelo de datos del servidor y su persistencia.
package store

import (
	"context"
	"errors"
	"time"
)

var (
	ErrNotFound = errors.New("no encontrado")
)

type Account struct {
	ID        string
	Phone     string
	CreatedAt time.Time
}

type Device struct {
	AccountID      string
	DeviceID       int
	Name           string
	RegistrationID int
	IdentityKey    []byte
	Banned         bool // la cuenta está bloqueada por el dueño
}

type SignedPreKey struct {
	KeyID     int    `json:"keyId"`
	PublicKey []byte `json:"publicKey"`
	Signature []byte `json:"signature"`
}

type PreKey struct {
	KeyID     int    `json:"keyId"`
	PublicKey []byte `json:"publicKey"`
}

// Bundle es lo que un remitente necesita para iniciar una sesión Signal (X3DH)
// con un dispositivo concreto.
type Bundle struct {
	DeviceID       int           `json:"deviceId"`
	RegistrationID int           `json:"registrationId"`
	IdentityKey    []byte        `json:"identityKey"`
	SignedPreKey   *SignedPreKey `json:"signedPreKey"`
	PreKey         *PreKey       `json:"preKey,omitempty"` // puede agotarse
}

// Envelope es un mensaje cifrado en tránsito. El servidor no puede leer Content.
type Envelope struct {
	ID          string
	ToAccount   string
	ToDevice    int
	FromAccount string
	FromDevice  int
	Type        int
	Content     []byte
	ServerTS    time.Time
	DeliverAt   time.Time
}

// Report es una denuncia de un usuario a otro.
type Report struct {
	ID        string
	Reporter  string
	Reported  string
	Reason    string
	Messages  []string // los que el denunciante decidió adjuntar (opcional)
	CreatedAt time.Time
}

// RegisterParams son los datos públicos del dispositivo al registrarse.
type RegisterParams struct {
	Phone          string
	DeviceName     string
	RegistrationID int
	IdentityKey    []byte
	TokenHash      []byte
}

type Store interface {
	// Registra (o re-registra) el dispositivo principal de un número.
	// Re-registrar sustituye el dispositivo anterior y borra sus claves y cola.
	RegisterPrimary(ctx context.Context, p RegisterParams) (Device, error)
	DeviceByTokenHash(ctx context.Context, tokenHash []byte) (Device, error)
	AccountIDByPhone(ctx context.Context, phone string) (string, error)
	// AccountIDsByPhones devuelve solo los números que tienen cuenta (phone -> accountId).
	AccountIDsByPhones(ctx context.Context, phones []string) (map[string]string, error)
	DeviceIDs(ctx context.Context, accountID string) ([]int, error)

	SetSignedPreKey(ctx context.Context, accountID string, deviceID int, k SignedPreKey) error
	AddPreKeys(ctx context.Context, accountID string, deviceID int, keys []PreKey) error
	PreKeyCount(ctx context.Context, accountID string, deviceID int) (int, error)
	// TakeBundles devuelve un bundle por dispositivo y consume una prekey de un solo uso de cada uno.
	TakeBundles(ctx context.Context, accountID string) ([]Bundle, error)

	Enqueue(ctx context.Context, envs []Envelope) error
	Pending(ctx context.Context, accountID string, deviceID int, now time.Time, limit int) ([]Envelope, error)
	Ack(ctx context.Context, accountID string, deviceID int, envelopeID string) error
	// DueScheduled devuelve los mensajes programados que vencen en (from, to].
	DueScheduled(ctx context.Context, from, to time.Time) ([]Envelope, error)

	// Adjuntos cifrados (bytes opacos).
	PutAttachment(ctx context.Context, id, ownerAccountID string, data []byte) error
	GetAttachment(ctx context.Context, id string) ([]byte, error)
	// PurgeAttachments borra los adjuntos creados antes de [before]. Devuelve cuántos.
	PurgeAttachments(ctx context.Context, before time.Time) (int, error)

	// Denuncias.
	AddReport(ctx context.Context, r Report) error
	// ReportsBy cuenta las denuncias que hizo una cuenta desde [since] (límite anti-abuso).
	ReportsBy(ctx context.Context, reporter string, since time.Time) (int, error)
	AccountExists(ctx context.Context, accountID string) (bool, error)

	// ---- Panel del dueño ----
	// Touch apunta la última conexión de la cuenta.
	Touch(ctx context.Context, accountID string, at time.Time) error
	PhoneBanned(ctx context.Context, phone string) (bool, error)
	SetBanned(ctx context.Context, accountID string, banned bool, reason string) error
	ResolveReport(ctx context.Context, reportID string) error
	ListReports(ctx context.Context, open bool, limit int) ([]ReportView, error)
	Stats(ctx context.Context, now time.Time) (Stats, error)
	LogSMS(ctx context.Context, country string, at time.Time) error
	AddAnnouncement(ctx context.Context, a Announcement) error
	DeleteAnnouncement(ctx context.Context, id string) error
	Announcements(ctx context.Context, limit int) ([]Announcement, error)
	BannedAccounts(ctx context.Context, limit int) ([]AccountView, error)

	// ---- Comunidades por país ----
	JoinCommunity(ctx context.Context, community, accountID string) error
	LeaveCommunity(ctx context.Context, community, accountID string) error
	// CommunityCounts devuelve cuántos miembros (no bloqueados) tiene cada comunidad.
	CommunityCounts(ctx context.Context) (map[string]int, error)
	// CommunitiesOf devuelve las comunidades a las que pertenece una cuenta.
	CommunitiesOf(ctx context.Context, accountID string) ([]string, error)
	// CommunityMembers devuelve los ids de las cuentas (no bloqueadas) de una comunidad.
	CommunityMembers(ctx context.Context, community string, limit int) ([]string, error)
}

// Announcement es un aviso de KLK para todos.
type Announcement struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"createdAt"`
}

// AccountView es lo que el dueño ve de una cuenta (nunca mensajes ni claves).
type AccountView struct {
	ID           string     `json:"id"`
	Phone        string     `json:"phone"`
	CreatedAt    time.Time  `json:"createdAt"`
	LastSeen     *time.Time `json:"lastSeen,omitempty"`
	BannedAt     *time.Time `json:"bannedAt,omitempty"`
	BannedReason string     `json:"bannedReason,omitempty"`
	Reports      int        `json:"reports"`
}

// ReportView es una denuncia con los datos que el dueño necesita para decidir.
type ReportView struct {
	ID         string      `json:"id"`
	Reason     string      `json:"reason"`
	Messages   []string    `json:"messages"`
	CreatedAt  time.Time   `json:"createdAt"`
	ResolvedAt *time.Time  `json:"resolvedAt,omitempty"`
	Reporter   string      `json:"reporterPhone"` // enmascarado
	Reported   AccountView `json:"reported"`
}

// DayCount es un punto de una gráfica diaria.
type DayCount struct {
	Day   string `json:"day"` // AAAA-MM-DD (UTC)
	Count int    `json:"count"`
}

// Stats son los números del panel.
type Stats struct {
	Users        int            `json:"users"`
	NewToday     int            `json:"newToday"`
	New7d        int            `json:"new7d"`
	Active24h    int            `json:"active24h"`
	Active7d     int            `json:"active7d"`
	Active30d    int            `json:"active30d"`
	Banned       int            `json:"banned"`
	OpenReports  int            `json:"openReports"`
	SMSToday     int            `json:"smsToday"`
	SMSMonth     int            `json:"smsMonth"` // desde el día 1 del mes (UTC)
	SMS30d       int            `json:"sms30d"`
	Attachments  int            `json:"attachments"`
	AttachBytes  int64          `json:"attachBytes"`
	Signups      []DayCount     `json:"signups"`  // últimos 30 días
	SMSDaily     []DayCount     `json:"smsDaily"` // últimos 30 días
	Countries    map[string]int `json:"countries"`
}

// MaskPhone deja ver el país y las 2 últimas cifras: +1809•••••34.
func MaskPhone(p string) string {
	r := []rune(p)
	if len(r) < 7 {
		return p
	}
	keep := 4
	out := string(r[:keep])
	for range r[keep : len(r)-2] {
		out += "•"
	}
	return out + string(r[len(r)-2:])
}

// CountryOf devuelve el prefijo de país aproximado de un número E.164.
func CountryOf(phone string) string {
	prefixes := []string{"+1809", "+1829", "+1849", "+353", "+34", "+1", "+44", "+39", "+33", "+49", "+41", "+31", "+32", "+351", "+52", "+57", "+58", "+51", "+56", "+54", "+507", "+506", "+509"}
	for _, p := range prefixes {
		if len(phone) >= len(p) && phone[:len(p)] == p {
			return p
		}
	}
	if len(phone) >= 3 {
		return phone[:3]
	}
	return phone
}

// days30 prepara los 30 días que acaban en [now] (UTC) con cuenta 0.
func days30(now time.Time) ([]DayCount, map[string]int) {
	out := make([]DayCount, 30)
	idx := map[string]int{}
	d0 := now.UTC().Truncate(24 * time.Hour).AddDate(0, 0, -29)
	for i := range out {
		day := d0.AddDate(0, 0, i).Format("2006-01-02")
		out[i] = DayCount{Day: day}
		idx[day] = i
	}
	return out, idx
}
