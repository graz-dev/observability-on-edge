import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const sensorErrors = new Counter('sensor_errors');
const slowDiagnostics = new Counter('slow_diagnostics');
const latency = new Trend('request_latency');

// Test configuration - simulates vessel monitoring patterns
// Duration: 40 min total — covers the full 25-min live demo + buffer.
// Managed by the k6 Operator (TestRun CR), runs inside the cluster on the
// edge node, connecting directly to the app via ClusterIP (no port-forward).
export const options = {
  stages: [
    { duration: '30s', target: 5 },   // Startup: systems coming online
    { duration: '39m', target: 8 },   // Sustained: covers full demo + buffer
    { duration: '30s', target: 0 },   // Shutdown
  ],
  thresholds: {
    'http_req_duration': ['p(95)<600'], // 95% of requests should be below 600ms
    'errors': ['rate<0.15'],            // Error rate should be below 15%
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://edge-demo-app.observability.svc.cluster.local:8080';

// Simulate different maritime monitoring patterns
export default function () {
  const scenario = Math.random();

  if (scenario < 0.5) {
    // 50% - Continuous engine monitoring (fast, high frequency)
    monitorEngine();
  } else if (scenario < 0.8) {
    // 30% - Navigation data collection (fast, high frequency)
    monitorNavigation();
  } else if (scenario < 0.92) {
    // 12% - Run diagnostics (slow, medium frequency)
    runDiagnostics();
  } else {
    // 8% - Check system alerts (error-prone, low frequency)
    checkAlerts();
  }

  // Simulate realistic sensor polling intervals
  sleep(Math.random() * 2 + 0.5); // 0.5-2.5 seconds
}

// Engine sensor monitoring - fast, critical data
function monitorEngine() {
  const startTime = Date.now();
  const res = http.get(`${BASE_URL}/api/sensors/engine`);
  const duration = Date.now() - startTime;

  const success = check(res, {
    'engine sensors status is 200': (r) => r.status === 200,
    'engine read time < 150ms': (r) => r.timings.duration < 150,
  });

  errorRate.add(!success);
  latency.add(duration);

  if (duration > 200) {
    slowDiagnostics.add(1);
  }
}

// Navigation sensor monitoring - fast, critical data
function monitorNavigation() {
  const startTime = Date.now();
  const res = http.get(`${BASE_URL}/api/sensors/navigation`);
  const duration = Date.now() - startTime;

  const success = check(res, {
    'navigation sensors status is 200': (r) => r.status === 200,
    'navigation read time < 120ms': (r) => r.timings.duration < 120,
  });

  errorRate.add(!success);
  latency.add(duration);

  if (duration > 200) {
    slowDiagnostics.add(1);
  }
}

// Engine diagnostics - slow, complex analysis
function runDiagnostics() {
  const startTime = Date.now();
  const res = http.get(`${BASE_URL}/api/analytics/diagnostics`);
  const duration = Date.now() - startTime;

  const success = check(res, {
    'diagnostics completed': (r) => r.status === 200,
    'diagnostics time < 1500ms': (r) => r.timings.duration < 1500,
  });

  errorRate.add(!success);
  latency.add(duration);

  if (duration > 500) {
    slowDiagnostics.add(1);
  }

  // Diagnostics runs take longer, so longer wait before next request
  sleep(Math.random() * 5 + 2); // 2-7 seconds between diagnostic runs
}

// System alerts checking - can fail due to sensor issues
function checkAlerts() {
  const startTime = Date.now();
  const res = http.get(`${BASE_URL}/api/alerts/system`);
  const duration = Date.now() - startTime;

  const success = check(res, {
    'alert check completed': (r) => r.status === 200 || r.status === 500,
  });

  if (res.status === 500) {
    sensorErrors.add(1);
  }

  errorRate.add(!success);
  latency.add(duration);

  if (duration > 200) {
    slowDiagnostics.add(1);
  }
}

export function handleSummary(data) {
  return {
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),
  };
}

function textSummary(data, options) {
  const indent = options.indent || '';
  const enableColors = options.enableColors || false;

  let summary = '\n';
  summary += `${indent}✓ Maritime Vessel Monitoring Load Test Complete\n`;
  summary += `${indent}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
  summary += `${indent}  Scenarios:  (100.00%) Vessel monitoring patterns\n`;
  summary += `${indent}  Checks:     ${data.metrics.checks.values.passes} passed, ${data.metrics.checks.values.fails} failed\n`;
  summary += `${indent}  HTTP Reqs:  ${data.metrics.http_reqs.values.count} total\n`;
  summary += `${indent}  Duration:   ${Math.round(data.state.testRunDurationMs / 1000)}s\n`;
  summary += `${indent}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
  summary += `${indent}  Request Metrics:\n`;
  summary += `${indent}    - Avg Duration: ${Math.round(data.metrics.http_req_duration.values.avg)}ms\n`;
  summary += `${indent}    - P95 Duration: ${Math.round(data.metrics.http_req_duration.values['p(95)'])}ms\n`;
  summary += `${indent}    - P99 Duration: ${Math.round(data.metrics.http_req_duration.values['p(99)'])}ms\n`;
  summary += `${indent}  Maritime Monitoring Metrics:\n`;
  summary += `${indent}    - Error Rate: ${(data.metrics.errors.values.rate * 100).toFixed(2)}%\n`;
  summary += `${indent}    - Slow Diagnostics (>200ms): ${data.metrics.slow_diagnostics.values.count}\n`;
  summary += `${indent}    - Sensor Communication Errors: ${data.metrics.sensor_errors.values.count}\n`;
  summary += `${indent}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n`;

  return summary;
}
