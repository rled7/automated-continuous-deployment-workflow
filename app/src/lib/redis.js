/**
 * Redis client wrapper using ioredis.
 *
 * The module is designed to be safe to import even when REDIS_URL is not set.
 * If the env var is absent, `healthCheck()` rejects with a clear error rather
 * than crashing the process at import time.
 *
 * Environment variables:
 *   REDIS_URL   — full Redis URL, e.g. redis://redis.production.svc.cluster.local:6379
 *   REDIS_FAKE  — Set to "1" for an in-memory fake (tests without a real Redis).
 *                 See DB_FAKE in lib/db.js for rationale — same pattern.
 *
 * Exports:
 *   client       — raw ioredis instance (lazyConnect — connect on first use)
 *   healthCheck(timeoutMs) — PING; resolves 'ok' or rejects
 *   shutdown()   — client.quit(); call during graceful shutdown
 */

import Redis from 'ioredis';
import logger from './logger.js';

const REDIS_URL  = process.env.REDIS_URL;
const REDIS_FAKE = process.env.REDIS_FAKE === '1';

// Graceful "not configured" sentinel — module still loads, calls reject.
const configured = REDIS_FAKE || !!REDIS_URL;

// ── Client (only created when env var is present and not faking) ──────────────

let client = null;

if (!REDIS_FAKE && configured) {
  client = new Redis(REDIS_URL, {
    maxRetriesPerRequest: 1,
    lazyConnect: true,
  });

  client.on('error', (err) => {
    // ioredis emits errors on connection loss; log them but don't crash.
    logger.error({ err }, 'redis client error');
  });
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Lightweight liveness probe.  Sends PING with an optional timeout.
 * @param {number} timeoutMs — default 1000 ms
 * @returns {Promise<'ok'>} — rejects with Error if unhealthy or timed out
 */
export async function healthCheck(timeoutMs = 1000) {
  if (REDIS_FAKE) return Promise.resolve('ok');

  if (!client) {
    throw new Error('Redis not configured: REDIS_URL env var is required');
  }

  const timeoutPromise = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('Redis health check timed out')), timeoutMs),
  );

  const checkPromise = client.ping().then(() => 'ok');

  return Promise.race([checkPromise, timeoutPromise]);
}

/**
 * Gracefully close the Redis connection.
 * Call during graceful shutdown, after DB shutdown.
 * @returns {Promise<void>}
 */
export function shutdown() {
  if (REDIS_FAKE) return Promise.resolve();
  if (!client) return Promise.resolve();
  return client.quit();
}

export { client };
