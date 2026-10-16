import { shutdown as shutdownTracing } from './lib/otel.js';
import { fileURLToPath } from 'url';
import express from 'express';
import helmet from 'helmet';
import pinoHttp from 'pino-http';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';

import logger from './lib/logger.js';
import { register } from './lib/metrics.js';
import * as db from './lib/db.js';
import * as redis from './lib/redis.js';
import { RedisFallbackStore } from './lib/rate-limit-store.js';
import requestIdMiddleware from './middleware/requestId.js';
import metricsMiddleware from './middleware/metrics.js';
import errorHandler from './middleware/error.js';
import healthRouter, { setShuttingDown } from './routes/health.js';

export const app = express();
const PORT = process.env.PORT || 3000;
// Shutdown: readiness fails for READINESS_GRACE_MS before the server closes;
// SHUTDOWN_TIMEOUT_MS after the signal the process exits regardless, well
// inside the pod's terminationGracePeriodSeconds (60 s).
const READINESS_GRACE_MS = 5_000;
const SHUTDOWN_TIMEOUT_MS = 45_000;

const positiveInt = (value, fallback) => {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isInteger(n) && n > 0 ? n : fallback;
};

// Behind the ingress controller every request arrives from the controller's
// pod, so without this req.ip is that pod's address and all clients share one
// rate limit. TRUST_PROXY is the number of proxies in front of the app (1
// behind ingress-nginx): req.ip is then the address the nearest proxy saw,
// and X-Forwarded-For entries a client adds itself are ignored.
const trustProxy = positiveInt(process.env.TRUST_PROXY, 0);
if (trustProxy) app.set('trust proxy', trustProxy);

// 1. Security headers
app.use(helmet());

// 2. Request ID (before logging so the logger can include it, and before the
// body parser so a malformed body's 400 carries it too)
app.use(requestIdMiddleware);

// 3. Structured request logging
app.use(
  pinoHttp({
    logger,
    genReqId: (req) => req.id,
  }),
);

// 4. Prometheus histogram middleware
app.use(metricsMiddleware);

// 5. Rate limiting — skip health and metrics endpoints
// RATE_LIMIT_MAX: requests per client per minute (default 100); staging
// raises it so a load test from one machine measures the app, not the limit.
// Counted in Redis when REDIS_URL is set, so the limit is per client across
// all replicas (lib/rate-limit-store.js); in memory per pod otherwise.
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: positiveInt(process.env.RATE_LIMIT_MAX, 100),
  store: redis.client ? new RedisFallbackStore(redis.client) : undefined,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) =>
    req.path.startsWith('/health') || req.path === '/metrics',
});
app.use(limiter);

// 6. JSON body parser (a request over the rate limit is not parsed)
app.use(express.json());

// 7. /api/items — persisted via Postgres
const createItemSchema = z.object({
  name: z.string().min(1).max(100),
});

// GET /api/items — returns the 100 most-recently created items
app.get('/api/items', async (req, res, next) => {
  try {
    const result = await db.query(
      'SELECT id, name, created_at FROM items ORDER BY created_at DESC LIMIT 100',
    );
    res.json(result.rows);
  } catch (err) {
    next(err);
  }
});

// POST /api/items — creates a new item and returns the persisted row
app.post('/api/items', async (req, res, next) => {
  try {
    const { name } = createItemSchema.parse(req.body);
    const result = await db.query(
      'INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at',
      [name],
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    next(err);
  }
});

// 8. Prometheus metrics endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// 9. Health router
app.use('/health', healthRouter);

// 10. Error handler (must be last)
app.use(errorHandler);

/**
 * Start the HTTP server and register graceful-shutdown handlers.
 * Returns the http.Server instance so callers (e.g., tests) can close it.
 */
export function start(port = PORT) {
  let isShuttingDown = false;

  const server = app.listen(port, () => {
    logger.info({ port }, 'Server running');
  });

  // Graceful shutdown: fail readiness, wait for the endpoints to drop the pod,
  // stop accepting connections and let in-flight requests finish, and only
  // then close the DB pool and Redis, which those requests may still use, and
  // flush the spans.
  const shutdown = (signal) => {
    if (isShuttingDown) return;
    isShuttingDown = true;
    logger.info({ signal }, 'Shutdown signal received, draining connections');

    // Flip the readiness flag so k8s stops routing new traffic
    setShuttingDown(true);

    const forceExit = setTimeout(() => {
      logger.error('Forced exit after shutdown timeout');
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS);
    forceExit.unref();

    // Give in-flight readiness probes ~5s to observe the 503
    setTimeout(async () => {
      let exitCode = 0;
      try {
        await new Promise((resolve, reject) => {
          server.close((err) => (err ? reject(err) : resolve()));
          server.closeIdleConnections?.();
        });
        logger.info('HTTP server closed');
      } catch (err) {
        logger.error({ err }, 'Error during server.close');
        exitCode = 1;
      }

      // Drain persistent connections — DB first (primary state), then Redis (cache)
      try {
        await db.shutdown();
        logger.info('DB pool drained');
      } catch (err) {
        logger.error({ err }, 'Error draining DB pool');
      }
      try {
        await redis.shutdown();
        logger.info('Redis connection closed');
      } catch (err) {
        logger.error({ err }, 'Error closing Redis connection');
      }
      // Last, so spans from the drain are exported too
      await shutdownTracing();

      if (exitCode === 0) logger.info('Process terminated cleanly');
      process.exit(exitCode);
    }, READINESS_GRACE_MS);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  return server;
}

// Only bind the port when executed directly (not when imported by tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  start();
}

export default app;
