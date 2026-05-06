/**
 * Postgres pool wrapper using the `pg` driver.
 *
 * The module is designed to be safe to import even when no database is
 * configured (e.g. local dev without Docker).  Env vars are checked lazily;
 * if they are absent, `query()` and `healthCheck()` reject with a clear
 * "DB not configured" error rather than crashing the process at import time.
 *
 * Environment variables:
 *   DB_HOST     — Postgres host       (required in staging/production)
 *   DB_PORT     — Postgres port       (default: 5432)
 *   DB_USER     — Postgres user       (default: appuser)
 *   DB_PASSWORD — Postgres password   (required in staging/production)
 *   DB_NAME     — Postgres database   (default: appdb)
 *   DB_SSL      — Set to "true" to enable SSL (default: off)
 *   DB_FAKE     — Set to "1" to use an in-memory fake store (for tests without
 *                 a real Postgres instance; ESM Jest + pg-mem can be fiddly)
 *
 * Exports:
 *   query(text, params) — execute a parameterised query
 *   healthCheck(timeoutMs) — SELECT 1; resolves 'ok' or rejects
 *   pool — raw pg.Pool instance (for drain on shutdown)
 *   shutdown() — pool.end(); call during graceful shutdown
 */

import pg from 'pg';
import logger from './logger.js';

const { Pool } = pg;

// ── Configuration ────────────────────────────────────────────────────────────

const DB_HOST     = process.env.DB_HOST;
const DB_PORT     = Number(process.env.DB_PORT || 5432);
const DB_USER     = process.env.DB_USER     || 'appuser';
const DB_PASSWORD = process.env.DB_PASSWORD;
const DB_NAME     = process.env.DB_NAME     || 'appdb';
const DB_SSL      = process.env.DB_SSL === 'true';

// ── DB_FAKE escape hatch ─────────────────────────────────────────────────────
//
// When DB_FAKE=1 (set in jest test environment), the module bypasses the real
// pg Pool and uses a minimal in-memory store instead.  This avoids the
// ESM Jest + pg-mem unstable_mockModule complexity: pg-mem's ESM interop
// requires jest.unstable_mockModule which is incompatible with top-level
// awaits in server.js.  The DB_FAKE flag is a pragmatic escape hatch that
// keeps tests green without fighting the ESM mocking layer.
//
// DO NOT set DB_FAKE in staging or production.

const DB_FAKE = process.env.DB_FAKE === '1';

let fakeStore = [];
let fakeNextId = 1;

// ── Graceful "not configured" sentinel ────────────────────────────────────────
// Module still loads; calls reject if neither real pool nor fake is active.
const configured = DB_FAKE || !!(DB_HOST && DB_PASSWORD);

// ── Pool (only created when env vars are present and not faking) ──────────────

let pool = null;

if (!DB_FAKE && configured) {
  pool = new Pool({
    host:                   DB_HOST,
    port:                   DB_PORT,
    user:                   DB_USER,
    password:               DB_PASSWORD,
    database:               DB_NAME,
    ssl:                    DB_SSL ? { rejectUnauthorized: true } : false,
    min:                    2,
    max:                    10,
    idleTimeoutMillis:      30_000,
    connectionTimeoutMillis: 5_000,
  });

  pool.on('error', (err) => {
    logger.error({ err }, 'pg pool background error');
  });
}

// ── Fake query implementation ─────────────────────────────────────────────────

function fakeQuery(text) {
  const normalized = text.trim().toUpperCase();

  // SELECT id, name, created_at FROM items ORDER BY created_at DESC LIMIT 100
  if (normalized.startsWith('SELECT') && normalized.includes('FROM ITEMS')) {
    const sorted = [...fakeStore].sort(
      (a, b) => new Date(b.created_at) - new Date(a.created_at),
    );
    return Promise.resolve({ rows: sorted.slice(0, 100), rowCount: sorted.length });
  }

  // INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at
  if (normalized.startsWith('INSERT INTO ITEMS')) {
    // params are passed separately — handled by the real query wrapper
    return Promise.resolve({ rows: [], rowCount: 0 }); // overridden below
  }

  // SELECT 1 (health check)
  if (normalized === 'SELECT 1') {
    return Promise.resolve({ rows: [{ '?column?': 1 }], rowCount: 1 });
  }

  return Promise.resolve({ rows: [], rowCount: 0 });
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Execute a parameterised SQL query.
 * @param {string} text   — SQL query with $1, $2 … placeholders
 * @param {Array}  params — parameter values
 * @returns {Promise<import('pg').QueryResult>}
 */
export async function query(text, params) {
  if (DB_FAKE) {
    const normalized = text.trim().toUpperCase();
    if (normalized.startsWith('INSERT INTO ITEMS')) {
      const name = params[0];
      const now  = new Date().toISOString();
      const row  = { id: fakeNextId++, name, created_at: now };
      fakeStore.push(row);
      return { rows: [row], rowCount: 1 };
    }
    return fakeQuery(text);
  }

  if (!pool) {
    throw new Error('DB not configured: DB_HOST and DB_PASSWORD env vars are required');
  }
  const start = Date.now();
  const result = await pool.query(text, params);
  const duration = Date.now() - start;
  logger.debug({ query: text, duration, rows: result.rowCount }, 'db query');
  return result;
}

/**
 * Lightweight liveness probe.  Runs `SELECT 1` with an optional timeout.
 * @param {number} timeoutMs — default 1500 ms
 * @returns {Promise<'ok'>} — rejects with Error if unhealthy or timed out
 */
export async function healthCheck(timeoutMs = 1500) {
  if (DB_FAKE) return Promise.resolve('ok');

  if (!pool) {
    throw new Error('DB not configured');
  }

  const timeoutPromise = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('DB health check timed out')), timeoutMs),
  );

  const checkPromise = pool.query('SELECT 1').then(() => 'ok');

  return Promise.race([checkPromise, timeoutPromise]);
}

/**
 * Drain the pool.  Call during graceful shutdown before server.close().
 * @returns {Promise<void>}
 */
export function shutdown() {
  if (DB_FAKE) {
    fakeStore = [];
    fakeNextId = 1;
    return Promise.resolve();
  }
  if (!pool) return Promise.resolve();
  return pool.end();
}

export { pool };
