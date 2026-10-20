// Package appstore comprueba las compras de KLK Plus hechas con Apple
// (StoreKit 2). Cada compra llega como un JWS firmado por Apple: se verifica
// la cadena de certificados hasta la raíz de Apple (Apple Root CA - G3) y la
// firma ES256, sin llamar a ningún servidor.
package appstore

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"time"
)

//go:embed apple_root_ca_g3.pem
var appleRootPEM []byte

// Extensiones que Apple pone en sus certificados de firma de compras.
var (
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Transaction son los datos de una compra que nos importan.
type Transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	ExpiresDate           int64  `json:"expiresDate"`    // ms
	RevocationDate        int64  `json:"revocationDate"` // ms, 0 = no
	AppAccountToken       string `json:"appAccountToken"`
	Environment           string `json:"environment"` // "Production" o "Sandbox"
	Type                  string `json:"type"`
}

// Expires es la fecha de fin de la suscripción.
func (t Transaction) Expires() time.Time { return time.UnixMilli(t.ExpiresDate) }

// Verifier comprueba JWS de Apple contra un conjunto de raíces.
type Verifier struct {
	roots *x509.CertPool
	// checkOIDs: en producción se exigen las extensiones de Apple (los tests no las ponen).
	checkOIDs bool
}

// NewApple crea el verificador con la raíz oficial de Apple.
func NewApple() *Verifier {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(appleRootPEM) {
		panic("appstore: raíz de Apple inválida")
	}
	return &Verifier{roots: pool, checkOIDs: true}
}

// NewWithRoots es para pruebas.
func NewWithRoots(roots *x509.CertPool) *Verifier { return &Verifier{roots: roots} }

var ErrInvalid = errors.New("compra de Apple no válida")

func hasExt(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// Verify comprueba el JWS y devuelve la compra.
func (v *Verifier) Verify(jws string, now time.Time) (Transaction, error) {
	var tx Transaction
	if len(jws) > 64*1024 {
		return tx, ErrInvalid
	}
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return tx, ErrInvalid
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return tx, ErrInvalid
	}
	var h struct {
		Alg string   `json:"alg"`
		X5c []string `json:"x5c"`
	}
	if json.Unmarshal(hb, &h) != nil || h.Alg != "ES256" || len(h.X5c) < 2 || len(h.X5c) > 4 {
		return tx, ErrInvalid
	}
	var certs []*x509.Certificate
	for _, c := range h.X5c {
		der, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			return tx, ErrInvalid
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return tx, ErrInvalid
		}
		certs = append(certs, cert)
	}
	leaf := certs[0]
	inter := x509.NewCertPool()
	for _, c := range certs[1:] {
		inter.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.roots,
		Intermediates: inter,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return tx, ErrInvalid
	}
	if v.checkOIDs && (!hasExt(leaf, oidLeaf) || !hasExt(certs[1], oidIntermediate)) {
		return tx, ErrInvalid
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return tx, ErrInvalid
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return tx, ErrInvalid
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, sum[:], r, s) {
		return tx, ErrInvalid
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(pb, &tx) != nil {
		return Transaction{}, ErrInvalid
	}
	return tx, nil
}
