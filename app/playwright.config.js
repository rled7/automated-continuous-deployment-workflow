// @ts-check
import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright E2E configuration — Build 020.
 *
 * Test dir:  app/e2e/
 * Runner:    Chromium only (firefox/webkit skipped for CI speed)
 * baseURL:   BASE_URL env var (defaults to http://localhost:3000 for local dev)
 *
 * Air-gapped note: `playwright install --with-deps chromium` calls apt.
 * For air-gapped environments, bake the browser into the custom agent image
 * (add `RUN npx playwright install --with-deps chromium` to docker/jenkins-agent/Dockerfile).
 */
export default defineConfig({
    testDir: './e2e',

    // Retry once on failure — flaky network in CI can cause false positives
    retries: 1,

    // Per-test timeout of 30 seconds
    timeout: 30_000,

    // Reporters: human-readable list + JUnit XML for Jenkins junit() step
    reporter: [
        ['list'],
        ['junit', { outputFile: 'reports/junit-e2e.xml' }],
    ],

    use: {
        // Target environment; override via BASE_URL env var in CI
        baseURL: process.env.BASE_URL || 'http://localhost:3000',

        // Capture traces on retry for debugging
        trace: 'on-first-retry',
    },

    projects: [
        {
            name: 'chromium',
            use: { ...devices['Desktop Chrome'] },
        },
        // firefox and webkit are intentionally omitted to keep CI fast.
        // Add them when cross-browser coverage becomes a requirement.
    ],
});
