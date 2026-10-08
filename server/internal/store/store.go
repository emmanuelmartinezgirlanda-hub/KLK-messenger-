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
}
