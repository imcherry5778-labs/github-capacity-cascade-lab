import http from 'k6/http';
import { check } from 'k6';

import { BASE_URL } from './lib/config.js';

// Local runner와 Docker smoke가 auth-sim의 실제 HTTP 준비 상태를 확인할 때만 사용하는 최소 probe다.
// 이 호출은 본 scenario의 logical/physical counter evidence에 포함되지 않는 별도 k6 실행이다.
export const options = {
  vus: 1,
  iterations: 1,
  thresholds: { checks: ['rate==1'] },
};

export default function () {
  // Process liveness뿐 아니라 readiness와 실제 token path까지 한 번씩 통과해야 probe가 성공한다.
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
