// Servidor de enrutado de KLK.
//
// Variables de entorno:
//
//	KLK_ADDR       dirección de escucha (por defecto :8080)
//	DATABASE_URL   Postgres, p. ej. postgres://klk:klk@localhost:5432/klk
//	               Si está vacía se usa un almacén en memoria (solo desarrollo).
//	KLK_ADMIN_TOKEN  clave del panel del dueño (/admin). Vacía = panel apagado.
//	KLK_SMS_PRICE    precio de cada SMS en euros, para el panel (por defecto 0.08)
//	KLK_SERVER_COST  coste mensual del servidor en euros, para el panel (por defecto 0)
//	KLK_SMS_COUNTRIES   prefijos a los que se mandan SMS ("+1,+34,…"; vacío = RD y diáspora; "*" = todos)
//	Recargas a RD (apagadas si no hay claves):
//	  RELOADLY_CLIENT_ID / RELOADLY_CLIENT_SECRET  claves de Reloadly · RELOADLY_SANDBOX=0 para recargas de verdad
//	  STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET    claves de Stripe (sk_test_… = sin cobrar de verdad)
//	  KLK_TOPUP_DEMO=1   modo prueba sin ninguna cuenta (proveedor y pago de mentira)
//	  KLK_TOPUP_CURRENCY (EUR) · KLK_TOPUP_MARGIN (0.08) · KLK_TOPUP_FEE (0.35) · KLK_TOPUP_MAX (40) · KLK_TOPUP_DAILY_MAX (5)
//	  KLK_PUBLIC_URL     dirección pública del servidor (https://…)
//	KLK_REVIEW_PHONES / KLK_REVIEW_CODE  números de prueba para la revisión de las tiendas (sin SMS)
//	KLK_OWNER_NAME / KLK_SUPPORT_EMAIL  responsable y correo de soporte (/privacidad y /soporte)
//	KLK_SMS_DAILY_MAX   SMS al día en total (500) · KLK_SMS_COUNTRY_MAX por país (200) · KLK_SMS_IP_MAX por conexión (10)
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
	"github.com/klk-app/klk-server/internal/topup"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var st store.Store
	if url := os.Getenv("DATABASE_URL"); url != "" {
		// La base de datos puede tardar en estar lista al arrancar por primera vez:
		// se reintenta durante unos 2 minutos antes de rendirse.
		var pg *store.Postgres
		var err error
		for i := 0; i < 24; i++ {
			pg, err = store.NewPostgres(ctx, url)
			if err == nil {
				if err = pg.Migrate(ctx); err == nil {
					break
				}
				pg.Close()
			}
			slog.Warn("esperando a la base de datos", "intento", i+1, "err", err)
			time.Sleep(5 * time.Second)
		}
		if err != nil {
			slog.Error("base de datos", "err", err)
			os.Exit(1)
		}
		defer pg.Close()
		st = pg
		slog.Info("usando Postgres")
	} else {
		st = store.NewMemory()
		slog.Warn("DATABASE_URL vacía: usando almacén en memoria (los datos se pierden al reiniciar)")
	}

	hub := relay.NewHub(st, relay.NoopPusher{})
	go hub.RunScheduler(ctx, 2*time.Second)
	go purgeAttachments(ctx, st)

	var otp *auth.OTP
	sid := os.Getenv("TWILIO_ACCOUNT_SID")
	switch {
	case sid != "" && os.Getenv("TWILIO_VERIFY_SERVICE_SID") != "":
		otp = auth.NewRemoteOTP(auth.TwilioVerify{
			AccountSID: sid,
			AuthToken:  os.Getenv("TWILIO_AUTH_TOKEN"),
			ServiceSID: os.Getenv("TWILIO_VERIFY_SERVICE_SID"),
			Locale:     os.Getenv("TWILIO_VERIFY_LOCALE"),
		})
		slog.Info("códigos por Twilio Verify")
	case sid != "":
		otp = auth.NewOTP(auth.TwilioSender{AccountSID: sid, AuthToken: os.Getenv("TWILIO_AUTH_TOKEN"), From: os.Getenv("TWILIO_FROM")})
		slog.Info("SMS por Twilio")
	default:
		otp = auth.NewOTP(auth.LogSender{})
		slog.Warn("sin TWILIO_ACCOUNT_SID: los códigos SMS se escriben en el log (solo pruebas)")
	}

	// Números de prueba para la revisión de Apple/Google (sin SMS, código fijo).
	if phones := os.Getenv("KLK_REVIEW_PHONES"); phones != "" {
		var list []string
		for _, p := range strings.Split(phones, ",") {
			list = append(list, strings.TrimSpace(p))
		}
		otp.SetReview(list, strings.TrimSpace(os.Getenv("KLK_REVIEW_CODE")))
		slog.Info("números de revisión activos", "n", len(list))
	}

	apiServer := api.New(st, otp, hub)
	apiServer.TrustProxy = os.Getenv("KLK_TRUST_PROXY") == "1"
	apiServer.AdminToken = os.Getenv("KLK_ADMIN_TOKEN")
	apiServer.SMS = &api.SMSGuard{
		Countries:  smsCountries(os.Getenv("KLK_SMS_COUNTRIES")),
		DailyMax:   envInt("KLK_SMS_DAILY_MAX", 500),
		CountryMax: envInt("KLK_SMS_COUNTRY_MAX", 200),
		PerIPMax:   envInt("KLK_SMS_IP_MAX", 10),
	}
	apiServer.Legal = api.Legal{Owner: os.Getenv("KLK_OWNER_NAME"), SupportEmail: os.Getenv("KLK_SUPPORT_EMAIL")}
	apiServer.Topups = topupConfig()
	if apiServer.Topups != nil {
		go func() {
			t := time.NewTicker(5 * time.Minute)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case now := <-t.C:
					apiServer.SweepTopups(ctx, now)
				}
			}
		}()
	}
	apiServer.SMSPrice = envFloat("KLK_SMS_PRICE", 0.08)
	apiServer.ServerCost = envFloat("KLK_SERVER_COST", 0)
	if apiServer.AdminToken == "" {
		slog.Warn("sin KLK_ADMIN_TOKEN: el panel del dueño (/admin) está desactivado")
	} else if len(apiServer.AdminToken) < 16 {
		slog.Warn("KLK_ADMIN_TOKEN es demasiado corta (mínimo 16 caracteres): panel desactivado")
	}

	// Render, Railway, Fly… indican el puerto en $PORT.
	addr := os.Getenv("KLK_ADDR")
	if addr == "" {
		addr = ":" + envOr("PORT", "8080")
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           apiServer.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	slog.Info("KLK escuchando", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("servidor", "err", err)
		os.Exit(1)
	}
}

// purgeAttachments borra cada hora los adjuntos de más de 30 días.
// Para entonces el destinatario ya los ha descargado y guardado en su móvil.
func purgeAttachments(ctx context.Context, st store.Store) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		if n, err := st.PurgeAttachments(ctx, time.Now().Add(-30*24*time.Hour)); err != nil {
			slog.Error("purga de adjuntos", "err", err)
		} else if n > 0 {
			slog.Info("adjuntos caducados borrados", "n", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func envInt(k string, def int) int {
	if v, err := strconv.Atoi(strings.TrimSpace(os.Getenv(k))); err == nil && v >= 0 {
		return v
	}
	return def
}

// smsCountries lee "+1,+34,+353"; vacío = los países por defecto; "*" = todos.
func smsCountries(v string) []string {
	v = strings.TrimSpace(v)
	if v == "" {
		return api.DefaultSMSCountries
	}
	if v == "*" {
		return nil
	}
	var out []string
	for _, c := range strings.Split(v, ",") {
		if c = strings.TrimSpace(c); c != "" {
			if !strings.HasPrefix(c, "+") {
				c = "+" + c
			}
			out = append(out, c)
		}
	}
	return out
}

func envFloat(k string, def float64) float64 {
	if v, err := strconv.ParseFloat(strings.ReplaceAll(os.Getenv(k), ",", "."), 64); err == nil && v >= 0 {
		return v
	}
	return def
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// topupConfig enciende las recargas si están las claves (o el modo prueba).
func topupConfig() *api.Topups {
	pricing := topup.Pricing{
		Currency: strings.ToUpper(envOr("KLK_TOPUP_CURRENCY", "EUR")),
		Margin:   envFloat("KLK_TOPUP_MARGIN", 0.08),
		Fee:      envFloat("KLK_TOPUP_FEE", 0.35),
		MaxPrice: envFloat("KLK_TOPUP_MAX", 40),
	}
	public := strings.TrimRight(envOr("KLK_PUBLIC_URL", os.Getenv("RENDER_EXTERNAL_URL")), "/")
	t := &api.Topups{Pricing: pricing, PublicURL: public, DailyMax: envInt("KLK_TOPUP_DAILY_MAX", 5)}
	id, secret := os.Getenv("RELOADLY_CLIENT_ID"), os.Getenv("RELOADLY_CLIENT_SECRET")
	sk := os.Getenv("STRIPE_SECRET_KEY")
	switch {
	case id != "" && secret != "" && sk != "":
		sandbox := os.Getenv("RELOADLY_SANDBOX") != "0"
		t.Provider = &topup.Reloadly{ClientID: id, ClientSecret: secret, Test: sandbox}
		t.Payments = &topup.Stripe{SecretKey: sk, WebhookSecret: os.Getenv("STRIPE_WEBHOOK_SECRET")}
		if os.Getenv("STRIPE_WEBHOOK_SECRET") == "" {
			slog.Warn("recargas: falta STRIPE_WEBHOOK_SECRET; los pagos no se confirmarán")
		}
		slog.Info("recargas encendidas", "reloadlyPrueba", sandbox, "stripePrueba", t.Payments.Test())
		return t
	case os.Getenv("KLK_TOPUP_DEMO") == "1":
		if public == "" {
			slog.Warn("recargas: modo prueba sin KLK_PUBLIC_URL; no se pueden abrir los pagos de prueba")
			return nil
		}
		t.Provider = &topup.Fake{}
		t.Payments = &topup.FakePay{BaseURL: public}
		slog.Info("recargas en MODO PRUEBA (no se cobra ni se recarga de verdad)")
		return t
	}
	return nil
}
