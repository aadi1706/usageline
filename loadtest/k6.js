// Ramping load test for a laptop-sized kind cluster. Run: k6 run loadtest/k6.js
// Override the target with: k6 run -e BASE_URL=http://localhost:8081 loadtest/k6.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8081';
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

// URLs contain generated IDs. Without a `name` tag k6 would create one metric series per distinct URL
// (high cardinality), so every request is grouped under a fixed template name.
const params = (name) => ({ ...JSON_HEADERS, tags: { name } });

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
  // Look the plan up first: POSTing an existing name returns 409, which k6 would count as a failed request.
  const plan = { name: 'loadtest', base_fee_cents: 1000, included_units: 100, unit_price_cents: 5 };
  const plans = http.get(`${BASE_URL}/plans`, { tags: { name: 'GET /plans' } }).json();
  const existing = plans.find((p) => p.name === plan.name);
  if (existing) return { planId: existing.id };
  return { planId: http.post(`${BASE_URL}/plans`, JSON.stringify(plan), params('POST /plans')).json('id') };
}

export default function (data) {
  const name = `lt-${__VU}-${__ITER}-${Date.now()}`;

  const tenant = http.post(`${BASE_URL}/tenants`, JSON.stringify({ name, plan_id: data.planId }), params('POST /tenants'));
  check(tenant, { 'tenant created': (r) => r.status === 201 });
  if (tenant.status !== 201) return;
  const tenantId = tenant.json('id');

  for (let i = 0; i < 3; i++) {
    const usage = http.post(
      `${BASE_URL}/tenants/${tenantId}/usage`,
      JSON.stringify({ metric: 'api_calls', quantity: 1 + Math.floor(Math.random() * 100) }),
      params('POST /tenants/{id}/usage'),
    );
    check(usage, { 'usage recorded': (r) => r.status === 201 });
  }

  const invoice = http.post(
    `${BASE_URL}/tenants/${tenantId}/invoices`,
    JSON.stringify({ period_start: '2020-01-01T00:00:00Z', period_end: '2100-01-01T00:00:00Z' }),
    params('POST /tenants/{id}/invoices'),
  );
  check(invoice, { 'invoice generated': (r) => r.status === 201 });
  if (invoice.status !== 201) return;

  const read = http.get(`${BASE_URL}/invoices/${invoice.json('id')}`, { tags: { name: 'GET /invoices/{id}' } });
  check(read, { 'invoice read': (r) => r.status === 200 });

  sleep(0.2 + Math.random() * 0.3);
}
