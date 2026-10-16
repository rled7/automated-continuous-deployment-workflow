import { httpRequestDurationMicroseconds } from '../lib/metrics.js';

/**
 * Express middleware that records HTTP request duration in the histogram
 * on response finish. The route label is the matched route's pattern with the
 * router's mount path (e.g. /health/ready, /api/items/:id), or "unmatched"
 * when no route matched: raw paths of 404s would make the label unbounded.
 */
const metricsMiddleware = (req, res, next) => {
  const start = Date.now();

  res.on('finish', () => {
    const duration = Date.now() - start;
    const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
    httpRequestDurationMicroseconds.observe(
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
