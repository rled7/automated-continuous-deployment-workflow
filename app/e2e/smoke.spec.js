// @ts-check
import { test, expect } from '@playwright/test';

/**
 * E2E smoke tests — Build 020.
 *
 * Validates that the three core liveness indicators are reachable after
 * deployment.  These are intentionally thin: they confirm the service is
 * up and responding with correct content types, not business-logic
 * correctness (that belongs in happy-path.spec.js and error-cases.spec.js).
 *
 * Runs against BASE_URL (default http://localhost:3000).
 */
test.describe('E2E Smoke — core endpoints', () => {

    test('GET /health/live returns 200', async ({ request }) => {
        const response = await request.get('/health/live');
        expect(response.status()).toBe(200);
    });

    test('GET /health/ready returns 200', async ({ request }) => {
        const response = await request.get('/health/ready');
        expect(response.status()).toBe(200);
    });

    test('GET /api/items returns an array', async ({ request }) => {
        const response = await request.get('/api/items');
        expect(response.status()).toBe(200);
        const body = await response.json();
        expect(Array.isArray(body)).toBe(true);
    });

});
