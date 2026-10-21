package topup

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIsDominican(t *testing.T) {
	for p, want := range map[string]bool{"+18095551234": true, "+18295551234": true, "+18495551234": true,
		"+17865551234": false, "+1809555123": false, "+34600000000": false, "+1809555123a": false} {
		if IsDominican(p) != want {
			t.Errorf("%s: %v", p, !want)
		}
	}
}

func TestChoicesAndPrice(t *testing.T) {
	op := Operator{Rate: 60, Min: 100, Max: 600}
	got := op.Choices(0)
	if len(got) != 5 || got[0] != 100 || got[4] != 500 {
		t.Fatalf("choices: %v", got)
	}
	if !op.Allows(300) || op.Allows(50) {
		t.Fatal("allows")
	}
	p := Pricing{Margin: 0.1, Fee: 0.3}
	if c := p.PriceCents(op.Cost(600)); c != 1130 { // 10 € ×1.1 + 0.30
		t.Fatalf("precio: %d", c)
	}
	fixed := Operator{Rate: 60, Amounts: []float64{100, 250}}
	if !fixed.Allows(250) || fixed.Allows(200) {
		t.Fatal("fijos")
	}
}

func TestReloadly(t *testing.T) {
	var sent map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/oauth/token":
			w.Write([]byte(`{"access_token":"tok","expires_in":3600}`))
		case r.Header.Get("Authorization") != "Bearer tok":
			w.WriteHeader(401)
		case strings.HasPrefix(r.URL.Path, "/operators/auto-detect/phone/18095550000"):
			w.WriteHeader(404)
			w.Write([]byte(`{"message":"not found","errorCode":"COULD_NOT_AUTO_DETECT_OPERATOR"}`))
		case strings.HasPrefix(r.URL.Path, "/operators/auto-detect/phone/18095551234/countries/DO"):
			w.Write([]byte(`{"operatorId":171,"name":"Claro Dominicana","denominationType":"RANGE","supportsLocalAmounts":true,
				"destinationCurrencyCode":"DOP","localMinAmount":50,"localMaxAmount":5000,"fx":{"rate":64.2}}`))
		case r.URL.Path == "/topups":
			json.NewDecoder(r.Body).Decode(&sent)
			if sent["recipientPhone"].(map[string]any)["number"] == "18095559999" {
				w.WriteHeader(400)
				w.Write([]byte(`{"message":"Invalid phone","errorCode":"INVALID_RECIPIENT_PHONE"}`))
				return
			}
			w.Write([]byte(`{"transactionId":555,"status":"SUCCESSFUL","requestedAmount":3.2,"discount":0.1,"balanceInfo":{"cost":3.1}}`))
		default:
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	r := &Reloadly{ClientID: "a", ClientSecret: "b", Test: true, AuthURL: srv.URL + "/oauth/token", APIURL: srv.URL}
	ctx := context.Background()
	op, err := r.Detect(ctx, "+18095551234")
	if err != nil || op.ID != 171 || op.Rate != 64.2 || op.Max != 5000 || !op.LocalAmounts {
		t.Fatalf("detect: %+v %v", op, err)
	}
	if _, err := r.Detect(ctx, "+18095550000"); !errors.Is(err, ErrNoOperator) {
		t.Fatalf("sin operador: %v", err)
	}
	res, err := r.Send(ctx, SendRequest{OrderID: "o1", Phone: "+18095551234", OperatorID: 171, LocalAmount: 200})
	if err != nil || res.Ref != "555" || res.CostCents != 310 {
		t.Fatalf("send: %+v %v", res, err)
	}
	if sent["customIdentifier"] != "o1" || sent["useLocalAmount"] != true || sent["amount"].(float64) != 200 {
		t.Fatalf("petición: %v", sent)
	}
	if _, err := r.Send(ctx, SendRequest{OrderID: "o2", Phone: "+18095559999", OperatorID: 171, LocalAmount: 200}); !errors.Is(err, ErrRejected) {
		t.Fatalf("rechazo: %v", err)
	}
}

func TestCountryOf(t *testing.T) {
	for phone, want := range map[string]string{
		"+18095551234": "DO", "+17875551234": "PR", "+14165551234": "CA", "+12125551234": "US",
		"+34612345678": "ES", "+353861234567": "IE", "+5999612345": "CW", "+2975601234": "AW",
		"+861234567890": "", "+1809": "",
	} {
		if got := CountryOf(phone); got != want {
			t.Errorf("%s: %q, quería %q", phone, got, want)
		}
	}
	eur := Operator{Rate: 1, LocalCurrency: "EUR", Min: 1, Max: 100}
	if c := eur.Choices(0); len(c) == 0 || c[0] != 5 || c[len(c)-1] != 50 {
		t.Fatalf("montos en euros: %v", c)
	}
	mxn := Operator{Rate: 19.7, LocalCurrency: "MXN", Min: 10, Max: 2000}
	if c := mxn.Choices(0); len(c) == 0 || c[0] != 100 {
		t.Fatalf("montos en pesos mexicanos: %v", c)
	}
	if FormatLocal("DOP", 500) != "RD$ 500" || FormatLocal("EUR", 10) != "€ 10" {
		t.Fatal("formato")
	}
}
