package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/imcherry5778-labs/github-capacity-cascade-lab/internal/server"
)

func main() {
	// JSON 로그는 local runner가 app.log로 저장한다. Admin token은 로그에 포함하지 않는다.
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	// SIGINT와 SIGTERM을 context 취소로 변환해 public/admin server가 함께 안전하게 종료되게 한다.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 주소와 credential은 파일에 저장하지 않고 LAB_* 환경 변수로만 전달한다.
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
