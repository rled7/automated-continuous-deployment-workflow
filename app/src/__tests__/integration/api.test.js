/**
 * Integration tests for the Express API.
 *
 * DB strategy — DB_FAKE escape hatch
 * ─────────────────────────────────────
 * Using `jest.unstable_mockModule` + pg-mem with ESM Jest proved intractable:
 * pg-mem's `newDb().adapters.createPg()` returns a CommonJS-style object that
 * conflicts with the top-level `import pg from 'pg'` in lib/db.js when Jest
 * transforms ESM modules via experimental-vm-modules.  The module graph is
 * evaluated before mocks can be injected, causing the real pg.Pool constructor
 * to run (and fail to connect) before the fake adapter is swapped in.
 *
 * Fallback choice: DB_FAKE=1 env flag in lib/db.js.
 * When set, lib/db.js uses a minimal in-memory store instead of pg.Pool.
 * This is set via jest.config.js testEnvironmentOptions → process.env, or via
 * the explicit `process.env.DB_FAKE = '1'` below.
 *
 * This keeps ESM-native Jest working without hoisting or unstable APIs, and
 * ensures the integration tests remain a valid signal for API contract testing.
 */

// DB_FAKE=1 and REDIS_FAKE=1 are set in src/__tests__/integration/setup.js,
// which Jest's `setupFiles` runs in the worker BEFORE any module is loaded.
// Do NOT set process.env here — ESM imports are hoisted and modules are
// cached before user-level code at the top of this file runs.

import { describe, test, expect } from '@jest/globals';
import request from 'supertest';

// Import the app (no server started — server.js only calls start() when run directly)
import { app } from '../../server.js';

describe('Integration — Express app', () => {
  describe('GET /api/items', () => {
    test('returns 200 with an array', async () => {
      const res = await request(app).get('/api/items');
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body)).toBe(true);
    });
  });

  describe('POST /api/items', () => {
    test('returns 201 with valid body', async () => {
      const res = await request(app)
        .post('/api/items')
        .send({ name: 'test-item' });
      expect(res.status).toBe(201);
      expect(res.body).toMatchObject({ name: 'test-item' });
      expect(res.body.id).toBeDefined();
    });

    test('returns 400 with missing name', async () => {
      const res = await request(app)
        .post('/api/items')
        .send({});
      expect(res.status).toBe(400);
      expect(res.body.error.message).toBe('Validation failed');
    });

    test('returns 400 with empty name string', async () => {
      const res = await request(app)
        .post('/api/items')
        .send({ name: '' });
      expect(res.status).toBe(400);
      expect(res.body.error.message).toBe('Validation failed');
    });
  });

  describe('GET /metrics', () => {
    test('returns 200 with prometheus content-type', async () => {
      const res = await request(app).get('/metrics');
      expect(res.status).toBe(200);
      // prom-client sets content-type like: text/plain; version=0.0.4; charset=utf-8
      expect(res.headers['content-type']).toMatch(/^text\/plain.*version=0\.0\.4/);
    });
  });

  describe('GET /health/live', () => {
    test('returns 200', async () => {
      const res = await request(app).get('/health/live');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('alive');
    });
  });

  describe('GET /openapi.yaml', () => {
    test('returns 200 with application/yaml and an OpenAPI 3 spec', async () => {
      const res = await request(app).get('/openapi.yaml');
      expect(res.status).toBe(200);
      expect(res.headers['content-type']).toMatch(/^application\/yaml/);
      expect(res.text).toMatch(/^openapi: 3\.0\.\d/);
      expect(res.text).toContain('title: my-app API');
      expect(res.text).toContain('/api/items');
      expect(res.text).toContain('/health/live');
      expect(res.text).toContain('/health/ready');
      expect(res.text).toContain('/metrics');
    });
  });
});
