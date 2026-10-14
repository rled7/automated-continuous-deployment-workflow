import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';

// lib/db.js reads its configuration when it is first imported, so each test
// sets the environment, mocks `pg`, and imports a fresh copy of the module.

const ENV_KEYS = ['DB_FAKE', 'DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASSWORD', 'DB_NAME', 'DB_SSL'];
let savedEnv;

beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  jest.resetModules();
});

afterEach(() => {
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

// Imports lib/db.js with a fake pg.Pool; `query` decides what pool.query does.
async function loadDb(env, query = () => Promise.resolve({ rows: [], rowCount: 0 })) {
  Object.assign(process.env, env);
  const pools = [];
  class FakePool {
    constructor(config) {
      this.config = config;
      this.handlers = {};
      this.query = jest.fn(query);
      this.end = jest.fn(() => Promise.resolve());
      pools.push(this);
    }

    on(event, handler) {
      this.handlers[event] = handler;
    }
  }
  const logger = { error: jest.fn(), info: jest.fn(), debug: jest.fn() };
  jest.unstable_mockModule('pg', () => ({ default: { Pool: FakePool } }));
  jest.unstable_mockModule('../../lib/logger.js', () => ({ default: logger }));
  const db = await import('../../lib/db.js');
  return { db, pools, logger };
}

describe('lib/db.js without a database configured', () => {
  test('creates no pool, rejects queries and health checks, and shuts down cleanly', async () => {
    const { db, pools } = await loadDb({});
    expect(pools).toHaveLength(0);
    expect(db.pool).toBeNull();
    await expect(db.query('SELECT 1')).rejects.toThrow('DB not configured');
    await expect(db.healthCheck()).rejects.toThrow('DB not configured');
    await expect(db.shutdown()).resolves.toBeUndefined();
  });

  test('needs both DB_HOST and DB_PASSWORD', async () => {
    const { pools } = await loadDb({ DB_HOST: 'db.internal' });
    expect(pools).toHaveLength(0);
  });
});

describe('lib/db.js with a database configured', () => {
  test('builds the pool from the environment, with defaults', async () => {
    const { pools } = await loadDb({ DB_HOST: 'db.internal', DB_PASSWORD: 'secret' });
    expect(pools).toHaveLength(1);
    expect(pools[0].config).toMatchObject({
      host: 'db.internal',
      port: 5432,
      user: 'appuser',
      password: 'secret',
      database: 'appdb',
      ssl: false,
      max: 10,
    });
  });

  test('honours DB_PORT, DB_USER, DB_NAME and DB_SSL', async () => {
    const { pools } = await loadDb({
      DB_HOST: 'db.internal', DB_PASSWORD: 'secret',
      DB_PORT: '6543', DB_USER: 'svc', DB_NAME: 'orders', DB_SSL: 'true',
    });
    expect(pools[0].config).toMatchObject({
      port: 6543, user: 'svc', database: 'orders', ssl: { rejectUnauthorized: true },
    });
  });

  test('query() passes text and params to the pool and returns its result', async () => {
    const result = { rows: [{ id: 1 }], rowCount: 1 };
    const { db, pools } = await loadDb(
      { DB_HOST: 'db.internal', DB_PASSWORD: 'secret' },
      () => Promise.resolve(result),
    );
    await expect(db.query('SELECT * FROM items WHERE id = $1', [1])).resolves.toBe(result);
    expect(pools[0].query).toHaveBeenCalledWith('SELECT * FROM items WHERE id = $1', [1]);
  });

  test('healthCheck() resolves "ok" when SELECT 1 succeeds', async () => {
    const { db, pools } = await loadDb({ DB_HOST: 'db.internal', DB_PASSWORD: 'secret' });
    await expect(db.healthCheck()).resolves.toBe('ok');
    expect(pools[0].query).toHaveBeenCalledWith('SELECT 1');
  });

  test('healthCheck() rejects when the database does not answer in time', async () => {
    const { db } = await loadDb(
      { DB_HOST: 'db.internal', DB_PASSWORD: 'secret' },
      () => new Promise(() => {}),
    );
    await expect(db.healthCheck(10)).rejects.toThrow('DB health check timed out');
  });

  test('logs background pool errors instead of crashing', async () => {
    const { pools, logger } = await loadDb({ DB_HOST: 'db.internal', DB_PASSWORD: 'secret' });
    const err = new Error('connection reset');
    pools[0].handlers.error(err);
    expect(logger.error).toHaveBeenCalledWith({ err }, 'pg pool background error');
  });

  test('shutdown() drains the pool', async () => {
    const { db, pools } = await loadDb({ DB_HOST: 'db.internal', DB_PASSWORD: 'secret' });
    await db.shutdown();
    expect(pools[0].end).toHaveBeenCalled();
  });
});

describe('lib/db.js with DB_FAKE=1', () => {
  test('stores items and lists the newest first', async () => {
    const { db, pools } = await loadDb({ DB_FAKE: '1' });
    expect(pools).toHaveLength(0);
    const first = await db.query('INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at', ['first']);
    expect(first.rows[0]).toMatchObject({ id: 1, name: 'first' });
    await new Promise((resolve) => setTimeout(resolve, 5));
    await db.query('INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at', ['second']);
    const list = await db.query('SELECT id, name, created_at FROM items ORDER BY created_at DESC LIMIT 100');
    expect(list.rows.map((r) => r.name)).toEqual(['second', 'first']);
  });

  test('answers SELECT 1 and other queries, and passes health checks', async () => {
    const { db } = await loadDb({ DB_FAKE: '1' });
    await expect(db.query('SELECT 1')).resolves.toMatchObject({ rowCount: 1 });
    await expect(db.query('DELETE FROM items')).resolves.toEqual({ rows: [], rowCount: 0 });
    await expect(db.healthCheck()).resolves.toBe('ok');
  });

  test('shutdown() empties the store', async () => {
    const { db } = await loadDb({ DB_FAKE: '1' });
    await db.query('INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at', ['gone']);
    await db.shutdown();
    const list = await db.query('SELECT id, name, created_at FROM items');
    expect(list.rows).toEqual([]);
  });
});
