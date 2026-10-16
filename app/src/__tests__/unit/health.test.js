import { jest, describe, test, expect, beforeEach } from '@jest/globals';
import express from 'express';
import request from 'supertest';

// Import fresh copies each test suite run by resetting the module state
import healthRouter, { setShuttingDown } from '../../routes/health.js';

function buildApp() {
  const app = express();
  app.use(express.json());
  app.use('/health', healthRouter);
  return app;
}

describe('Health Router', () => {
  beforeEach(() => {
    // Reset shutdown state before each test
    setShuttingDown(false);
  });

  describe('GET /health/live', () => {
    test('returns 200 with status alive', async () => {
      const app = buildApp();
      const res = await request(app).get('/health/live');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ status: 'alive' });
    });
  });

  describe('GET /health/ready', () => {
    test('returns 200 by default (all deps healthy)', async () => {
      const app = buildApp();
      const res = await request(app).get('/health/ready');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('ready');
    });

    test('returns 503 during shutdown', async () => {
      setShuttingDown(true);
      const app = buildApp();
      const res = await request(app).get('/health/ready');
      expect(res.status).toBe(503);
      expect(res.body.status).toBe('shutting_down');
    });
  });
});

// A fresh health router whose dependency probes resolve or reject as given.
async function loadRouterWith({ database, redis }) {
  jest.resetModules();
  const probe = (ok) => jest.fn(async () => {
    if (!ok) throw new Error('down');
    return 'ok';
  });
  jest.unstable_mockModule('../../lib/db.js', () => ({ healthCheck: probe(database) }));
  jest.unstable_mockModule('../../lib/redis.js', () => ({ healthCheck: probe(redis) }));
  const mod = await import('../../routes/health.js');
  const app = express();
  app.use('/health', mod.default);
  return { app, setShuttingDown: mod.setShuttingDown };
}

describe('GET /health/ready with a dependency down', () => {
  test('Redis down: 200 "degraded" — no route needs Redis', async () => {
    const { app } = await loadRouterWith({ database: true, redis: false });
    const res = await request(app).get('/health/ready');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'degraded', checks: { database: 'ok', redis: 'error' } });
  });

  test('database down: 503', async () => {
    const { app } = await loadRouterWith({ database: false, redis: true });
    const res = await request(app).get('/health/ready');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ status: 'unavailable', checks: { database: 'error', redis: 'ok' } });
  });

  test('database and Redis down: 503', async () => {
    const { app } = await loadRouterWith({ database: false, redis: false });
    const res = await request(app).get('/health/ready');
    expect(res.status).toBe(503);
    expect(res.body.checks).toEqual({ database: 'error', redis: 'error' });
  });

  test('shutting down: 503 even with Redis the only failure', async () => {
    const { app, setShuttingDown: setDown } = await loadRouterWith({ database: true, redis: false });
    setDown(true);
    const res = await request(app).get('/health/ready');
    expect(res.status).toBe(503);
    expect(res.body.status).toBe('shutting_down');
  });
});
