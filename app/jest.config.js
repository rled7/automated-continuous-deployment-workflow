/** @type {import('jest').Config} */
const config = {
  // Use experimental VM modules for native ESM support
  testEnvironment: 'node',
  transform: {},

  // Match test files under src/__tests__/
  testMatch: ['**/src/__tests__/**/*.test.js'],

  // Coverage settings
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
