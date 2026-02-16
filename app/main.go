package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.uber.org/zap"
)

func main() {
	ctx := context.Background()

	// Initialize logger
	logger, err := InitLogger()
	if err != nil {
		panic(err)
	}
	defer logger.Sync()

	logger.Info("starting maritime vessel monitoring system")

	// Ensure log directory exists
	if err := os.MkdirAll("/var/log/app", 0755); err != nil {
		logger.Error("failed to create log directory", zap.Error(err))
	}

	// Initialize OpenTelemetry
	tp, mp, err := InitTelemetry(ctx)
	if err != nil {
		logger.Fatal("failed to initialize telemetry", zap.Error(err))
	}
	defer func() {
		if err := tp.Shutdown(ctx); err != nil {
			logger.Error("failed to shutdown tracer provider", zap.Error(err))
		}
		if err := mp.Shutdown(ctx); err != nil {
			logger.Error("failed to shutdown meter provider", zap.Error(err))
		}
	}()

	logger.Info("telemetry initialized successfully")

	// Create server
	server, err := NewServer(logger)
	if err != nil {
		logger.Fatal("failed to create server", zap.Error(err))
	}

	// Register maritime monitoring endpoints
	http.HandleFunc("/health", server.tracingMiddleware(server.healthHandler))
	http.HandleFunc("/api/sensors/engine", server.tracingMiddleware(server.engineHandler))
	http.HandleFunc("/api/sensors/navigation", server.tracingMiddleware(server.navigationHandler))
	http.HandleFunc("/api/analytics/diagnostics", server.tracingMiddleware(server.diagnosticsHandler))
	http.HandleFunc("/api/alerts/system", server.tracingMiddleware(server.alertsHandler))

	// Create HTTP server
	httpServer := &http.Server{
		Addr:         ":8080",
		Handler:      http.DefaultServeMux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in a goroutine
	go func() {
		logger.Info("starting HTTP server", zap.String("addr", httpServer.Addr))
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("failed to start server", zap.Error(err))
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("shutting down vessel monitoring system")

	// Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		logger.Error("server forced to shutdown", zap.Error(err))
	}

	logger.Info("server exited")
}
