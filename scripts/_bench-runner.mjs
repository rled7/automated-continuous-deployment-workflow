// Bench runner — invoked by scripts/benchmark-app.sh.
// Uses node:http directly for low-overhead timing (vs. spawning curl per request).
import http from 'node:http';

const [, , portStr, requestsStr, concurrencyStr, jsonOutStr] = process.argv;
const PORT = parseInt(portStr, 10);
const REQUESTS = parseInt(requestsStr, 10);
const CONCURRENCY = parseInt(concurrencyStr, 10);
const JSON_OUT = jsonOutStr === '1';

const ENDPOINTS = [
  { method: 'GET',  path: '/health/live' },
  { method: 'GET',  path: '/health/ready' },
  { method: 'GET',  path: '/api/items' },
  { method: 'POST', path: '/api/items', body: { name: 'bench' } },
  { method: 'GET',  path: '/metrics' },
  { method: 'GET',  path: '/openapi.yaml' },
];

function fire(ep) {
  return new Promise((resolve) => {
    const start = process.hrtime.bigint();
    const bodyStr = ep.body ? JSON.stringify(ep.body) : '';
    const opts = {
      host: '127.0.0.1',
      port: PORT,
      path: ep.path,
      method: ep.method,
      headers: ep.body
        ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(bodyStr) }
        : {},
    };
    const req = http.request(opts, (res) => {
      res.on('data', () => {});
      res.on('end', () => {
        const ns = process.hrtime.bigint() - start;
        resolve({ ms: Number(ns) / 1e6, status: res.statusCode });
      });
    });
    req.on('error', () => resolve({ ms: -1, status: 0 }));
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

function pct(arr, p) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length * p) / 100));
  return sorted[idx];
}

async function benchEndpoint(ep) {
  const samples = [];
  let fired = 0;
  let inflight = 0;

  return new Promise((resolveAll) => {
    const tick = () => {
      while (inflight < CONCURRENCY && fired < REQUESTS) {
        inflight++;
        fired++;
        fire(ep).then((r) => {
          samples.push(r);
          inflight--;
          if (samples.length === REQUESTS) {
            resolveAll(samples);
          } else {
            tick();
          }
        });
      }
    };
    tick();
  });
}

const all = [];

for (const ep of ENDPOINTS) {
  const wallStart = process.hrtime.bigint();
  const samples = await benchEndpoint(ep);
  const wallNs = process.hrtime.bigint() - wallStart;

  const ok = samples.filter((s) => s.ms >= 0 && s.status > 0 && s.status < 500);
  const okMs = ok.map((s) => s.ms);
  const errors = samples.length - ok.length;
  const result = {
    method: ep.method,
    path: ep.path,
    requests: samples.length,
    p50: pct(okMs, 50),
    p95: pct(okMs, 95),
    p99: pct(okMs, 99),
    avg: okMs.length ? okMs.reduce((a, b) => a + b, 0) / okMs.length : 0,
    rps: samples.length / (Number(wallNs) / 1e9),
    errors,
  };
  all.push(result);

  if (!JSON_OUT) {
    const label = `${ep.method.padEnd(5)} ${ep.path.padEnd(18)}`;
    console.log(
      `  ${label}  p50=${result.p50.toFixed(1).padStart(5)}ms  ` +
        `p95=${result.p95.toFixed(1).padStart(5)}ms  ` +
        `p99=${result.p99.toFixed(1).padStart(5)}ms  ` +
        `avg=${result.avg.toFixed(1).padStart(5)}ms  ` +
        `${result.rps.toFixed(0).padStart(5)} req/s  ` +
        `errs=${errors}`,
    );
  }
}

if (JSON_OUT) {
  console.log(
    JSON.stringify(
      { timestamp: new Date().toISOString(), concurrency: CONCURRENCY, results: all },
      null,
      2,
    ),
  );
}
