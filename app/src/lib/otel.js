/**
 * OpenTelemetry SDK initialisation.
 *
 * This module MUST be imported as the very first statement in server.js so that
 * auto-instrumentation patches libraries (express, http, pino, …) before they
 * are loaded by anything else.
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
import { Resource } from '@opentelemetry/resources';
import { SEMRESATTRS_SERVICE_NAME, SEMRESATTRS_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;

if (!endpoint) {
  console.log('OTel disabled — set OTEL_EXPORTER_OTLP_ENDPOINT to enable');
} else {
  const serviceName = process.env.OTEL_SERVICE_NAME || 'my-app';
  const serviceVersion = process.env.npm_package_version || 'unknown';

  const sdk = new NodeSDK({
    resource: new Resource({
      [SEMRESATTRS_SERVICE_NAME]: serviceName,
      [SEMRESATTRS_SERVICE_VERSION]: serviceVersion,
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

  // Graceful shutdown — flush pending spans before process exits.
  // Do NOT call process.exit() here; server.js's own SIGTERM/SIGINT
  // handler is responsible for that.
  const shutdown = () => {
    sdk.shutdown().catch((err) => {
      console.error('OTel SDK shutdown error:', err);
    });
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
