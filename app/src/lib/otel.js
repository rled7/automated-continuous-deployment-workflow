/**
 * OpenTelemetry SDK initialisation.
 *
 * Loaded by instrumentation.js (`node --import ./dist/instrumentation.js
 * dist/server.js`) after it registers the ESM loader hook, so the
 * instrumentations patch libraries (express, ioredis, pg, …) that the app
 * imports as ES modules. server.js imports it too: started without --import,
 * the SDK still runs, but only libraries loaded through require() are patched.
 *
 * Environment variables:
 *   OTEL_EXPORTER_OTLP_ENDPOINT  — full URL of the OTLP/HTTP collector endpoint,
 *                                   e.g. http://otel-collector:4318
 *                                   If unset the SDK is NOT initialised (no-op).
 *   OTEL_SERVICE_NAME            — service name sent in every span (default: my-app)
 */

import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

let sdk = null;

if (!endpoint) {
  console.log('OTel disabled — set OTEL_EXPORTER_OTLP_ENDPOINT to enable');
} else {
  const serviceName = process.env.OTEL_SERVICE_NAME || 'my-app';
  const serviceVersion = process.env.npm_package_version || 'unknown';

  sdk = new NodeSDK({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: serviceName,
      [ATTR_SERVICE_VERSION]: serviceVersion,
    }),
    traceExporter: new OTLPTraceExporter({
      url: `${endpoint}/v1/traces`,
    }),
    instrumentations: [
      getNodeAutoInstrumentations({
        // Disable noisy fs instrumentation that fires on every require()
        '@opentelemetry/instrumentation-fs': { enabled: false },
      }),
    ],
  });

  sdk.start();
}

/**
 * Flush pending spans and stop the SDK. server.js calls this at the end of
 * its graceful shutdown, so spans from draining requests are exported too.
 * Never rejects; a failed flush is logged. Gives up after timeoutMs: an
 * unreachable collector would otherwise hold the pod's termination for the
 * exporter's retries.
 * @param {number} timeoutMs — default 5000 ms
 * @returns {Promise<void>}
 */
export async function shutdown(timeoutMs = 5_000) {
  if (!sdk) return;
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${timeoutMs} ms`)), timeoutMs);
  });
  try {
    await Promise.race([sdk.shutdown(), timeout]);
  } catch (err) {
    console.error('OTel SDK shutdown error:', err);
  } finally {
    clearTimeout(timer);
  }
}
