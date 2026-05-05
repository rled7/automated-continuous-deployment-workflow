import { describe, test, expect, beforeAll, afterAll } from '@jest/globals';
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
});
