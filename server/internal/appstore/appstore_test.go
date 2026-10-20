package appstore

import (
	"strings"
	"testing"
	"time"
)

func TestVerify(t *testing.T) {
	ts := NewTestSigner()
	v := NewWithRoots(ts.Roots)
	want := Transaction{OriginalTransactionID: "1000", BundleID: "com.klkapp.klk", ProductID: "klk.plus.mensual",
		ExpiresDate: time.Now().Add(time.Hour).UnixMilli()}
	jws := ts.Sign(want)
	got, err := v.Verify(jws, time.Now())
	if err != nil || got.OriginalTransactionID != "1000" || got.ProductID != want.ProductID {
		t.Fatalf("got %+v %v", got, err)
	}
	// Firma cambiada
	parts := strings.Split(jws, ".")
	other := ts.Sign(Transaction{OriginalTransactionID: "2000"})
	forged := parts[0] + "." + strings.Split(other, ".")[1] + "." + parts[2]
	if _, err := v.Verify(forged, time.Now()); err == nil {
		t.Fatal("aceptó un JWS alterado")
	}
	// Otra cadena (no es de nuestra raíz)
	if _, err := v.Verify(NewTestSigner().Sign(want), time.Now()); err == nil {
		t.Fatal("aceptó otra raíz")
	}
	// Con la raíz de Apple, uno de prueba no vale
	if _, err := NewApple().Verify(jws, time.Now()); err == nil {
		t.Fatal("la raíz de Apple aceptó un JWS de prueba")
	}
	if _, err := v.Verify("a.b", time.Now()); err == nil {
		t.Fatal("aceptó basura")
	}
}
