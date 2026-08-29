package server

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

func TestRunGracefulShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	err := Run(ctx, Config{
		PublicAddr:      "127.0.0.1:0",
		AdminAddr:       "127.0.0.1:0",
		Logger:          slog.New(slog.NewJSONHandler(io.Discard, nil)),
		ShutdownTimeout: time.Second,
	})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("shutdown took %v", elapsed)
	}
}
