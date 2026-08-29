import http from 'k6/http';
import { Counter, Rate, Trend } from 'k6/metrics';
import { sleep } from 'k6';

import { BASE_URL, REQUEST_TIMEOUT } from './config.js';

// 사용자 의도(logical)와 실제 HTTP 호출(physical)을 별도 counter로 측정해 retry 증폭을 계산한다.
export const logicalRequests = new Counter('logical_requests');
export const physicalAttempts = new Counter('physical_attempts');
export const retryAttempts = new Counter('retry_attempts');
export const logicalFailures = new Rate('logical_failures');
export const logicalRequestDuration = new Trend('logical_request_duration', true);

const retryableStatuses = new Set([408, 429, 502, 503, 504]);

export function executeLogicalRequest(requestID, policy) {
  // 이 함수 호출 하나가 사용자가 의도한 token operation 하나다.
  logicalRequests.add(1);
  retryAttempts.add(0);
  const started = Date.now();
  let response = null;
  let success = false;
  let attempts = 0;

  for (let attempt = 1; attempt <= policy.maxAttempts; attempt += 1) {
    // 최초 호출과 모든 retry를 포함한 실제 POST 하나를 각각 physical attempt로 세다.
    attempts = attempt;
    physicalAttempts.add(1);
    if (attempt > 1) {
      retryAttempts.add(1);
    }

    try {
      // 같은 logical ID와 증가하는 attempt를 header로 보내 server가 재현 가능한 fault 결정을 하게 한다.
      response = http.post(`${BASE_URL}/token`, '{}', {
        headers: {
          'Content-Type': 'application/json',
          'X-Lab-Logical-Request-ID': requestID,
          'X-Lab-Attempt': String(attempt),
        },
        tags: { name: 'POST /token', request_kind: 'workload' },
        timeout: REQUEST_TIMEOUT,
      });
    } catch (_error) {
      response = null;
    }

    success = response !== null && response.status >= 200 && response.status < 300;
    // 성공, 시도 횟수 소진, retry 불가 응답 중 하나면 logical operation을 종료한다.
    if (success || attempt === policy.maxAttempts || !policy.shouldRetry(response)) {
      break;
    }
    // Policy가 제공한 backoff/jitter만큼 기다린 후 다음 physical attempt를 시작한다.
    const delayMilliseconds = policy.delayMilliseconds(attempt);
    if (delayMilliseconds > 0) {
      sleep(delayMilliseconds / 1000);
    }
  }

  logicalFailures.add(success ? 0 : 1);
  logicalRequestDuration.add(Date.now() - started);
  return { response, success, attempts };
}

export function noRetryPolicy() {
  // Baseline/latency에서 fault와 retry의 영향을 분리하기 위한 1회 시도 정책이다.
  return {
    name: 'none',
    maxAttempts: 1,
    shouldRetry: () => false,
    delayMilliseconds: () => 0,
  };
}

export function badRetryPolicy(maxAttempts) {
  // 실패 종류를 구분하지 않고 즉시 retry하는 공격적 비교군이다.
  return {
    name: 'bad-immediate-retry',
    maxAttempts,
    shouldRetry: () => true,
    delayMilliseconds: () => 0,
  };
}

export function goodRetryPolicy(maxAttempts, baseDelayMilliseconds, maxDelayMilliseconds) {
  // 일시적으로 복구 가능한 상태만 retry하고, 지수 backoff에 full jitter를 적용해 동시 재시도를 피한다.
  return {
    name: 'good-bounded-backoff-jitter',
    maxAttempts,
    shouldRetry: (response) => response === null || response.status === 0 || retryableStatuses.has(response.status),
    delayMilliseconds: (completedAttempt) => {
      const exponential = baseDelayMilliseconds * (2 ** (completedAttempt - 1));
      const bounded = Math.min(exponential, maxDelayMilliseconds);
      // 0부터 bounded 사이의 random delay를 사용하는 full jitter다.
      return Math.random() * bounded;
    },
  };
}
