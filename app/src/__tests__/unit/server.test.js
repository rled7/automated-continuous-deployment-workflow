import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';
import request from 'supertest';

// server.js with lib/db.js and lib/redis.js replaced by in-memory stand-ins
// whose calls the tests can check (ES module exports cannot be spied on).
const items = [];
const db = {
  query: jest.fn(async (text, params) => {
    if (/^\s*INSERT/i.test(text)) {
      const row = { id: items.length + 1, name: params[0], created_at: new Date().toISOString() };
      items.push(row);
      return { rows: [row], rowCount: 1 };
    }
    return { rows: [...items].reverse(), rowCount: items.length };
  }),
  healthCheck: jest.fn(async () => 'ok'),
  shutdown: jest.fn(async () => {}),
};
const redis = {
  client: null,
  healthCheck: jest.fn(async () => 'ok'),
  shutdown: jest.fn(async () => {}),
};
jest.unstable_mockModule('../../lib/db.js', () => db);
jest.unstable_mockModule('../../lib/redis.js', () => redis);

const { app, start } = await import('../../server.js');
const { default: logger } = await import('../../lib/logger.js');

describe('API routes', () => {
  test('POST /api/items stores an item and GET /api/items lists it', async () => {
    const created = await request(app).post('/api/items').send({ name: 'widget' });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ name: 'widget' });
    const list = await request(app).get('/api/items');
    expect(list.status).toBe(200);
    expect(list.body.map((i) => i.name)).toContain('widget');
  });

  test('POST /api/items rejects an empty name with 400', async () => {
    const res = await request(app).post('/api/items').send({ name: '' });
    expect(res.status).toBe(400);
  });

  test('GET /api/items passes database errors to the error handler', async () => {
    jest.spyOn(logger, 'error').mockImplementation(() => {});
    db.query.mockRejectedValueOnce(new Error('connection refused'));
    const res = await request(app).get('/api/items');
    expect(res.status).toBe(500);
  });

  test('GET /metrics serves Prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });
});

describe('start() and graceful shutdown', () => {
  let handlers;
  let server;

  beforeEach(() => {
    handlers = {};
    jest.spyOn(process, 'on').mockImplementation((event, handler) => {
      handlers[event] = handler;
      return process;
    });
    jest.spyOn(process, 'exit').mockImplementation(() => {});
    jest.spyOn(logger, 'info').mockImplementation(() => {});
    jest.spyOn(logger, 'error').mockImplementation(() => {});
  });

  afterEach(async () => {
    jest.useRealTimers();
    jest.restoreAllMocks();
    if (server?.listening) await new Promise((resolve) => server.close(resolve));
  });

  // Sends the signals, then runs the shutdown sequence: the 5 s readiness
  // grace period, then draining.
  async function shutDown(...signals) {
    jest.useFakeTimers({ doNotFake: ['nextTick', 'setImmediate'] });
    for (const signal of signals) handlers[signal]();
    await jest.advanceTimersByTimeAsync(5_000);
    jest.useRealTimers();
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  test('listens and registers SIGTERM and SIGINT handlers', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    expect(server.address().port).toBeGreaterThan(0);
    expect(Object.keys(handlers)).toEqual(expect.arrayContaining(['SIGTERM', 'SIGINT']));
  });

  test('on SIGTERM: fails readiness, drains DB and Redis, closes, exits 0', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    db.shutdown.mockClear();
    redis.shutdown.mockClear();

    await shutDown('SIGTERM');

    const ready = await request(app).get('/health/ready');
    expect(ready.status).toBe(503);
    expect(db.shutdown).toHaveBeenCalled();
    expect(redis.shutdown).toHaveBeenCalled();
    expect(server.listening).toBe(false);
    expect(process.exit).toHaveBeenCalledWith(0);
  });

  test('keeps shutting down when draining fails, and ignores a second signal', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    db.shutdown.mockRejectedValueOnce(new Error('pool busy'));
    redis.shutdown.mockRejectedValueOnce(new Error('redis gone'));

    // A second signal while shutting down is ignored.
    await shutDown('SIGINT', 'SIGTERM');

    expect(logger.error).toHaveBeenCalledWith(expect.anything(), 'Error draining DB pool');
    expect(logger.error).toHaveBeenCalledWith(expect.anything(), 'Error closing Redis connection');
    expect(process.exit).toHaveBeenCalledTimes(1);
    expect(process.exit).toHaveBeenCalledWith(0);
  });
});
