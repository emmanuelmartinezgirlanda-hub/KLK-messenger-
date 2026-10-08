// Servidor de enrutado de KLK.
//
// Variables de entorno:
//
//	KLK_ADDR       dirección de escucha (por defecto :8080)
//	DATABASE_URL   Postgres, p. ej. postgres://klk:klk@localhost:5432/klk
//	               Si está vacía se usa un almacén en memoria (solo desarrollo).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
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
		pg, err := store.NewPostgres(ctx, url)
		if err != nil {
			slog.Error("base de datos", "err", err)
			os.Exit(1)
		}
		defer pg.Close()
		if err := pg.Migrate(ctx); err != nil {
			slog.Error("migraciones", "err", err)
			os.Exit(1)
		}
		st = pg
		slog.Info("usando Postgres")
	} else {
		st = store.NewMemory()
		slog.Warn("DATABASE_URL vacía: usando almacén en memoria (los datos se pierden al reiniciar)")
	}

	hub := relay.NewHub(st, relay.NoopPusher{})
	go hub.RunScheduler(ctx, 2*time.Second)
	go purgeAttachments(ctx, st)

	var sms auth.SMSSender = auth.LogSender{}
	if sid := os.Getenv("TWILIO_ACCOUNT_SID"); sid != "" {
		sms = auth.TwilioSender{AccountSID: sid, AuthToken: os.Getenv("TWILIO_AUTH_TOKEN"), From: os.Getenv("TWILIO_FROM")}
		slog.Info("SMS por Twilio")
	} else {
		slog.Warn("sin TWILIO_ACCOUNT_SID: los códigos SMS se escriben en el log (solo pruebas)")
	}

	apiServer := api.New(st, auth.NewOTP(sms), hub)
	apiServer.TrustProxy = os.Getenv("KLK_TRUST_PROXY") == "1"

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

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
