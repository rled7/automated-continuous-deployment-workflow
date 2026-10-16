import { jest, describe, test, expect } from '@jest/globals';
import express from 'express';
import request from 'supertest';
import { z } from 'zod';

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

  test('falls back to 500 when no statusCode, without the error message', async () => {
    const app = buildApp((req, res, next) => {
      next(new Error('connect ECONNREFUSED 10.0.0.12:5432'));
    });

    const res = await request(app).get('/test').set('x-request-id', 'err-500');
    expect(res.status).toBe(500);
    expect(res.body).toEqual({
      error: { message: 'Internal Server Error', requestId: 'err-500' },
    });
  });

  test('logs the real error for a 5xx', async () => {
    const { default: logger } = await import('../../lib/logger.js');
    const spy = jest.spyOn(logger, 'error').mockImplementation(() => {});
    const err = new Error('relation "items" does not exist');
    const app = buildApp((req, res, next) => next(err));

    await request(app).get('/test').set('x-request-id', 'logged');
    expect(spy).toHaveBeenCalledWith({ requestId: 'logged', err, status: 500 }, 'Request error');
    spy.mockRestore();
  });

  test('a 4xx without a message gets the status text', async () => {
    const app = buildApp((req, res, next) => {
      const err = new Error();
      err.statusCode = 409;
      next(err);
    });

    const res = await request(app).get('/test');
    expect(res.status).toBe(409);
    expect(res.body.error.message).toBe('Conflict');
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
    expect(res.body.error).toHaveProperty('message', 'Internal Server Error');
    expect(res.body.error).toHaveProperty('requestId', 'shape-check');
  });
});
