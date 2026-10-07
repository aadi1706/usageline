// Ramping load test for a laptop-sized kind cluster. Run: k6 run loadtest/k6.js
// Override the target with: k6 run -e BASE_URL=http://localhost:8081 loadtest/k6.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export const options = {
  stages: [
    { duration: '30s', target: 5 },   // warm up
    { duration: '1m', target: 20 },   // ramp
    { duration: '2m', target: 40 },   // sustained peak, long enough for the HPA to react
    { duration: '30s', target: 0 },   // ramp down
  ],
  // Reported as pass/fail at the end; they are checks on this run, not performance claims.
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

export function setup() {
  // Idempotent: reuse the plan if an earlier run already created it.
  const plan = { name: 'loadtest', base_fee_cents: 1000, included_units: 100, unit_price_cents: 5 };
  const res = http.post(`${BASE_URL}/plans`, JSON.stringify(plan), JSON_HEADERS);
  if (res.status === 201) return { planId: res.json('id') };
  const existing = http.get(`${BASE_URL}/plans`).json().find((p) => p.name === 'loadtest');
  return { planId: existing.id };
}

export default function (data) {
  const name = `lt-${__VU}-${__ITER}-${Date.now()}`;

  const tenant = http.post(`${BASE_URL}/tenants`, JSON.stringify({ name, plan_id: data.planId }), JSON_HEADERS);
  check(tenant, { 'tenant created': (r) => r.status === 201 });
  if (tenant.status !== 201) return;
  const tenantId = tenant.json('id');

  for (let i = 0; i < 3; i++) {
    const usage = http.post(
      `${BASE_URL}/tenants/${tenantId}/usage`,
      JSON.stringify({ metric: 'api_calls', quantity: 1 + Math.floor(Math.random() * 100) }),
      JSON_HEADERS,
    );
    check(usage, { 'usage recorded': (r) => r.status === 201 });
  }

  const invoice = http.post(
    `${BASE_URL}/tenants/${tenantId}/invoices`,
    JSON.stringify({ period_start: '2020-01-01T00:00:00Z', period_end: '2100-01-01T00:00:00Z' }),
    JSON_HEADERS,
  );
  check(invoice, { 'invoice generated': (r) => r.status === 201 });
  if (invoice.status !== 201) return;

  const read = http.get(`${BASE_URL}/invoices/${invoice.json('id')}`);
  check(read, { 'invoice read': (r) => r.status === 200 });

  sleep(0.2 + Math.random() * 0.3);
}
