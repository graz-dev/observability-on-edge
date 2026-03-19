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
	logger             *zap.Logger
	tracer             trace.Tracer
	requestCounter     metric.Int64Counter
	requestDuration    metric.Float64Histogram
	diagnosticsCounter metric.Int64Counter
}

func NewServer(logger *zap.Logger) (*Server, error) {
	tracer := otel.Tracer("vessel-monitor")
	meter := otel.Meter("vessel-monitor")

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

func (s *Server) tracingMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		ctx = otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(r.Header))

		ctx, span := s.tracer.Start(ctx, r.URL.Path,
			trace.WithAttributes(
				attribute.String("http.method", r.Method),
				attribute.String("http.url", r.URL.String()),
				attribute.String("http.route", r.URL.Path),
			),
		)
		defer span.End()

		spanCtx := span.SpanContext()
		logger := s.logger.With(
			zap.String("trace_id", spanCtx.TraceID().String()),
			zap.String("span_id", spanCtx.SpanID().String()),
			zap.String("method", r.Method),
			zap.String("path", r.URL.Path),
		)
		logger.Info("handling request")

		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(rw, r.WithContext(ctx))
		duration := time.Since(start).Milliseconds()

		attrs := []attribute.KeyValue{
			attribute.String("http.method", r.Method),
			attribute.String("http.route", r.URL.Path),
			attribute.Int("http.status_code", rw.statusCode),
		}
		s.requestCounter.Add(ctx, 1, metric.WithAttributes(attrs...))
		s.requestDuration.Record(ctx, float64(duration), metric.WithAttributes(attrs...))

		if rw.statusCode >= 400 {
			span.SetStatus(codes.Error, fmt.Sprintf("HTTP %d", rw.statusCode))
		} else {
			span.SetStatus(codes.Ok, "")
		}
		span.SetAttributes(attribute.Int("http.status_code", rw.statusCode))

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

func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

// engineHandler — fast endpoint (~70-110ms total, 4 child spans).
// Pipeline: acquire raw CAN bus readings → validate schema → normalise units → enrich metadata.
// Simulates a realistic sensor acquisition chain on an edge vessel controller.
func (s *Server) engineHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Span 1: raw CAN bus acquisition — dominant latency
	ctx, acqSpan := s.tracer.Start(ctx, "acquire-sensor-data",
		trace.WithAttributes(
			attribute.String("sensor.bus", "CAN-0"),
			attribute.Int("sensor.channel", rand.Intn(8)),
			attribute.Int("sensor.count", 6),
			attribute.Float64("sensor.bus_utilization", 0.3+rand.Float64()*0.5),
			attribute.String("firmware.version", "3.2.1"),
		),
	)
	time.Sleep(time.Duration(30+rand.Intn(25)) * time.Millisecond)
	acqSpan.End()

	// Span 2: schema/range validation
	ctx, valSpan := s.tracer.Start(ctx, "validate-readings",
		trace.WithAttributes(
			attribute.String("schema.version", "engine-v2"),
			attribute.Int("fields.checked", 6),
			attribute.Bool("schema.strict", true),
		),
	)
	time.Sleep(time.Duration(8+rand.Intn(10)) * time.Millisecond)
	if rand.Float32() < 0.05 {
		valSpan.AddEvent("out-of-range-warning",
			trace.WithAttributes(attribute.String("field", "oil_pressure_psi")),
		)
	}
	valSpan.End()

	// Span 3: unit normalisation (imperial → SI)
	ctx, normSpan := s.tracer.Start(ctx, "normalise-units",
		trace.WithAttributes(
			attribute.String("conversion.standard", "SI"),
			attribute.Int("fields.converted", 3),
		),
	)
	time.Sleep(time.Duration(5+rand.Intn(8)) * time.Millisecond)
	normSpan.End()

	// Span 4: metadata enrichment (vessel ID, position tag)
	_, enrichSpan := s.tracer.Start(ctx, "enrich-metadata",
		trace.WithAttributes(
			attribute.String("vessel.id", "IMO-9234567"),
			attribute.String("vessel.flag", "IT"),
			attribute.Float64("position.lat", 41.9028+rand.Float64()*0.01),
			attribute.Float64("position.lon", 12.4964+rand.Float64()*0.01),
		),
	)
	time.Sleep(time.Duration(3+rand.Intn(5)) * time.Millisecond)
	enrichSpan.End()

	engineData := map[string]interface{}{
		"rpm":              1800 + rand.Intn(400),
		"temperature_c":    75 + rand.Intn(15),
		"oil_pressure_psi": 45 + rand.Intn(10),
		"fuel_rate_lph":    12.5 + rand.Float64()*2.5,
		"coolant_temp_c":   70 + rand.Intn(10),
		"battery_volts":    13.8 + rand.Float64()*0.4,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sensor_type": "engine",
		"timestamp":   time.Now().Unix(),
		"data":        engineData,
		"status":      "normal",
	})
}

// navigationHandler — fast endpoint (~55-90ms total, 4 child spans).
// Pipeline: GPS fix acquisition → course vector computation → geofence check → chart overlay.
func (s *Server) navigationHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Span 1: GPS fix (NMEA parse + satellite lock)
	ctx, gpsSpan := s.tracer.Start(ctx, "read-gps-fix",
		trace.WithAttributes(
			attribute.Int("gps.satellites", 8+rand.Intn(4)),
			attribute.Float64("gps.hdop", 0.8+rand.Float64()*0.6),
			attribute.String("gps.protocol", "NMEA-0183"),
			attribute.String("gps.fix_type", "3D"),
		),
	)
	time.Sleep(time.Duration(20+rand.Intn(20)) * time.Millisecond)
	gpsSpan.End()

	// Span 2: course vector (heading + speed from last two fixes)
	ctx, courseSpan := s.tracer.Start(ctx, "compute-course-vector",
		trace.WithAttributes(
			attribute.String("algorithm", "great-circle"),
			attribute.Float64("cog", float64(180+rand.Intn(20))),
			attribute.Float64("sog_knots", 8.5+rand.Float64()*3.5),
		),
	)
	time.Sleep(time.Duration(10+rand.Intn(15)) * time.Millisecond)
	courseSpan.End()

	// Span 3: geofence compliance (shipping lane check)
	ctx, geoSpan := s.tracer.Start(ctx, "check-geofence",
		trace.WithAttributes(
			attribute.String("zone.id", "MED-LANE-7"),
			attribute.String("zone.type", "traffic_separation_scheme"),
			attribute.Bool("zone.compliant", true),
		),
	)
	time.Sleep(time.Duration(5+rand.Intn(10)) * time.Millisecond)
	geoSpan.End()

	// Span 4: chart overlay (depth contour lookup)
	_, chartSpan := s.tracer.Start(ctx, "lookup-chart-overlay",
		trace.WithAttributes(
			attribute.String("chart.id", "INT-3301"),
			attribute.String("chart.edition", "2024-Q3"),
			attribute.Float64("depth.meters", float64(45+rand.Intn(25))),
		),
	)
	time.Sleep(time.Duration(4+rand.Intn(8)) * time.Millisecond)
	chartSpan.End()

	navData := map[string]interface{}{
		"latitude":      41.9028 + rand.Float64()*0.01,
		"longitude":     12.4964 + rand.Float64()*0.01,
		"speed_knots":   8.5 + rand.Float64()*3.5,
		"heading":       180 + rand.Intn(20),
		"depth_meters":  45 + rand.Intn(25),
		"wind_speed_kt": 12 + rand.Intn(8),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sensor_type": "navigation",
		"timestamp":   time.Now().Unix(),
		"data":        navData,
		"status":      "normal",
	})
}

// diagnosticsHandler — slow endpoint (~350-700ms steady, up to 1500ms on complex path, 6 child spans).
// Pipeline: sensor snapshot → vibration FFT → engine diagnostics → anomaly evaluation →
//
//	maintenance check → report generation.
//
// Rich span tree is the primary driver of tail-sampling memory at high load.
func (s *Server) diagnosticsHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Span 1: collect a full sensor snapshot before analysis
	ctx, snapSpan := s.tracer.Start(ctx, "collect-sensor-snapshot",
		trace.WithAttributes(
			attribute.Int("sensors.polled", 24),
			attribute.String("snapshot.format", "protobuf-v2"),
			attribute.Float64("data.size_kb", 12.4+rand.Float64()*5),
		),
	)
	time.Sleep(time.Duration(40+rand.Intn(40)) * time.Millisecond)
	snapSpan.End()

	// Span 2: vibration FFT analysis
	ctx, vibSpan := s.tracer.Start(ctx, "analyze-vibration-patterns",
		trace.WithAttributes(
			attribute.String("algorithm", "FFT-Hann"),
			attribute.Int("fft.samples", 1024),
			attribute.Float64("vibration.rms", 0.2+rand.Float64()*0.15),
			attribute.String("frequency.dominant_hz", fmt.Sprintf("%.1f", 12.5+rand.Float64()*5)),
		),
	)
	time.Sleep(time.Duration(60+rand.Intn(80)) * time.Millisecond)
	vibSpan.End()

	// Span 3: engine diagnostics (existing heavy computation — complex path at 15%)
	isComplex := rand.Float32() < 0.15
	ctx, diagSpan := s.tracer.Start(ctx, "run-engine-diagnostics",
		trace.WithAttributes(
			attribute.Bool("complex_analysis", isComplex),
			attribute.Int("cylinders.checked", 6),
			attribute.String("diagnostic.model", "MTU-12V-4000"),
		),
	)
	engineLatency := 120 + rand.Intn(180)
	if isComplex {
		engineLatency = 600 + rand.Intn(400)
		diagSpan.AddEvent("deep-scan-triggered",
			trace.WithAttributes(attribute.String("reason", "vibration-anomaly")),
		)
		s.logger.Warn("complex diagnostic analysis detected",
			zap.Int("latency_ms", engineLatency),
			zap.String("trace_id", diagSpan.SpanContext().TraceID().String()),
		)
	}
	time.Sleep(time.Duration(engineLatency) * time.Millisecond)
	diagSpan.End()

	// Span 4: anomaly evaluation against historical baseline
	ctx, anomSpan := s.tracer.Start(ctx, "evaluate-anomalies",
		trace.WithAttributes(
			attribute.Int("baseline.samples", 720),
			attribute.Float64("anomaly.score", rand.Float64()*0.3),
			attribute.String("model.version", "isolation-forest-v3"),
		),
	)
	time.Sleep(time.Duration(30+rand.Intn(40)) * time.Millisecond)
	anomSpan.End()

	// Span 5: maintenance schedule check
	ctx, maintSpan := s.tracer.Start(ctx, "check-maintenance-schedule",
		trace.WithAttributes(
			attribute.Int("hours.since_last_service", 120+rand.Intn(200)),
			attribute.Int("hours.until_next_service", 150+rand.Intn(50)),
			attribute.String("service.interval", "500h"),
		),
	)
	time.Sleep(time.Duration(20+rand.Intn(30)) * time.Millisecond)
	maintSpan.End()

	// Span 6: report generation
	_, reportSpan := s.tracer.Start(ctx, "generate-diagnostic-report",
		trace.WithAttributes(
			attribute.String("report.format", "JSON-v2"),
			attribute.Int("report.sections", 5),
		),
	)
	time.Sleep(time.Duration(5+rand.Intn(10)) * time.Millisecond)
	reportSpan.End()

	s.diagnosticsCounter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("result", "completed"),
		attribute.Bool("complex", isComplex),
	))

	diagnostics := map[string]interface{}{
		"engine_health":            85 + rand.Intn(10),
		"fuel_efficiency":          92 + rand.Intn(6),
		"vibration_level":          0.2 + rand.Float64()*0.15,
		"exhaust_temp_c":           350 + rand.Intn(50),
		"next_maintenance_hours":   150 + rand.Intn(50),
		"anomaly_score":            rand.Float64() * 0.3,
		"warnings":                 []string{},
	}
	if rand.Float32() < 0.2 {
		diagnostics["warnings"] = []string{"Minor oil pressure fluctuation detected"}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"diagnostic_type":  "full_system",
		"timestamp":        time.Now().Unix(),
		"analysis_time_ms": engineLatency,
		"results":          diagnostics,
		"status":           "completed",
	})
}

// alertsHandler — error-prone endpoint (20% failure rate, ~80-140ms total, 4 child spans).
// Pipeline: query alert history → evaluate thresholds → publish alert → audit log.
func (s *Server) alertsHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Span 1: query recent alert history
	ctx, histSpan := s.tracer.Start(ctx, "query-alert-history",
		trace.WithAttributes(
			attribute.Int("history.window_s", 300),
			attribute.Int("alerts.found", rand.Intn(5)),
			attribute.String("store.backend", "redis"),
		),
	)
	time.Sleep(time.Duration(20+rand.Intn(25)) * time.Millisecond)
	histSpan.End()

	// Span 2: threshold evaluation
	ctx, thrSpan := s.tracer.Start(ctx, "evaluate-thresholds",
		trace.WithAttributes(
			attribute.Int("rules.evaluated", 12),
			attribute.String("ruleset.version", "v2.4"),
			attribute.Float64("threshold.bilge_level_pct", rand.Float64()*100),
		),
	)
	time.Sleep(time.Duration(10+rand.Intn(15)) * time.Millisecond)
	thrSpan.End()

	// Span 3: publish / report alert
	ctx, pubSpan := s.tracer.Start(ctx, "report-system-alert",
		trace.WithAttributes(
			attribute.String("channel", "NMEA-2000"),
			attribute.String("priority", "normal"),
		),
	)
	time.Sleep(time.Duration(25+rand.Intn(30)) * time.Millisecond)

	isFailed := rand.Float32() < 0.20
	if isFailed {
		errorMsg := "sensor communication failure"
		pubSpan.SetStatus(codes.Error, errorMsg)
		pubSpan.SetAttributes(attribute.String("error.type", "sensor_failure"))
		pubSpan.End()

		// Span 4 (error path): failure audit
		_, auditSpan := s.tracer.Start(ctx, "write-failure-audit",
			trace.WithAttributes(
				attribute.String("error.source", "bilge-pump-sensor"),
				attribute.String("audit.severity", "ERROR"),
			),
		)
		time.Sleep(time.Duration(5+rand.Intn(10)) * time.Millisecond)
		auditSpan.End()

		s.logger.Error("alert system failed",
			zap.String("error", errorMsg),
			zap.String("trace_id", pubSpan.SpanContext().TraceID().String()),
		)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{
			"error":    errorMsg,
			"trace_id": pubSpan.SpanContext().TraceID().String(),
			"details":  "Failed to read bilge pump sensor data",
		})
		return
	}
	pubSpan.End()

	// Span 4 (success path): audit log write
	_, auditSpan := s.tracer.Start(ctx, "write-audit-log",
		trace.WithAttributes(
			attribute.String("audit.outcome", "success"),
			attribute.String("log.destination", "syslog"),
		),
	)
	time.Sleep(time.Duration(5+rand.Intn(8)) * time.Millisecond)
	auditSpan.End()

	alertType := []string{"info", "warning", "normal"}[rand.Intn(3)]
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"alert_id":      rand.Intn(10000),
		"type":          alertType,
		"message":       "All systems operational",
		"timestamp":     time.Now().Unix(),
		"sensor_status": "online",
	})
}
