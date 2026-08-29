package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"example.com/demo-github-capacity-cascade/internal/server"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	err := server.Run(ctx, server.Config{
		PublicAddr: os.Getenv("LAB_PUBLIC_ADDR"),
		AdminAddr:  os.Getenv("LAB_ADMIN_ADDR"),
		AdminToken: os.Getenv("LAB_ADMIN_TOKEN"),
		Logger:     logger,
	})
	if err != nil {
		logger.Error("auth-sim failed", "error", err)
		os.Exit(1)
	}
}
