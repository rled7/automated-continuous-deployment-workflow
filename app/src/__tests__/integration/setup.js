/**
 * Jest setup file for integration tests.
 *
 * Runs in the worker process BEFORE any test module is imported.
 * Setting DB_FAKE=1 here ensures lib/db.js sees the flag when its ESM
 * module is first evaluated (ESM modules are cached after first load;
 * setting env vars at the top of a test file is too late because imports
 * are hoisted and evaluated before user code runs).
 *
 * This file is referenced in jest.config.js via `setupFiles` for the
 * integration test project.
 */

// Enable the in-memory fake DB store for all integration tests.
// See app/src/lib/db.js for implementation details and rationale.
process.env.DB_FAKE = '1';

// Enable the Redis fake so healthCheck() returns 'ok' without a real server.
// Same rationale as DB_FAKE: lazyConnect ioredis would fail on first ping()
// because no Redis is available in the Jest worker environment.
process.env.REDIS_FAKE = '1';

// Remove REDIS_URL to ensure no real ioredis client is created.
delete process.env.REDIS_URL;
