import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';

// instrumentation.js registers the ESM loader hook (when tracing is on) and
// then loads lib/otel.js. Both are mocked; the test checks the order.
let savedEndpoint;
let calls;

beforeEach(() => {
  savedEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
  delete process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
  calls = [];
  jest.resetModules();
});

afterEach(() => {
  if (savedEndpoint === undefined) delete process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
  else process.env.OTEL_EXPORTER_OTLP_ENDPOINT = savedEndpoint;
});

async function loadInstrumentation(env) {
  Object.assign(process.env, env);
  const register = jest.fn((specifier) => calls.push(['register', specifier]));
  jest.unstable_mockModule('node:module', () => ({ register }));
  jest.unstable_mockModule('../../lib/otel.js', () => {
    calls.push(['otel']);
    return { shutdown: jest.fn() };
  });
  await import('../../instrumentation.js');
  return { register };
}

describe('instrumentation.js', () => {
  test('registers the OpenTelemetry ESM hook, then starts the SDK', async () => {
    const { register } = await loadInstrumentation({
      OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318',
    });
    expect(register).toHaveBeenCalledWith(
      '@opentelemetry/instrumentation/hook.mjs',
      expect.stringMatching(/instrumentation\.js$/),
    );
    expect(calls).toEqual([['register', '@opentelemetry/instrumentation/hook.mjs'], ['otel']]);
  });

  test('registers no hook when tracing is off', async () => {
    const { register } = await loadInstrumentation({});
    expect(register).not.toHaveBeenCalled();
    expect(calls).toEqual([['otel']]);
  });
});
