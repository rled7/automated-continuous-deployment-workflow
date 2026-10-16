import { describe, test, expect } from '@jest/globals';
import express from 'express';
import request from 'supertest';

import requestIdMiddleware from '../../middleware/requestId.js';

// UUID v4 pattern
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function buildApp() {
  const app = express();
  app.use(requestIdMiddleware);
  // Echo req.id back so we can assert on it
  app.get('/test', (req, res) => {
    res.json({ id: req.id });
  });
  return app;
}

describe('requestId middleware', () => {
  test('passes through x-request-id header when present', async () => {
    const app = buildApp();
    const res = await request(app)
      .get('/test')
      .set('x-request-id', 'my-custom-id');

    expect(res.status).toBe(200);
    expect(res.body.id).toBe('my-custom-id');
    expect(res.headers['x-request-id']).toBe('my-custom-id');
  });

  test('generates a UUID when x-request-id header is absent', async () => {
    const app = buildApp();
    const res = await request(app).get('/test');

    expect(res.status).toBe(200);
    expect(res.body.id).toMatch(UUID_RE);
    expect(res.headers['x-request-id']).toMatch(UUID_RE);
  });

  test('sets req.id on the request object', async () => {
    const app = buildApp();
    const res = await request(app)
      .get('/test')
      .set('x-request-id', 'req-id-check');

    expect(res.body.id).toBe('req-id-check');
  });

  test('echoes generated UUID in response header', async () => {
    const app = buildApp();
    const res = await request(app).get('/test');
    // req.id and response header must match
    expect(res.body.id).toBe(res.headers['x-request-id']);
  });

  test('accepts a client UUID and IDs of letters, digits, dot, underscore, hyphen', async () => {
    const app = buildApp();
    for (const id of ['3f0e6b9a-6c1d-4c2e-9b7a-1d2e3f4a5b6c', 'trace_01.A-b', 'x'.repeat(64)]) {
      const res = await request(app).get('/test').set('x-request-id', id);
      expect(res.body.id).toBe(id);
    }
  });

  test.each([
    ['too long', 'x'.repeat(65)],
    ['spaces', 'two words'],
    ['log-forging characters', 'id","level":60,"msg":"forged'],
    ['markup', '<script>alert(1)</script>'],
  ])('replaces an ID with %s by a generated UUID', async (_, id) => {
    const app = buildApp();
    const res = await request(app).get('/test').set('x-request-id', id);
    expect(res.body.id).toMatch(UUID_RE);
    expect(res.headers['x-request-id']).toBe(res.body.id);
  });
});
