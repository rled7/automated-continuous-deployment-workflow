// @ts-check
import { test, expect } from '@playwright/test';

/**
 * E2E happy-path tests — Build 020.
 *
 * Exercises the create-then-read flow for items.  The test creates an item
 * with a unique name (timestamped to avoid collisions across parallel runs),
 * then reads the full list and confirms the new item appears.
 *
 * Runs against BASE_URL (default http://localhost:3000).
 */
test.describe('E2E Happy Path — create and retrieve items', () => {

    test('POST /api/items creates a new item that appears in GET /api/items', async ({ request }) => {
        // Use a unique name so the assertion is unambiguous across runs
        const itemName = `e2e-item-${Date.now()}`;

        // Create the item
        const createResponse = await request.post('/api/items', {
            data: { name: itemName },
        });
        expect(createResponse.status()).toBe(201);

        const created = await createResponse.json();
        expect(created).toHaveProperty('id');
        expect(created.name).toBe(itemName);

        // Retrieve the full list and confirm the item is present
        const listResponse = await request.get('/api/items');
        expect(listResponse.status()).toBe(200);

        const items = await listResponse.json();
        expect(Array.isArray(items)).toBe(true);

        const found = items.some((item) => item.name === itemName);
        expect(found).toBe(true);
    });

});
