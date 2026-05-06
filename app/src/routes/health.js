import express from 'express';
import { healthCheck as dbHealthCheck } from '../lib/db.js';
import { healthCheck as redisHealthCheck } from '../lib/redis.js';

const router = express.Router();

let shuttingDown = false;

/**
 * Called by server.js during graceful shutdown so /ready returns 503,
 * allowing k8s to stop routing traffic before connections are drained.
 */
export const setShuttingDown = (value) => {
  shuttingDown = value;
};

/**
 * Real dependency probes.
 * Both run in parallel via Promise.allSettled so a slow probe does not
 * extend the response time for the other.
 */
const checkDatabase = async () => {
  try {
    await dbHealthCheck(1500);
    return { ok: true };
  } catch {
    return { ok: false };
  }
};

const checkRedis = async () => {
  try {
    await redisHealthCheck(1000);
    return { ok: true };
  } catch {
    return { ok: false };
  }
};

// GET /health/live — pod is alive as long as the process runs
router.get('/live', (req, res) => {
  res.json({ status: 'alive' });
});

// GET /health/ready — returns 503 during shutdown or if a dependency is down
router.get('/ready', async (req, res) => {
  if (shuttingDown) {
    return res.status(503).json({ status: 'shutting_down' });
  }

  // Run both probes in parallel; allSettled ensures neither blocks the other
  const [dbResult, redisResult] = await Promise.allSettled([
    checkDatabase(),
    checkRedis(),
  ]);

  const db    = dbResult.status    === 'fulfilled' ? dbResult.value    : { ok: false };
  const redis = redisResult.status === 'fulfilled' ? redisResult.value : { ok: false };
  const allOk = db.ok && redis.ok;

  const body = {
    status: allOk ? 'ready' : 'degraded',
    checks: {
      database: db.ok ? 'ok' : 'error',
      redis: redis.ok ? 'ok' : 'error',
    },
  };

  return res.status(allOk ? 200 : 503).json(body);
});

export default router;
