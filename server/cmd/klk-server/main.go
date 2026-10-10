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

	apiServer := api.New(st, otp, hub)
	apiServer.TrustProxy = os.Getenv("KLK_TRUST_PROXY") == "1"
	apiServer.AdminToken = os.Getenv("KLK_ADMIN_TOKEN")
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
