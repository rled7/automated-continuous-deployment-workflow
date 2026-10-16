import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';

// lib/redis.js reads its configuration when it is first imported, so each
// test sets the environment, mocks `ioredis`, and imports a fresh copy.

const ENV_KEYS = ['NODE_ENV', 'REDIS_URL', 'REDIS_FAKE'];
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

// Imports lib/redis.js with a fake ioredis client; `ping` decides what PING does.
async function loadRedis(env, ping = () => Promise.resolve('PONG')) {
  Object.assign(process.env, env);
  const clients = [];
  class FakeRedis {
    constructor(url, options) {
      this.url = url;
      this.options = options;
      this.handlers = {};
      this.ping = jest.fn(ping);
      this.quit = jest.fn(() => Promise.resolve('OK'));
      clients.push(this);
    }

    on(event, handler) {
      this.handlers[event] = handler;
    }
  }
  const logger = { error: jest.fn(), info: jest.fn(), debug: jest.fn() };
  jest.unstable_mockModule('ioredis', () => ({ default: FakeRedis }));
  jest.unstable_mockModule('../../lib/logger.js', () => ({ default: logger }));
  const redis = await import('../../lib/redis.js');
  return { redis, clients, logger };
}

describe('lib/redis.js without REDIS_URL', () => {
  test('creates no client, rejects health checks, and shuts down cleanly', async () => {
    const { redis, clients } = await loadRedis({});
    expect(clients).toHaveLength(0);
    expect(redis.client).toBeNull();
    await expect(redis.healthCheck()).rejects.toThrow('REDIS_URL env var is required');
    await expect(redis.shutdown()).resolves.toBeUndefined();
  });
});

describe('lib/redis.js with REDIS_URL', () => {
  const env = { REDIS_URL: 'redis://redis.staging.svc.cluster.local:6379' };

  test('creates a lazily connecting client for that URL', async () => {
    const { clients } = await loadRedis(env);
    expect(clients).toHaveLength(1);
    expect(clients[0].url).toBe(env.REDIS_URL);
    expect(clients[0].options).toEqual({ maxRetriesPerRequest: 1, lazyConnect: true });
  });

  test('healthCheck() resolves "ok" when PING answers', async () => {
    const { redis, clients } = await loadRedis(env);
    await expect(redis.healthCheck()).resolves.toBe('ok');
    expect(clients[0].ping).toHaveBeenCalled();
  });

  test('healthCheck() rejects when PING does not answer in time', async () => {
    const { redis } = await loadRedis(env, () => new Promise(() => {}));
    await expect(redis.healthCheck(10)).rejects.toThrow('Redis health check timed out');
  });

  test('logs connection errors instead of crashing', async () => {
    const { clients, logger } = await loadRedis(env);
    const err = new Error('ECONNRESET');
    clients[0].handlers.error(err);
    expect(logger.error).toHaveBeenCalledWith({ err }, 'redis client error');
  });

  test('shutdown() closes the connection', async () => {
    const { redis, clients } = await loadRedis(env);
    await redis.shutdown();
    expect(clients[0].quit).toHaveBeenCalled();
  });
});

describe('lib/redis.js with REDIS_FAKE=1', () => {
  test('needs no client and passes health checks', async () => {
    const { redis, clients } = await loadRedis({ REDIS_FAKE: '1' });
    expect(clients).toHaveLength(0);
    await expect(redis.healthCheck()).resolves.toBe('ok');
    await expect(redis.shutdown()).resolves.toBeUndefined();
  });
});

describe('lib/redis.js REDIS_FAKE guard', () => {
  test.each(['production', 'staging'])('refuses to load with REDIS_FAKE=1 when NODE_ENV is %s', async (env) => {
    await expect(loadRedis({ REDIS_FAKE: '1', NODE_ENV: env })).rejects.toThrow(
      `REDIS_FAKE must not be set when NODE_ENV is ${env}`,
    );
  });

  test('loads with REDIS_FAKE=1 in test', async () => {
    await expect(loadRedis({ REDIS_FAKE: '1', NODE_ENV: 'test' })).resolves.toBeDefined();
  });
});
