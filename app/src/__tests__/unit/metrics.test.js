import { describe, test, expect, beforeEach } from '@jest/globals';
import express from 'express';
import request from 'supertest';

import metricsMiddleware from '../../middleware/metrics.js';
import { httpRequestDurationMicroseconds } from '../../lib/metrics.js';

function buildApp() {
  const app = express();
  app.use(metricsMiddleware);
  const router = express.Router();
  router.get('/ready', (req, res) => res.json({ ok: true }));
  app.use('/health', router);
  app.get('/api/items/:id', (req, res) => res.json({ id: req.params.id }));
  return app;
}

// Route labels recorded in the histogram so far.
async function routeLabels() {
  const { values } = await httpRequestDurationMicroseconds.get();
  return [...new Set(values.map((v) => v.labels.route).filter(Boolean))].sort();
}

describe('metrics middleware', () => {
  beforeEach(() => {
    httpRequestDurationMicroseconds.reset();
  });

  test('labels a router route with its mount path', async () => {
    await request(buildApp()).get('/health/ready');
    expect(await routeLabels()).toEqual(['/health/ready']);
  });

  test('labels a parameterised route with its pattern, not the path', async () => {
    const app = buildApp();
    await request(app).get('/api/items/1');
    await request(app).get('/api/items/2');
    expect(await routeLabels()).toEqual(['/api/items/:id']);
  });

  test('labels every unmatched path "unmatched"', async () => {
    const app = buildApp();
    await request(app).get('/does-not-exist');
    await request(app).get('/wp-admin/setup.php');
    expect(await routeLabels()).toEqual(['unmatched']);
  });
});
