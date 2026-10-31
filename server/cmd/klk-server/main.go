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
//	KLK_APNS_KEY / KLK_APNS_KEY_ID / KLK_APNS_TEAM_ID  avisos a iPhone (clave .p8 de Apple)
//	KLK_FCM_CREDENTIALS  avisos a Android (el .json de «Cuentas de servicio» de Firebase)
//	KLK_PLAY_CREDENTIALS cobros de Plus en Android (cuenta de servicio invitada en Play Console;
//	                     si falta se usa KLK_FCM_CREDENTIALS). KLK_PLAY_PACKAGE = com.klkapp.klk
//	KLK_FOUNDERS_MAX / KLK_FOUNDERS_DAYS  oferta «Fundadores»: Plus gratis (365 días) a las primeras N cuentas
//	KLK_RESEND_KEY / KLK_MAIL_FROM  entrar con correo (códigos por correo con resend.com)
//	KLK_REVIEW_PHONES / KLK_REVIEW_CODE  números de prueba para la revisión de las tiendas (sin SMS)
//	KLK_S3_ENDPOINT / KLK_S3_BUCKET / KLK_S3_ACCESS_KEY / KLK_S3_SECRET_KEY  adjuntos en Cloudflare R2
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
	"github.com/klk-app/klk-server/internal/appstore"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/blob"
	"github.com/klk-app/klk-server/internal/playstore"
	"github.com/klk-app/klk-server/internal/push"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
	"github.com/klk-app/klk-server/internal/topup"
	"github.com/klk-app/klk-server/internal/turn"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var st store.Store
	var health []api.ServiceCheck
	check := func(name string, ok bool, detail string) {
		health = append(health, api.ServiceCheck{Name: name, OK: ok, Detail: detail})
	}
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

	// Adjuntos en Cloudflare R2 (o cualquier S3) si están las claves.
	if ep := os.Getenv("KLK_S3_ENDPOINT"); ep != "" && os.Getenv("KLK_S3_ACCESS_KEY") != "" {
		st = &blob.Store{Store: st, S3: &blob.S3{
			Endpoint:  ep,
			Bucket:    envOr("KLK_S3_BUCKET", "klk-adjuntos"),
			AccessKey: os.Getenv("KLK_S3_ACCESS_KEY"),
			SecretKey: os.Getenv("KLK_S3_SECRET_KEY"),
			Region:    os.Getenv("KLK_S3_REGION"),
		}}
		slog.Info("adjuntos en almacenamiento S3/R2")
		check("Fotos y adjuntos (Cloudflare R2)", true, "activado")
	} else {
		check("Fotos y adjuntos (Cloudflare R2)", false, "sin KLK_S3_ENDPOINT: se guardan en la base de datos")
	}

	var pusher relay.Pusher = relay.NoopPusher{}
	if key := os.Getenv("KLK_APNS_KEY"); key != "" {
		a, err := push.NewAPNs(push.Config{
			KeyPEM:  key,
			KeyID:   strings.TrimSpace(os.Getenv("KLK_APNS_KEY_ID")),
			TeamID:  strings.TrimSpace(os.Getenv("KLK_APNS_TEAM_ID")),
			Topic:   envOr("KLK_APNS_TOPIC", "com.klkapp.klk"),
			Sandbox: os.Getenv("KLK_APNS_SANDBOX") == "1",
		}, st)
		if err != nil {
			slog.Error("avisos push de iPhone desactivados", "err", err)
			check("Notificaciones iPhone (Apple)", false, "la clave KLK_APNS_KEY no vale: "+err.Error())
		} else {
			pusher = a
			slog.Info("avisos push de iPhone (APNs) activados")
			check("Notificaciones iPhone (Apple)", true, "activadas")
		}
	} else {
		check("Notificaciones iPhone (Apple)", false, "falta KLK_APNS_KEY")
	}
	// Android: Firebase Cloud Messaging con la cuenta de servicio (.json de Firebase).
	if cred := os.Getenv("KLK_FCM_CREDENTIALS"); cred != "" {
		f, err := push.NewFCM(cred, st)
		if err != nil {
			slog.Error("avisos push de Android desactivados", "err", err)
			check("Notificaciones Android (Firebase)", false, "la clave KLK_FCM_CREDENTIALS no vale: "+err.Error())
		} else {
			if _, noop := pusher.(relay.NoopPusher); noop {
				pusher = f
			} else {
				pusher = push.Multi{pusher, f}
			}
			slog.Info("avisos push de Android (FCM) activados", "proyecto", f.ProjectID())
			check("Notificaciones Android (Firebase)", true, "activadas · proyecto "+f.ProjectID())
		}
	} else {
		check("Notificaciones Android (Firebase)", false, "falta KLK_FCM_CREDENTIALS")
	}
	hub := relay.NewHub(st, pusher)
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
		check("SMS (Twilio)", true, "códigos por Twilio Verify")
	case sid != "":
		otp = auth.NewOTP(auth.TwilioSender{AccountSID: sid, AuthToken: os.Getenv("TWILIO_AUTH_TOKEN"), From: os.Getenv("TWILIO_FROM")})
		slog.Info("SMS por Twilio")
		check("SMS (Twilio)", true, "SMS por Twilio")
	default:
		otp = auth.NewOTP(auth.LogSender{})
		slog.Warn("sin TWILIO_ACCOUNT_SID: los códigos SMS se escriben en el log (solo pruebas)")
		check("SMS (Twilio)", false, "sin TWILIO_ACCOUNT_SID: no se mandan SMS")
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
	// Entrar con correo (código por correo con Resend). Sin clave, la opción no sale en la app.
	if key := os.Getenv("KLK_RESEND_KEY"); key != "" {
		apiServer.Mail = auth.NewMailOTP(auth.Resend{Key: key, From: envOr("KLK_MAIL_FROM", "KLK messenger <onboarding@resend.dev>")})
		slog.Info("entrar con correo: activado (Resend)")
		check("Correo (Resend)", true, "activado")
	} else if os.Getenv("KLK_MAIL_LOG") == "1" {
		apiServer.Mail = auth.NewMailOTP(auth.LogMail{})
		slog.Warn("entrar con correo: los códigos se escriben en el log (solo pruebas)")
		check("Correo (Resend)", false, "modo prueba: los códigos van al log")
	} else {
		check("Correo (Resend)", false, "falta KLK_RESEND_KEY")
	}
	apiServer.TrustProxy = os.Getenv("KLK_TRUST_PROXY") == "1"
	// Puente para llamadas (TURN). Cloudflare si está configurado; si no, Twilio
	// (la misma cuenta de los SMS). Ponlo a "off" con KLK_TURN=off.
	switch {
	case os.Getenv("KLK_TURN") == "off":
	case os.Getenv("KLK_CF_TURN_KEY_ID") != "" && os.Getenv("KLK_CF_TURN_TOKEN") != "":
		apiServer.TURN = &turn.Cache{P: turn.Cloudflare{
			KeyID: strings.TrimSpace(os.Getenv("KLK_CF_TURN_KEY_ID")),
			Token: strings.TrimSpace(os.Getenv("KLK_CF_TURN_TOKEN")),
		}}
		slog.Info("llamadas: TURN de Cloudflare")
		check("Llamadas (TURN)", true, "Cloudflare")
	case sid != "" && os.Getenv("TWILIO_AUTH_TOKEN") != "":
		apiServer.TURN = &turn.Cache{P: turn.Twilio{AccountSID: sid, AuthToken: os.Getenv("TWILIO_AUTH_TOKEN")}}
		slog.Info("llamadas: TURN de Twilio")
		check("Llamadas (TURN)", true, "Twilio")
	default:
		check("Llamadas (TURN)", false, "sin puente: algunas llamadas pueden fallar")
	}
	apiServer.AdminToken = os.Getenv("KLK_ADMIN_TOKEN")
	apiServer.SMS = &api.SMSGuard{
		Countries:  smsCountries(os.Getenv("KLK_SMS_COUNTRIES")),
		DailyMax:   envInt("KLK_SMS_DAILY_MAX", 500),
		CountryMax: envInt("KLK_SMS_COUNTRY_MAX", 200),
		PerIPMax:   envInt("KLK_SMS_IP_MAX", 10),
	}
	apiServer.PlusCodes = api.ParsePlusCodes(os.Getenv("KLK_PLUS_CODES"))
	apiServer.FoundersMax = envInt("KLK_FOUNDERS_MAX", 0)
	apiServer.FoundersDays = envInt("KLK_FOUNDERS_DAYS", 365)
	apiServer.Apple = appstore.NewApple()
	apiServer.AppleBundleID = "com.klkapp.klk"
	if v := os.Getenv("KLK_APPLE_BUNDLE_ID"); v != "" {
		apiServer.AppleBundleID = v
	}
	// Android: las compras de Plus con Google Play se comprueban con la API de Google.
	playCred := os.Getenv("KLK_PLAY_CREDENTIALS")
	if playCred == "" {
		playCred = os.Getenv("KLK_FCM_CREDENTIALS")
	}
	if playCred != "" {
		v, err := playstore.New(playCred, envOr("KLK_PLAY_PACKAGE", "com.klkapp.klk"))
		if err != nil {
			check("Cobros Plus Android (Google Play)", false, "la clave no vale: "+err.Error())
		} else {
			apiServer.Play = v
			check("Cobros Plus Android (Google Play)", true, "listo · invita a "+v.Email()+" en Play Console")
		}
	} else {
		check("Cobros Plus Android (Google Play)", false, "falta KLK_PLAY_CREDENTIALS")
	}
	apiServer.Health = health
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
		// Mi Gente: fotos subidas que nunca se llegaron a publicar.
		if n, err := st.PurgeGenteImages(ctx, time.Now().Add(-24*time.Hour)); err != nil {
			slog.Warn("purga de fotos de Mi Gente", "err", err)
		} else if n > 0 {
			slog.Info("fotos de Mi Gente sin publicar borradas", "n", n)
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
