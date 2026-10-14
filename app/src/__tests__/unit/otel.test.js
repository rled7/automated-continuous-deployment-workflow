import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';

// lib/otel.js starts the OpenTelemetry SDK when it is imported, if
// OTEL_EXPORTER_OTLP_ENDPOINT is set. Each test mocks the SDK and imports a
// fresh copy; process.on is stubbed so no real signal handlers stay behind.

const ENV_KEYS = ['OTEL_EXPORTER_OTLP_ENDPOINT', 'OTEL_SERVICE_NAME'];
let savedEnv;
let onSpy;
let signalHandlers;

beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  signalHandlers = {};
  onSpy = jest.spyOn(process, 'on').mockImplementation((event, handler) => {
    signalHandlers[event] = handler;
    return process;
  });
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
  jest.resetModules();
});

afterEach(() => {
  jest.restoreAllMocks();
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

async function loadOtel(env, shutdown = () => Promise.resolve()) {
  Object.assign(process.env, env);
  const sdks = [];
  class FakeNodeSDK {
    constructor(config) {
      this.config = config;
      this.start = jest.fn();
      this.shutdown = jest.fn(shutdown);
      sdks.push(this);
    }
  }
  class FakeExporter {
    constructor(options) { this.options = options; }
  }
  class FakeResource {
    constructor(attributes) { this.attributes = attributes; }
  }
  const getNodeAutoInstrumentations = jest.fn((config) => ({ config }));
  jest.unstable_mockModule('@opentelemetry/sdk-node', () => ({ NodeSDK: FakeNodeSDK }));
  jest.unstable_mockModule('@opentelemetry/exporter-trace-otlp-http', () => ({ OTLPTraceExporter: FakeExporter }));
  jest.unstable_mockModule('@opentelemetry/resources', () => ({ Resource: FakeResource }));
  jest.unstable_mockModule('@opentelemetry/auto-instrumentations-node', () => ({ getNodeAutoInstrumentations }));
  await import('../../lib/otel.js');
  return { sdks, getNodeAutoInstrumentations };
}

describe('lib/otel.js', () => {
  test('stays off without OTEL_EXPORTER_OTLP_ENDPOINT', async () => {
    const { sdks } = await loadOtel({});
    expect(sdks).toHaveLength(0);
    expect(console.log).toHaveBeenCalledWith(expect.stringContaining('OTel disabled'));
    expect(onSpy).not.toHaveBeenCalled();
  });

  test('starts the SDK, exporting traces to <endpoint>/v1/traces', async () => {
    const { sdks, getNodeAutoInstrumentations } = await loadOtel({
      OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318',
      OTEL_SERVICE_NAME: 'checkout',
    });
    expect(sdks).toHaveLength(1);
    const [sdk] = sdks;
    expect(sdk.start).toHaveBeenCalled();
    expect(sdk.config.traceExporter.options).toEqual({ url: 'http://otel-collector:4318/v1/traces' });
    expect(Object.values(sdk.config.resource.attributes)).toContain('checkout');
    // fs instrumentation fires on every require(); it stays off.
    expect(getNodeAutoInstrumentations).toHaveBeenCalledWith({
      '@opentelemetry/instrumentation-fs': { enabled: false },
    });
  });

  test('defaults the service name to my-app', async () => {
    const { sdks } = await loadOtel({ OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' });
    expect(Object.values(sdks[0].config.resource.attributes)).toContain('my-app');
  });

  test('flushes spans on SIGTERM and SIGINT', async () => {
    const { sdks } = await loadOtel({ OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' });
    expect(Object.keys(signalHandlers).sort()).toEqual(['SIGINT', 'SIGTERM']);
    signalHandlers.SIGTERM();
    expect(sdks[0].shutdown).toHaveBeenCalledTimes(1);
    signalHandlers.SIGINT();
    expect(sdks[0].shutdown).toHaveBeenCalledTimes(2);
  });

  test('logs a failed flush instead of throwing', async () => {
    const err = new Error('collector unreachable');
    const { sdks } = await loadOtel(
      { OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' },
      () => Promise.reject(err),
    );
    signalHandlers.SIGTERM();
    await sdks[0].shutdown.mock.results[0].value.catch(() => {});
    await new Promise((resolve) => setImmediate(resolve));
    expect(console.error).toHaveBeenCalledWith('OTel SDK shutdown error:', err);
  });
});
