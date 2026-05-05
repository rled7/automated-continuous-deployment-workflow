import { describe, test, expect } from '@jest/globals';
import express from 'express';
import request from 'supertest';
import { ZodError, z } from 'zod';

import requestIdMiddleware from '../../middleware/requestId.js';
import errorHandler from '../../middleware/error.js';

function buildApp(routeHandler) {
  const app = express();
  app.use(express.json());
  app.use(requestIdMiddleware);
  app.get('/test', routeHandler);
  app.use(errorHandler);
  return app;
}

describe('errorHandler middleware', () => {
  test('returns 400 for ZodError with message "Validation failed"', async () => {
    const schema = z.object({ name: z.string().min(1) });

    const app = buildApp((req, res, next) => {
      try {
        schema.parse({});
      } catch (err) {
        next(err);
      }
    });

    const res = await request(app).get('/test');
    expect(res.status).toBe(400);
    expect(res.body.error.message).toBe('Validation failed');
    expect(Array.isArray(res.body.error.issues)).toBe(true);
  });

  test('returns 400 and includes requestId in response for ZodError', async () => {
    const schema = z.object({ name: z.string().min(1) });

    const app = buildApp((req, res, next) => {
      try {
        schema.parse({});
      } catch (err) {
        next(err);
      }
    });

    const res = await request(app)
      .get('/test')
      .set('x-request-id', 'zod-test-id');

    expect(res.status).toBe(400);
    expect(res.body.error.requestId).toBe('zod-test-id');
  });

  test('preserves err.statusCode when set', async () => {
    const app = buildApp((req, res, next) => {
      const err = new Error('Not Found');
      err.statusCode = 404;
      next(err);
    });

    const res = await request(app).get('/test');
    expect(res.status).toBe(404);
    expect(res.body.error.message).toBe('Not Found');
  });

  test('falls back to 500 when no statusCode', async () => {
    const app = buildApp((req, res, next) => {
      next(new Error('Unexpected'));
    });

    const res = await request(app).get('/test');
    expect(res.status).toBe(500);
    expect(res.body.error.message).toBe('Unexpected');
  });

  test('response shape includes error.message and error.requestId', async () => {
    const app = buildApp((req, res, next) => {
      const err = new Error('Something broke');
      err.statusCode = 503;
      next(err);
    });

    const res = await request(app)
      .get('/test')
      .set('x-request-id', 'shape-check');

    expect(res.status).toBe(503);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error).toHaveProperty('message');
    expect(res.body.error).toHaveProperty('requestId', 'shape-check');
  });
});
