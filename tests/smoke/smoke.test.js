import axios from 'axios';

const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const client   = axios.create({ baseURL: BASE_URL, timeout: 10_000 });

describe('Smoke Tests — Post Deploy', () => {

    // ── Health ──────────────────────────────────────────────────────────────
    describe('Health Endpoints', () => {
        test('GET /health/live returns 200', async () => {
            const res = await client.get('/health/live');
            expect(res.status).toBe(200);
            expect(res.data.status).toBe('alive');
        });

        test('GET /health/ready returns 200 with all checks passing', async () => {
            const res = await client.get('/health/ready');
            expect(res.status).toBe(200);
            expect(res.data.status).toBe('ready');
            expect(res.data.checks.database).toBe('ok');
        });
    });

    // ── Core API ────────────────────────────────────────────────────────────
    describe('Core API', () => {
        test('GET /api/items returns 200', async () => {
            const res = await client.get('/api/items');
            expect(res.status).toBe(200);
            expect(Array.isArray(res.data)).toBe(true);
        });

        test('POST /api/items creates resource', async () => {
            const res = await client.post('/api/items', { name: 'smoke-test-item' });
            expect(res.status).toBe(201);
            expect(res.data.id).toBeDefined();
        });
    });

    // ── Performance ─────────────────────────────────────────────────────────
    describe('Response Time SLA', () => {
        test('Health endpoint responds under 200ms', async () => {
            const start = Date.now();
            await client.get('/health/live');
            expect(Date.now() - start).toBeLessThan(200);
        });

        test('API endpoint responds under 500ms', async () => {
            const start = Date.now();
            await client.get('/api/items');
            expect(Date.now() - start).toBeLessThan(500);
        });
    });

});