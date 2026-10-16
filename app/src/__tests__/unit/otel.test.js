import { jest, describe, test, expect, beforeEach, afterEach } from '@jest/globals';

// lib/otel.js starts the OpenTelemetry SDK when it is imported, if
// OTEL_EXPORTER_OTLP_ENDPOINT is set. Each test mocks the SDK and imports a
// fresh copy; process.on is stubbed to check that no signal handlers are added.

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
  const resourceFromAttributes = jest.fn((attributes) => ({ attributes }));
  const getNodeAutoInstrumentations = jest.fn((config) => ({ config }));
  jest.unstable_mockModule('@opentelemetry/sdk-node', () => ({ NodeSDK: FakeNodeSDK }));
  jest.unstable_mockModule('@opentelemetry/exporter-trace-otlp-http', () => ({ OTLPTraceExporter: FakeExporter }));
  jest.unstable_mockModule('@opentelemetry/resources', () => ({ resourceFromAttributes }));
  jest.unstable_mockModule('@opentelemetry/auto-instrumentations-node', () => ({ getNodeAutoInstrumentations }));
  const otel = await import('../../lib/otel.js');
  return { otel, sdks, getNodeAutoInstrumentations };
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

  test('adds no signal handlers: server.js flushes at the end of its shutdown', async () => {
    const { sdks } = await loadOtel({ OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' });
    expect(onSpy).not.toHaveBeenCalled();
    expect(sdks[0].shutdown).not.toHaveBeenCalled();
  });

  test('shutdown() flushes and stops the SDK', async () => {
    const { otel, sdks } = await loadOtel({ OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' });
    await expect(otel.shutdown()).resolves.toBeUndefined();
    expect(sdks[0].shutdown).toHaveBeenCalledTimes(1);
  });

  test('shutdown() is a no-op when the SDK is off', async () => {
    const { otel } = await loadOtel({});
    await expect(otel.shutdown()).resolves.toBeUndefined();
  });

  test('shutdown() logs a failed flush instead of rejecting', async () => {
    const err = new Error('collector unreachable');
    const { otel } = await loadOtel(
      { OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' },
      () => Promise.reject(err),
    );
    await expect(otel.shutdown()).resolves.toBeUndefined();
    expect(console.error).toHaveBeenCalledWith('OTel SDK shutdown error:', err);
  });

  test('shutdown() gives up on a flush that does not finish in time', async () => {
    const { otel } = await loadOtel(
      { OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4318' },
      () => new Promise(() => {}),
    );
    await expect(otel.shutdown(10)).resolves.toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(
      'OTel SDK shutdown error:',
      expect.objectContaining({ message: 'timed out after 10 ms' }),
    );
  });
});
