import http from 'k6/http';
import { check } from 'k6';

import { resetFault } from './lib/admin.js';
import { BASE_URL, faultSettings, logicalRequestID, smokeOptions } from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

// 짧은 단일 iteration으로 health, readiness, token response와 핵심 counter 연결을 엄격하게 확인한다.
const fault = faultSettings();
const policy = noRetryPolicy();

export const options = smokeOptions();

export function setup() {
  // Smoke는 항상 fault가 없는 정상 상태에서 시작한다.
  resetFault();
}

export default function () {
  // Probe endpoint와 workload endpoint를 함께 호출하여 public plane의 최소 contract를 검증한다.
  const health = http.get(`${BASE_URL}/healthz`, { tags: { name: 'GET /healthz', request_kind: 'probe' } });
  const ready = http.get(`${BASE_URL}/readyz`, { tags: { name: 'GET /readyz', request_kind: 'probe' } });
  const result = executeLogicalRequest(logicalRequestID('smoke'), policy);

  check(health, {
    'healthz is 200': (response) => response.status === 200,
    'healthz body is valid': (response) => response.json('status') === 'ok',
  });
  check(ready, {
    'readyz is 200': (response) => response.status === 200,
    'readyz body is valid': (response) => response.json('status') === 'ready',
  });
  check(result.response, {
    'token is 200': (response) => response !== null && response.status === 200,
    'token body is lab placeholder': (response) => response !== null && response.json('token') === 'lab-token-placeholder',
    'token returns request ID': (response) => response !== null && response.json('request_id') === logicalRequestID('smoke'),
    'token returns first attempt': (response) => response !== null && response.json('attempt') === 1,
  });
}

export function teardown() {
  // Smoke 성공 여부와 관계없이 정상 fault 설정으로 되돌린다.
  resetFault();
}

export const handleSummary = createSummaryHandler({
  scenario: 'smoke',
  logicalRate: null,
  duration: 'single iteration',
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
