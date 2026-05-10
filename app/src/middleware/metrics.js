import { httpRequestDurationMs } from '../lib/metrics.js';

/**
 * Express middleware that records HTTP request duration in the histogram
 * on response finish. Route label uses req.route.path when available,
 * falling back to req.path.
 */
const metricsMiddleware = (req, res, next) => {
  const start = Date.now();

  res.on('finish', () => {
    const duration = Date.now() - start;
    const route = (req.route && req.route.path) || req.path || 'unknown';
    httpRequestDurationMs.observe(
      {
        method: req.method,
        route,
        status_code: res.statusCode,
      },
      duration,
    );
  });

  next();
};

export default metricsMiddleware;
