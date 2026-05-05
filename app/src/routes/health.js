import express from 'express';

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
 * Stubbed dependency checks.
 * Replace the bodies with real async calls (pool.query, redis.ping, etc.).
 */
const checkDatabase = async () => ({ ok: true, latencyMs: 0 });
const checkRedis = async () => ({ ok: true, latencyMs: 0 });

// GET /health/live — pod is alive as long as the process runs
router.get('/live', (req, res) => {
  res.json({ status: 'alive' });
});

// GET /health/ready — returns 503 during shutdown or if a dependency is down
router.get('/ready', async (req, res) => {
  if (shuttingDown) {
    return res.status(503).json({ status: 'shutting_down' });
  }

  const [db, redis] = await Promise.all([checkDatabase(), checkRedis()]);
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
