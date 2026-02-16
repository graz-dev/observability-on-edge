package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

type Server struct {
	logger            *zap.Logger
	tracer            trace.Tracer
	requestCounter    metric.Int64Counter
	requestDuration   metric.Float64Histogram
	diagnosticsCounter metric.Int64Counter
}

func NewServer(logger *zap.Logger) (*Server, error) {
	tracer := otel.Tracer("vessel-monitor")
	meter := otel.Meter("vessel-monitor")

	// Create metrics
	requestCounter, err := meter.Int64Counter(
		"http.server.request.count",
		metric.WithDescription("Total number of HTTP requests"),
		metric.WithUnit("{request}"),
	)
	if err != nil {
		return nil, err
	}

	requestDuration, err := meter.Float64Histogram(
		"http.server.request.duration",
		metric.WithDescription("HTTP request duration"),
		metric.WithUnit("ms"),
	)
	if err != nil {
		return nil, err
	}

	diagnosticsCounter, err := meter.Int64Counter(
		"vessel.diagnostics.count",
		metric.WithDescription("Total number of diagnostic runs"),
		metric.WithUnit("{diagnostic}"),
	)
	if err != nil {
		return nil, err
	}

	return &Server{
		logger:             logger,
		tracer:             tracer,
		requestCounter:     requestCounter,
		requestDuration:    requestDuration,
		diagnosticsCounter: diagnosticsCounter,
	}, nil
}

// Middleware to add tracing and logging to all requests
func (s *Server) tracingMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		// Extract trace context from incoming request
		ctx = otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(r.Header))

		// Start a new span
		ctx, span := s.tracer.Start(ctx, r.URL.Path,
			trace.WithAttributes(
				attribute.String("http.method", r.Method),
				attribute.String("http.url", r.URL.String()),
				attribute.String("http.route", r.URL.Path),
			),
		)
		defer span.End()

		// Get trace context for logging
		spanCtx := span.SpanContext()
		traceID := spanCtx.TraceID().String()
		spanID := spanCtx.SpanID().String()

		// Add trace context to logger
		logger := s.logger.With(
			zap.String("trace_id", traceID),
			zap.String("span_id", spanID),
			zap.String("method", r.Method),
			zap.String("path", r.URL.Path),
		)

		// Log request
		logger.Info("handling request")

		// Measure request duration
		start := time.Now()

		// Create a response writer wrapper to capture status code
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		// Call the handler with updated context
		next.ServeHTTP(rw, r.WithContext(ctx))

		// Calculate duration
		duration := time.Since(start).Milliseconds()

		// Record metrics
		attrs := []attribute.KeyValue{
			attribute.String("http.method", r.Method),
			attribute.String("http.route", r.URL.Path),
			attribute.Int("http.status_code", rw.statusCode),
		}

		s.requestCounter.Add(ctx, 1, metric.WithAttributes(attrs...))
		s.requestDuration.Record(ctx, float64(duration), metric.WithAttributes(attrs...))

		// Set span status based on HTTP status code
		if rw.statusCode >= 400 {
			span.SetStatus(codes.Error, fmt.Sprintf("HTTP %d", rw.statusCode))
		} else {
			span.SetStatus(codes.Ok, "")
		}
		span.SetAttributes(attribute.Int("http.status_code", rw.statusCode))

		// Log response
		logger.Info("request completed",
			zap.Int("status", rw.statusCode),
			zap.Int64("duration_ms", duration),
		)
	}
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

// Health check endpoint
func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

// Fast endpoint - Engine sensors (~50-80ms)
func (s *Server) engineHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_, span := s.tracer.Start(ctx, "read-engine-sensors")
	defer span.End()

	// Simulate fast sensor read
	time.Sleep(time.Duration(50+rand.Intn(30)) * time.Millisecond)

	// Generate realistic engine data
	engineData := map[string]interface{}{
		"rpm":             1800 + rand.Intn(400),      // 1800-2200 RPM
		"temperature_c":   75 + rand.Intn(15),         // 75-90°C
		"oil_pressure_psi": 45 + rand.Intn(10),        // 45-55 PSI
		"fuel_rate_lph":   12.5 + rand.Float64()*2.5, // 12.5-15 L/h
		"coolant_temp_c":  70 + rand.Intn(10),         // 70-80°C
		"battery_volts":   13.8 + rand.Float64()*0.4, // 13.8-14.2V
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sensor_type": "engine",
		"timestamp":   time.Now().Unix(),
		"data":        engineData,
		"status":      "normal",
	})
}

// Fast endpoint - Navigation sensors (~40-60ms)
func (s *Server) navigationHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_, span := s.tracer.Start(ctx, "read-navigation-sensors")
	defer span.End()

	// Simulate fast GPS/nav sensor read
	time.Sleep(time.Duration(40+rand.Intn(20)) * time.Millisecond)

	// Generate realistic navigation data
	navData := map[string]interface{}{
		"latitude":     41.9028 + rand.Float64()*0.01,   // Mediterranean Sea
		"longitude":    12.4964 + rand.Float64()*0.01,   // Near Italian coast
		"speed_knots":  8.5 + rand.Float64()*3.5,        // 8.5-12 knots
		"heading":      180 + rand.Intn(20),              // ~180° (southbound)
		"depth_meters": 45 + rand.Intn(25),               // 45-70m depth
		"wind_speed_kt": 12 + rand.Intn(8),               // 12-20 knots
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sensor_type": "navigation",
		"timestamp":   time.Now().Unix(),
		"data":        navData,
		"status":      "normal",
	})
}

// Slow endpoint - Complex diagnostics (~300-600ms, some >1s)
func (s *Server) diagnosticsHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_, span := s.tracer.Start(ctx, "run-engine-diagnostics")
	defer span.End()

	// Simulate complex diagnostic analysis - occasionally very slow
	latency := 300 + rand.Intn(300)
	if rand.Float32() < 0.15 { // 15% chance of very slow diagnostics
		latency = 1000 + rand.Intn(500)
		span.SetAttributes(attribute.Bool("complex_analysis", true))
		s.logger.Warn("complex diagnostic analysis detected",
			zap.Int("latency_ms", latency),
			zap.String("trace_id", span.SpanContext().TraceID().String()),
		)
	}

	time.Sleep(time.Duration(latency) * time.Millisecond)

	// Record diagnostic run
	s.diagnosticsCounter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("result", "completed"),
	))

	// Generate diagnostic results
	diagnostics := map[string]interface{}{
		"engine_health":       85 + rand.Intn(10),        // 85-95% health score
		"fuel_efficiency":     92 + rand.Intn(6),         // 92-98% efficiency
		"vibration_level":     0.2 + rand.Float64()*0.15, // 0.2-0.35 mm/s
		"exhaust_temp_c":      350 + rand.Intn(50),       // 350-400°C
		"next_maintenance_hours": 150 + rand.Intn(50),    // 150-200 hours
		"warnings": []string{},
	}

	// Occasionally add warnings
	if rand.Float32() < 0.2 {
		diagnostics["warnings"] = []string{"Minor oil pressure fluctuation detected"}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"diagnostic_type": "full_system",
		"timestamp":       time.Now().Unix(),
		"analysis_time_ms": latency,
		"results":         diagnostics,
		"status":          "completed",
	})
}

// Error-prone endpoint - System alerts (20% failure rate)
func (s *Server) alertsHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_, span := s.tracer.Start(ctx, "report-system-alert")
	defer span.End()

	// Simulate processing time
	time.Sleep(time.Duration(80+rand.Intn(80)) * time.Millisecond)

	// 20% chance of sensor/communication failure
	if rand.Float32() < 0.20 {
		errorMsg := "sensor communication failure"
		span.SetStatus(codes.Error, errorMsg)
		span.SetAttributes(attribute.String("error.type", "sensor_failure"))

		s.logger.Error("alert system failed",
			zap.String("error", errorMsg),
			zap.String("trace_id", span.SpanContext().TraceID().String()),
		)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{
			"error":    errorMsg,
			"trace_id": span.SpanContext().TraceID().String(),
			"details":  "Failed to read bilge pump sensor data",
		})
		return
	}

	// Success case - normal alert reporting
	alertType := []string{"info", "warning", "normal"}[rand.Intn(3)]

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"alert_id":   rand.Intn(10000),
		"type":       alertType,
		"message":    "All systems operational",
		"timestamp":  time.Now().Unix(),
		"sensor_status": "online",
	})
}
