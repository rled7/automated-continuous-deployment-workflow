/** @type {import('jest').Config} */
const config = {
  // Use experimental VM modules for native ESM support
  testEnvironment: 'node',
  transform: {},

  // Build 017: split into two projects so integration tests get their own
  // setupFiles (DB_FAKE=1) without affecting unit tests.
  //
  // With ESM + --experimental-vm-modules, `import` statements are hoisted and
  // modules are cached before user code at the top of a test file runs.
  // `setupFiles` entries run synchronously in the worker before the module
  // registry is populated — this is the correct hook for setting env vars that
  // modules read at evaluation time.
  projects: [
    {
      displayName: 'unit',
      testEnvironment: 'node',
      transform: {},
      testMatch: ['<rootDir>/src/__tests__/unit/**/*.test.js'],
      testPathIgnorePatterns: ['/node_modules/', '/dist/'],
      // Unit tests do NOT set DB_FAKE; health.test.js expects both DB and Redis
      // to be "ok" — with no env vars set, lib/db.js and lib/redis.js are in
      // "not configured" mode, but health.js catches rejections via allSettled
      // and returns { ok: false }.  The health unit test expects 200 (all ok).
      //
      // To satisfy that, unit tests need the same DB_FAKE flag so dbHealthCheck
      // returns 'ok', plus a fake REDIS_URL so redis.js creates a client.
      // We use a separate setup file to keep unit and integration configs clean.
      setupFiles: ['<rootDir>/src/__tests__/unit/setup.js'],
    },
    {
      displayName: 'integration',
      testEnvironment: 'node',
      transform: {},
      testMatch: ['<rootDir>/src/__tests__/integration/**/*.test.js'],
      testPathIgnorePatterns: ['/node_modules/', '/dist/'],
      // Integration setup sets DB_FAKE=1 and removes REDIS_URL before modules load.
      setupFiles: ['<rootDir>/src/__tests__/integration/setup.js'],
    },
  ],

  // Coverage settings (applied when --coverage is passed to the root config)
  collectCoverageFrom: ['src/**/*.js', '!src/**/__tests__/**'],
  coverageReporters: ['text', 'cobertura'],
  coverageThreshold: {
    global: {
      lines: 80,
      branches: 70,
      functions: 60,
    },
  },
};

export default config;
