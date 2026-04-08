/**
 * ForgeOps — k6 Load Test for node-api
 *
 * Simulates realistic user traffic:
 *   - Health checks
 *   - List items (read-heavy)
 *   - Create items (write)
 *   - Fetch individual items
 *
 * Usage:
 *   k6 run --vus 10 --duration 30s --env BASE_URL=http://localhost:3000 k6/load-test.js
 */

import http   from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────
const errorRate    = new Rate('custom_error_rate');
const createTrend  = new Trend('create_item_duration', true);
const itemsCreated = new Counter('items_created_total');

// ── k6 options ────────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '10s', target: 5  },   // Ramp up
    { duration: '20s', target: 10 },   // Sustain
    { duration: '5s',  target: 0  },   // Ramp down
  ],
  thresholds: {
    http_req_duration:         ['p(95)<500', 'p(99)<1000'],  // Latency SLO
    http_req_failed:           ['rate<0.01'],                 // < 1% error rate
    custom_error_rate:         ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

// ── Default scenario (virtual user behaviour) ─────────────────────────────────
export default function () {
  const headers = { 'Content-Type': 'application/json' };

  // ── 1. Health check ────────────────────────────────────────────────────────
  group('health', () => {
    const res = http.get(`${BASE_URL}/health`);
    const ok  = check(res, {
      'health status 200': r => r.status === 200,
      'health body ok':    r => r.json('status') === 'ok',
    });
    errorRate.add(!ok);
  });

  sleep(0.5);

  // ── 2. List items ──────────────────────────────────────────────────────────
  group('list items', () => {
    const res = http.get(`${BASE_URL}/items`);
    const ok  = check(res, {
      'list status 200':  r => r.status === 200,
      'list has items':   r => Array.isArray(r.json('items')),
    });
    errorRate.add(!ok);
  });

  sleep(0.3);

  // ── 3. Create item ─────────────────────────────────────────────────────────
  group('create item', () => {
    const payload = JSON.stringify({ name: `load-test-item-${Date.now()}` });
    const start   = Date.now();
    const res     = http.post(`${BASE_URL}/items`, payload, { headers });
    createTrend.add(Date.now() - start);

    const ok = check(res, {
      'create status 201': r => r.status === 201,
      'create has id':     r => typeof r.json('id') === 'number',
    });

    if (ok) { itemsCreated.add(1); }
    errorRate.add(!ok);
  });

  sleep(0.5);
}

// ── Setup: verify the server is alive before the test ─────────────────────────
export function setup() {
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) {
    throw new Error(`Server not available at ${BASE_URL}/health (HTTP ${res.status})`);
  }
  console.log(`✅ Server is up: ${BASE_URL}`);
  return { baseUrl: BASE_URL };
}

// ── Teardown: print summary ───────────────────────────────────────────────────
export function teardown(data) {
  console.log(`✅ Load test complete against ${data.baseUrl}`);
}
