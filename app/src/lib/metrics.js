import { Registry, collectDefaultMetrics, Histogram } from 'prom-client';

const register = new Registry();

collectDefaultMetrics({ register });

const httpRequestDurationMs = new Histogram({
  name: 'http_request_duration_ms',
  help: 'Duration of HTTP requests in milliseconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000],
  registers: [register],
});

export { register, httpRequestDurationMs };
