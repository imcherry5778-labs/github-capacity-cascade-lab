package server

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"time"
)

const (
	defaultPublicAddr    = "127.0.0.1:8080"
	defaultAdminAddr     = "127.0.0.1:9090"
	defaultShutdownDelay = 5 * time.Second
)

type Config struct {
	PublicAddr      string
	AdminAddr       string
	AdminToken      string
	Logger          *slog.Logger
	ShutdownTimeout time.Duration
}

func Run(ctx context.Context, config Config) error {
	config = withDefaults(config)
	app := NewApplication(config.AdminToken)
	publicListener, err := net.Listen("tcp", config.PublicAddr)
	if err != nil {
		return err
	}
	adminListener, err := net.Listen("tcp", config.AdminAddr)
	if err != nil {
		_ = publicListener.Close()
		return err
	}

	publicServer := newHTTPServer(app.PublicHandler())
	adminServer := newHTTPServer(app.AdminHandler())
	errCh := make(chan error, 2)

	config.Logger.Info("auth-sim starting",
		"public_addr", publicListener.Addr().String(),
		"admin_addr", adminListener.Addr().String(),
	)
	go serve(publicServer, publicListener, errCh)
	go serve(adminServer, adminListener, errCh)

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-errCh:
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), config.ShutdownTimeout)
	defer cancel()
	shutdownErr := errors.Join(
		publicServer.Shutdown(shutdownCtx),
		adminServer.Shutdown(shutdownCtx),
	)
	config.Logger.Info("auth-sim stopped")
	return errors.Join(runErr, shutdownErr)
}

func withDefaults(config Config) Config {
	if config.PublicAddr == "" {
		config.PublicAddr = defaultPublicAddr
	}
	if config.AdminAddr == "" {
		config.AdminAddr = defaultAdminAddr
	}
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	if config.ShutdownTimeout <= 0 {
		config.ShutdownTimeout = defaultShutdownDelay
	}
	return config
}

func newHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
}

func serve(server *http.Server, listener net.Listener, errCh chan<- error) {
	err := server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	errCh <- err
}
