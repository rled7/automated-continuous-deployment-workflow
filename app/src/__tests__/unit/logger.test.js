import { jest, describe, test, expect, beforeEach } from '@jest/globals';
import express from 'express';
import pinoHttp from 'pino-http';
import request from 'supertest';

// lib/logger.js with pino writing to an array instead of stdout, so the tests
// can read what a request log line contains.
const { default: realPino } = await import('pino');
let lines;

beforeEach(() => {
  lines = [];
  jest.resetModules();
  jest.unstable_mockModule('pino', () => ({
    default: (options) => realPino(options, { write: (line) => lines.push(line) }),
  }));
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
