package topup

import (
	"fmt"
	"math"
	"strings"
)

// Países donde hay diáspora dominicana (y RD). Prefijo internacional → código ISO.
// El orden importa: primero los prefijos más largos.
var countryPrefixes = []struct{ prefix, iso string }{
	{"+5999", "CW"}, {"+297", "AW"}, {"+351", "PT"}, {"+353", "IE"}, {"+376", "AD"},
	{"+502", "GT"}, {"+503", "SV"}, {"+504", "HN"}, {"+505", "NI"}, {"+506", "CR"}, {"+507", "PA"},
	{"+509", "HT"}, {"+591", "BO"}, {"+593", "EC"}, {"+595", "PY"}, {"+598", "UY"},
	{"+30", "GR"}, {"+31", "NL"}, {"+32", "BE"}, {"+33", "FR"}, {"+34", "ES"}, {"+39", "IT"},
	{"+41", "CH"}, {"+43", "AT"}, {"+44", "GB"}, {"+45", "DK"}, {"+46", "SE"}, {"+47", "NO"}, {"+48", "PL"},
	{"+49", "DE"}, {"+51", "PE"}, {"+52", "MX"}, {"+54", "AR"}, {"+55", "BR"}, {"+56", "CL"}, {"+57", "CO"},
	{"+58", "VE"},
}

// Prefijos de zona de Canadá dentro del +1.
var canadaAreas = map[string]bool{
	"204": true, "226": true, "236": true, "249": true, "250": true, "263": true, "289": true, "306": true,
	"343": true, "354": true, "365": true, "367": true, "368": true, "382": true, "403": true, "416": true,
	"418": true, "428": true, "431": true, "437": true, "438": true, "450": true, "468": true, "474": true,
	"506": true, "514": true, "519": true, "548": true, "579": true, "581": true, "584": true, "587": true,
	"604": true, "613": true, "639": true, "647": true, "672": true, "683": true, "705": true, "709": true,
	"742": true, "753": true, "778": true, "780": true, "782": true, "807": true, "819": true, "825": true,
	"867": true, "873": true, "879": true, "902": true, "905": true,
}

// CountryOf devuelve el país (ISO) de un número E.164, o "" si no hacemos recargas allí.
func CountryOf(phone string) string {
	if len(phone) < 8 || len(phone) > 16 || phone[0] != '+' {
		return ""
	}
	for _, c := range phone[1:] {
		if c < '0' || c > '9' {
			return ""
		}
	}
	if strings.HasPrefix(phone, "+1") {
		if len(phone) != 12 {
			return ""
		}
		switch a := phone[2:5]; {
		case a == "809" || a == "829" || a == "849":
			return "DO"
		case a == "787" || a == "939":
			return "PR"
		case canadaAreas[a]:
			return "CA"
		default:
			return "US"
		}
	}
	for _, p := range countryPrefixes {
		if strings.HasPrefix(phone, p.prefix) {
			return p.iso
		}
	}
	return ""
}

// niceRound redondea a un monto "bonito" en la moneda del país (5, 10, 50, 100…).
func niceRound(v float64) float64 {
	step := 1.0
	switch {
	case v >= 20000:
		step = 1000
	case v >= 2000:
		step = 100
	case v >= 200:
		step = 10
	case v >= 30:
		step = 5
	}
	return math.Max(step, math.Round(v/step)*step)
}

// FormatLocal: "RD$ 500", "€ 10", "US$ 15", "MXN 200".
func FormatLocal(currency string, v float64) string {
	sym := map[string]string{"DOP": "RD$", "USD": "US$", "EUR": "€", "GBP": "£", "CAD": "CA$", "CHF": "CHF"}[currency]
	if sym == "" {
		sym = currency
	}
	if v == math.Trunc(v) {
		return fmt.Sprintf("%s %.0f", sym, v)
	}
	return fmt.Sprintf("%s %.2f", sym, v)
}
