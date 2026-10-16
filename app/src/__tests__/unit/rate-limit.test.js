import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';
import request from 'supertest';

// server.js reads TRUST_PROXY and RATE_LIMIT_MAX when it is imported, so each
// test sets them and imports a fresh copy (with lib/db.js and lib/redis.js
// replaced, as in server.test.js).
const ENV_KEYS = ['TRUST_PROXY', 'RATE_LIMIT_MAX'];
let savedEnv;

beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  jest.resetModules();
  // express-rate-limit reports X-Forwarded-For without trust proxy on stderr.
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

async function loadApp(env) {
  Object.assign(process.env, env);
  jest.unstable_mockModule('../../lib/db.js', () => ({
    query: jest.fn(async () => ({ rows: [], rowCount: 0 })),
    healthCheck: jest.fn(async () => 'ok'),
    shutdown: jest.fn(async () => {}),
  }));
  jest.unstable_mockModule('../../lib/redis.js', () => ({
    client: null,
    healthCheck: jest.fn(async () => 'ok'),
    shutdown: jest.fn(async () => {}),
  }));
  const { default: logger } = await import('../../lib/logger.js');
  jest.spyOn(logger, 'info').mockImplementation(() => {});
  const { app } = await import('../../server.js');
  return app;
}

// Statuses of n sequential GET /api/items, optionally from a forwarded address.
async function statuses(app, n, forwardedFor) {
  const out = [];
  for (let i = 0; i < n; i += 1) {
    const req = request(app).get('/api/items');
    if (forwardedFor) req.set('X-Forwarded-For', forwardedFor);
    out.push((await req).status);
  }
  return out;
}

describe('rate limit', () => {
  test('defaults to 100 requests a minute per client', async () => {
    const app = await loadApp({});
    const got = await statuses(app, 101);
    expect(got.slice(0, 100).every((s) => s === 200)).toBe(true);
    expect(got[100]).toBe(429);
  });

  test('RATE_LIMIT_MAX sets the limit; an invalid value keeps the default', async () => {
    let app = await loadApp({ RATE_LIMIT_MAX: '3' });
    expect(await statuses(app, 4)).toEqual([200, 200, 200, 429]);

    jest.resetModules();
    app = await loadApp({ RATE_LIMIT_MAX: 'lots' });
    expect((await statuses(app, 4)).every((s) => s === 200)).toBe(true);
  });

  test('without TRUST_PROXY, everyone behind a proxy shares one limit', async () => {
    const app = await loadApp({ RATE_LIMIT_MAX: '2' });
    expect(await statuses(app, 2, '203.0.113.1')).toEqual([200, 200]);
    expect(await statuses(app, 1, '203.0.113.2')).toEqual([429]);
  });

  test('with TRUST_PROXY=1, each forwarded client has its own limit', async () => {
    const app = await loadApp({ RATE_LIMIT_MAX: '2', TRUST_PROXY: '1' });
    expect(await statuses(app, 3, '203.0.113.1')).toEqual([200, 200, 429]);
    expect(await statuses(app, 2, '203.0.113.2')).toEqual([200, 200]);
  });

  test('with TRUST_PROXY=1, an address the client adds itself is ignored', async () => {
    const app = await loadApp({ RATE_LIMIT_MAX: '1', TRUST_PROXY: '1' });
    // The proxy appends the address it saw: a client rotating the first
    // entry still lands in the bucket of its real address.
    expect(await statuses(app, 1, '198.51.100.7, 203.0.113.1')).toEqual([200]);
    expect(await statuses(app, 1, '198.51.100.8, 203.0.113.1')).toEqual([429]);
  });
});
