import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';
import express from 'express';
import pinoHttp from 'pino-http';
import request from 'supertest';

// lib/logger.js with pino writing to an array instead of stdout, so the tests
// can read what a request log line contains, and the options it was given.
const { default: realPino } = await import('pino');
let lines;
let pinoOptions;
let savedNodeEnv;

beforeEach(() => {
  lines = [];
  savedNodeEnv = process.env.NODE_ENV;
  jest.resetModules();
  jest.unstable_mockModule('pino', () => ({
    default: (options) => {
      pinoOptions = options;
      return realPino({ ...options, transport: undefined }, { write: (line) => lines.push(line) });
    },
  }));
});

afterEach(() => {
  process.env.NODE_ENV = savedNodeEnv;
});

const logged = () => lines.join('');

describe('request logging', () => {
  test('server.js logs requests without the Authorization or Cookie values', async () => {
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
    const { app } = await import('../../server.js');

    const res = await request(app)
      .get('/api/items')
      .set('Authorization', 'Bearer s3cret-token')
      .set('Proxy-Authorization', 'Basic s3cret-proxy')
      .set('Cookie', 'session=s3cret-cookie');

    expect(res.status).toBe(200);
    expect(logged()).toContain('request completed');
    expect(logged()).toContain('[Redacted]');
    expect(logged()).not.toMatch(/s3cret/);
  });

  test('Set-Cookie on the response is redacted', async () => {
    const { default: logger } = await import('../../lib/logger.js');
    const app = express();
    app.use(pinoHttp({ logger }));
    app.get('/login', (req, res) => {
      res.cookie('session', 's3cret-session');
      res.json({ ok: true });
    });

    const res = await request(app).get('/login');

    expect(res.headers['set-cookie'][0]).toContain('s3cret-session');
    expect(logged()).toContain('request completed');
    expect(logged()).not.toMatch(/s3cret/);
  });
});

describe('pretty printing', () => {
  test('development uses pino-pretty when it is installed', async () => {
    process.env.NODE_ENV = 'development';
    await import('../../lib/logger.js');
    expect(pinoOptions.transport).toMatchObject({ target: 'pino-pretty' });
  });

  test('development without pino-pretty (the production image) logs JSON', async () => {
    process.env.NODE_ENV = 'development';
    const actual = await import('module');
    jest.unstable_mockModule('module', () => ({
      ...actual,
      createRequire: () => ({
        resolve: () => {
          throw Object.assign(new Error("Cannot find module 'pino-pretty'"), { code: 'MODULE_NOT_FOUND' });
        },
      }),
    }));
    await import('../../lib/logger.js');
    expect(pinoOptions.transport).toBeUndefined();
  });

  test('production logs JSON', async () => {
    process.env.NODE_ENV = 'production';
    await import('../../lib/logger.js');
    expect(pinoOptions.transport).toBeUndefined();
  });
});
