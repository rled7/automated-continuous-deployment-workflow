/**
 * Jest setup file for unit tests.
 *
 * Runs in the worker process BEFORE any test module is imported.
 * Sets DB_FAKE=1 and REDIS_FAKE=1 so that lib/db.js and lib/redis.js
 * return 'ok' from their healthCheck() functions without needing real
 * infrastructure — this allows health.test.js to exercise the router
 * logic in isolation.
 *
 * See app/src/__tests__/integration/setup.js for the integration counterpart.
 */
process.env.DB_FAKE    = '1';
process.env.REDIS_FAKE = '1';
