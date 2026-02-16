package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// InitTelemetry initializes OpenTelemetry tracing and metrics
func InitTelemetry(ctx context.Context) (*sdktrace.TracerProvider, *sdkmetric.MeterProvider, error) {
	// Get OTLP endpoint from environment or use default
	otlpEndpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if otlpEndpoint == "" {
		otlpEndpoint = "otel-collector.observability.svc.cluster.local:4317"
	}

	// Create resource with service information
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("edge-demo-app"),
			semconv.ServiceVersion("1.0.0"),
			semconv.DeploymentEnvironment("edge"),
		),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// Set up trace exporter
	traceExporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(otlpEndpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	// Set up trace provider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	// Set up propagators for distributed tracing
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// Set up metrics exporter
	metricExporter, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint(otlpEndpoint),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	// Set up meter provider
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter,
			sdkmetric.WithInterval(10*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	return tp, mp, nil
}

// InitLogger initializes a structured JSON logger with trace context
func InitLogger() (*zap.Logger, error) {
	config := zap.NewProductionConfig()
	config.EncoderConfig.TimeKey = "timestamp"
	config.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	config.OutputPaths = []string{"stdout", "/var/log/app/app.log"}
	config.ErrorOutputPaths = []string{"stderr"}

	logger, err := config.Build()
	if err != nil {
		return nil, fmt.Errorf("failed to create logger: %w", err)
	}

	return logger, nil
}
