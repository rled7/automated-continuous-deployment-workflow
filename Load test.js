import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────
const errorRate    = new Rate('error_rate');
const responseTime = new Trend('response_time_ms', true);

// ── Test configuration ────────────────────────────────────────────────────────
export const options = {
    stages: [
        { duration: '1m',  target: 10  },   // Ramp up
        { duration: '3m',  target: 50  },   // Sustained load
        { duration: '1m',  target: 100 },   // Spike
        { duration: '2m',  target: 50  },   // Back to normal
        { duration: '1m',  target: 0   },   // Ramp down
    ],
    thresholds: {
        http_req_duration: ['p(95)<500', 'p(99)<1000'],   // 95th pct < 500ms
        http_req_failed:   ['rate<0.01'],                  // <1% error rate
        error_rate:        ['rate<0.01'],
    },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

// ── Test scenarios ────────────────────────────────────────────────────────────
export default function () {
    // Health check
    const healthRes = http.get(`${BASE_URL}/health/ready`);
    check(healthRes, {
        'health status is 200': (r) => r.status === 200,
        'health response < 100ms': (r) => r.timings.duration < 100,
    });
    errorRate.add(healthRes.status !== 200);
    responseTime.add(healthRes.timings.duration);

    sleep(0.5);

    // Main API endpoint
    const apiRes = http.get(`${BASE_URL}/api/items`, {
        headers: { 'Content-Type': 'application/json' },
    });
    check(apiRes, {
        'API status is 200': (r) => r.status === 200,
        'API response < 500ms': (r) => r.timings.duration < 500,
        'API has content': (r) => r.body.length > 0,
    });
    errorRate.add(apiRes.status !== 200);
    responseTime.add(apiRes.timings.duration);

    sleep(1);
}