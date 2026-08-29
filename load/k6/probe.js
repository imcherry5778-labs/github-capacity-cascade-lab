import http from 'k6/http';
import { check } from 'k6';

import { BASE_URL } from './lib/config.js';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: { checks: ['rate==1'] },
};

export default function () {
  const health = http.get(`${BASE_URL}/healthz`, { tags: { name: 'GET /healthz', request_kind: 'probe' } });
  const ready = http.get(`${BASE_URL}/readyz`, { tags: { name: 'GET /readyz', request_kind: 'probe' } });
  const token = http.post(`${BASE_URL}/token`, '{}', {
    headers: {
      'Content-Type': 'application/json',
      'X-Lab-Logical-Request-ID': 'probe-0',
      'X-Lab-Attempt': '1',
    },
    tags: { name: 'POST /token', request_kind: 'probe' },
  });
  check(health, { 'healthz is 200': (response) => response.status === 200 });
  check(ready, { 'readyz is 200': (response) => response.status === 200 });
  check(token, { 'token is 200': (response) => response.status === 200 });
}
