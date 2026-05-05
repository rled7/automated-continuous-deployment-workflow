import express from 'express';
import helmet from 'helmet';
import pinoHttp from 'pino-http';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';

import logger from './lib/logger.js';
import { register } from './lib/metrics.js';
import requestIdMiddleware from './middleware/requestId.js';
import metricsMiddleware from './middleware/metrics.js';
import errorHandler from './middleware/error.js';
import healthRouter, { setShuttingDown } from './routes/health.js';

const app = express();
const PORT = process.env.PORT || 3000;
const SHUTDOWN_TIMEOUT_MS = 55_000;

let isShuttingDown = false;

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

// 6. POST /api/items — validated with Zod
const createItemSchema = z.object({
  name: z.string().min(1).max(100),
});

app.post('/api/items', (req, res, next) => {
  try {
    const { name } = createItemSchema.parse(req.body);
    res.status(201).json({ id: Date.now(), name });
  } catch (err) {
    next(err);
  }
});

app.get('/api/items', (req, res) => {
  res.json([{ id: 1, name: 'demo-item' }]);
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

// Start server
const server = app.listen(PORT, () => {
  logger.info({ port: PORT }, 'Server running');
});

// 10. Graceful shutdown
const shutdown = (signal) => {
  if (isShuttingDown) return;
  isShuttingDown = true;
  logger.info({ signal }, 'Shutdown signal received, draining connections');

  // Flip the readiness flag so k8s stops routing new traffic
  setShuttingDown(true);

  // Give in-flight readiness probes ~5s to observe the 503
  setTimeout(() => {
    const forceExit = setTimeout(() => {
      logger.error('Forced exit after shutdown timeout');
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS);
    forceExit.unref();

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

export default server;
