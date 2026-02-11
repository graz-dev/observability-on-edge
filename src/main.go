package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
)

func initTracer() (*sdktrace.TracerProvider, error) {
	ctx := context.Background()

	// The OTel Collector is running as a DaemonSet on the same node.
	// In K8s, we can reach the node IP via status.hostIP field passed as env var,
	// or if using hostNetwork: true in DaemonSet, we can try generic DNS if set up.
	// For simplicity with the DaemonSet + Sidecar pattern or HostPort:
	// We will assume the collector is listening on the Node IP.
	collectorAddr := os.Getenv("COLLECTOR_ENDPOINT")
	if collectorAddr == "" {
		collectorAddr = "localhost:4317" // Default fallback
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("noise-generator"),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))

	return tp, nil
}

func noiseHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tracer := otel.Tracer("noise-generator")
	ctx, span := tracer.Start(ctx, "handle-request")
	defer span.End()

	scenario := rand.Float64()

	// 10% High Latency
	if scenario < 0.10 {
		span.SetAttributes(attribute.String("scenario", "high_latency"))
		time.Sleep(1200 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("High Latency Response"))
		log.Printf("[REQUEST] scenario=high_latency status=200")
		return
	}

	// 10% Error
	if scenario < 0.20 {
		span.SetAttributes(attribute.String("scenario", "error"))
		span.RecordError(fmt.Errorf("simulated internal error"))
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Internal Server Error"))
		log.Printf("[REQUEST] scenario=error status=500")
		return
	}

	// 80% Success
	span.SetAttributes(attribute.String("scenario", "success"))
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Success Response"))
	log.Printf("[REQUEST] scenario=success status=200")
}

func main() {
	tp, err := initTracer()
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		if err := tp.Shutdown(context.Background()); err != nil {
			log.Fatal(err)
		}
	}()

	otelHandler := otelhttp.NewHandler(http.HandlerFunc(noiseHandler), "http-server")

	http.Handle("/", otelHandler)

	port := "8080"
	fmt.Printf("Noise Generator running on port %s\n", port)

	// Start a background goroutine to generate self-traffic if needed,
	// or we can rely on an external load generator.
	// The prompt says "Noise Generator that produces constant traffic".
	// So distinct from the server, it should also generate noise?
	// "Un microservizio... che produce traffico costante".
	// It implies the service itself generates traffic OR receives it?
	// "Noise Generator... produce traffico". Usually implies it generates requests.
	// Let's add a self-pinger goroutine.

	go func() {
		client := http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
		ticker := time.NewTicker(100 * time.Millisecond) // 10 RPS
		tracer := otel.Tracer("noise-generator")
		for range ticker.C {
			ctx, span := tracer.Start(context.Background(), "self-ping")
			req, _ := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("http://localhost:%s/", port), nil)
			resp, err := client.Do(req)
			if err == nil {
				resp.Body.Close()
			}
			span.End()
		}
	}()

	log.Fatal(http.ListenAndServe(":"+port, nil))
}
