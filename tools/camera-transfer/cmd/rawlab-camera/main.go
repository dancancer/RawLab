package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/app"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := (&app.Runner{Out: os.Stdout, Err: os.Stderr}).Run(ctx, os.Args[1:])
	stop()
	os.Exit(code)
}
