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
const otel = { shutdown: jest.fn(async () => {}) };
jest.unstable_mockModule('../../lib/db.js', () => db);
jest.unstable_mockModule('../../lib/redis.js', () => redis);
jest.unstable_mockModule('../../lib/otel.js', () => otel);

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

  test('POST /api/items with malformed JSON returns 400 with a request ID', async () => {
    jest.spyOn(logger, 'error').mockImplementation(() => {});
    const res = await request(app)
      .post('/api/items')
      .set('Content-Type', 'application/json')
      .set('x-request-id', 'bad-json-1')
      .send('{"name": ');
    expect(res.status).toBe(400);
    expect(res.headers['x-request-id']).toBe('bad-json-1');
    expect(res.body.error.requestId).toBe('bad-json-1');
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

  test('on SIGTERM: fails readiness, closes the server, then drains DB and Redis, flushes spans, exits 0', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    db.shutdown.mockClear();
    redis.shutdown.mockClear();
    otel.shutdown.mockClear();
    // Whether the server was still listening when the DB pool was drained.
    let listeningAtDbShutdown;
    db.shutdown.mockImplementationOnce(async () => {
      listeningAtDbShutdown = server.listening;
    });

    await shutDown('SIGTERM');

    const ready = await request(app).get('/health/ready');
    expect(ready.status).toBe(503);
    expect(db.shutdown).toHaveBeenCalled();
    expect(listeningAtDbShutdown).toBe(false);
    expect(redis.shutdown).toHaveBeenCalled();
    expect(otel.shutdown).toHaveBeenCalled();
    expect(otel.shutdown.mock.invocationCallOrder[0])
      .toBeGreaterThan(redis.shutdown.mock.invocationCallOrder[0]);
    expect(process.exit.mock.invocationCallOrder[0])
      .toBeGreaterThan(otel.shutdown.mock.invocationCallOrder[0]);
    expect(server.listening).toBe(false);
    expect(process.exit).toHaveBeenCalledWith(0);
  });

  test('waits for in-flight requests before draining the DB pool', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    db.shutdown.mockClear();
    let release;
    db.query.mockImplementationOnce(() => new Promise((resolve) => {
      release = () => resolve({ rows: [{ id: 1, name: 'slow' }], rowCount: 1 });
    }));
    const inFlight = request(server).get('/api/items').then((res) => res);
    while (!release) await new Promise((resolve) => setImmediate(resolve));

    await shutDown('SIGTERM');
    expect(db.shutdown).not.toHaveBeenCalled();
    expect(process.exit).not.toHaveBeenCalled();

    release();
    const res = await inFlight;
    expect(res.status).toBe(200);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(db.shutdown).toHaveBeenCalled();
    expect(process.exit).toHaveBeenCalledWith(0);
  });

  test('forces exit 45 s after the signal if requests never finish', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    let release;
    db.query.mockImplementationOnce(() => new Promise((resolve) => {
      release = () => resolve({ rows: [], rowCount: 0 });
    }));
    const inFlight = request(server).get('/api/items').then((res) => res);
    while (!release) await new Promise((resolve) => setImmediate(resolve));

    jest.useFakeTimers({ doNotFake: ['nextTick', 'setImmediate'] });
    handlers.SIGTERM();
    await jest.advanceTimersByTimeAsync(44_999);
    expect(process.exit).not.toHaveBeenCalled();
    await jest.advanceTimersByTimeAsync(1);
    expect(logger.error).toHaveBeenCalledWith('Forced exit after shutdown timeout');
    expect(process.exit).toHaveBeenCalledWith(1);
    jest.useRealTimers();

    release();
    await inFlight;
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

  test('exits 1 when the server fails to close', async () => {
    server = start(0);
    await new Promise((resolve) => server.once('listening', resolve));
    await new Promise((resolve) => server.close(resolve));

    await shutDown('SIGTERM');

    expect(logger.error).toHaveBeenCalledWith(expect.anything(), 'Error during server.close');
    expect(process.exit).toHaveBeenCalledWith(1);
  });
});
