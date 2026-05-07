// @ts-check
import { test, expect } from '@playwright/test';

/**
 * E2E error-case tests — Build 020.
 *
 * Validates that the API returns well-structured error responses for invalid
 * inputs and unknown routes.  The structured error shape expected is:
 *   { error: { message: string, requestId: string } }
 *
 * Runs against BASE_URL (default http://localhost:3000).
 */
test.describe('E2E Error Cases — invalid inputs and unknown routes', () => {

    test('POST /api/items with empty body returns 400 with structured error', async ({ request }) => {
        const response = await request.post('/api/items', {
            data: {},
        });
        expect(response.status()).toBe(400);

        const body = await response.json();
        expect(body).toHaveProperty('error');
        expect(body.error).toHaveProperty('message');
        expect(body.error).toHaveProperty('requestId');
    });

    test('POST /api/items with name >100 chars returns 400', async ({ request }) => {
        const longName = 'x'.repeat(101);

        const response = await request.post('/api/items', {
            data: { name: longName },
        });
        expect(response.status()).toBe(400);

        const body = await response.json();
        expect(body).toHaveProperty('error');
        expect(body.error).toHaveProperty('message');
    });

    test('GET /api/nonexistent returns 404', async ({ request }) => {
        const response = await request.get('/api/nonexistent');
        expect(response.status()).toBe(404);
    });

});
