package appstore

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"time"
)

// TestSigner firma compras falsas con una cadena propia (solo para pruebas).
type TestSigner struct {
	Roots *x509.CertPool
	key   *ecdsa.PrivateKey
	chain []string
}

// NewTestSigner crea raíz → intermedio → hoja.
func NewTestSigner() *TestSigner {
	mk := func(cn string, parent *x509.Certificate, parentKey *ecdsa.PrivateKey, ca bool) (*x509.Certificate, *ecdsa.PrivateKey) {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{
			SerialNumber:          big.NewInt(time.Now().UnixNano()),
			Subject:               pkix.Name{CommonName: cn},
			NotBefore:             time.Now().Add(-time.Hour),
			NotAfter:              time.Now().Add(24 * time.Hour),
			IsCA:                  ca,
			BasicConstraintsValid: true,
			KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		}
		if parent == nil {
			parent, parentKey = tpl, k
		}
		der, _ := x509.CreateCertificate(rand.Reader, tpl, parent, &k.PublicKey, parentKey)
		c, _ := x509.ParseCertificate(der)
		return c, k
	}
	root, rk := mk("root", nil, nil, true)
	inter, ik := mk("inter", root, rk, true)
	leaf, lk := mk("leaf", inter, ik, false)
	pool := x509.NewCertPool()
	pool.AddCert(root)
	enc := base64.StdEncoding.EncodeToString
	return &TestSigner{Roots: pool, key: lk, chain: []string{enc(leaf.Raw), enc(inter.Raw), enc(root.Raw)}}
}

// Sign devuelve el JWS de la compra.
func (t *TestSigner) Sign(tx Transaction) string {
	h, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": t.chain})
	p, _ := json.Marshal(tx)
	b := base64.RawURLEncoding
	in := b.EncodeToString(h) + "." + b.EncodeToString(p)
	sum := sha256.Sum256([]byte(in))
	r, s, _ := ecdsa.Sign(rand.Reader, t.key, sum[:])
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return in + "." + b.EncodeToString(sig)
}
