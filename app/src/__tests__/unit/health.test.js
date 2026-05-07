import { describe, test, expect, beforeEach } from '@jest/globals';
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
