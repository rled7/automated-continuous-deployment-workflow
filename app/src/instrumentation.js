/**
 * Preloaded with `node --import ./dist/instrumentation.js dist/server.js`.
 *
 * ES module imports bypass the require() hooks OpenTelemetry instruments
 * libraries with, so express, ioredis and the rest would not be traced. The
 * loader hook registered here wraps them as they are imported; it is only
 * registered when tracing is on. The SDK is then started by lib/otel.js,
 * before server.js imports anything.
 */

import { register } from 'node:module';

if (process.env.OTEL_EXPORTER_OTLP_ENDPOINT) {
  register('@opentelemetry/instrumentation/hook.mjs', import.meta.url);
}

await import('./lib/otel.js');
