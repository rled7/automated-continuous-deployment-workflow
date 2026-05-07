import './lib/otel.js';
import { createRequire } from 'module';
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
import requestIdMiddleware from './middleware/requestId.js';
import metricsMiddleware from './middleware/metrics.js';
import errorHandler from './middleware/error.js';
import healthRouter, { setShuttingDown } from './routes/health.js';

export const app = express();
const PORT = process.env.PORT || 3000;
const SHUTDOWN_TIMEOUT_MS = 55_000;

// 1. Security headers + JSON body parser
app.use(helmet());
app.use(express.json());

// 2. Request ID (before logging so the logger can include it)
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
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) =>
    req.path.startsWith('/health') || req.path === '/metrics',
});
app.use(limiter);

// 6. /api/items — persisted via Postgres
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

// 7. Prometheus metrics endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// 8. Health router
app.use('/health', healthRouter);

// 9. Error handler (must be last)
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

  // Graceful shutdown
  const shutdown = (signal) => {
    if (isShuttingDown) return;
    isShuttingDown = true;
    logger.info({ signal }, 'Shutdown signal received, draining connections');

    // Flip the readiness flag so k8s stops routing new traffic
    setShuttingDown(true);

    // Give in-flight readiness probes ~5s to observe the 503
    setTimeout(async () => {
      const forceExit = setTimeout(() => {
        logger.error('Forced exit after shutdown timeout');
        process.exit(1);
      }, SHUTDOWN_TIMEOUT_MS);
      forceExit.unref();

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

      server.close((err) => {
        if (err) {
          logger.error({ err }, 'Error during server.close');
          process.exit(1);
        }
        logger.info('Process terminated cleanly');
        process.exit(0);
      });
    }, 5_000);
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
