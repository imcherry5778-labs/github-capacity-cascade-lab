import http from 'k6/http';
import { Counter, Rate, Trend } from 'k6/metrics';
import { sleep } from 'k6';

import { BASE_URL, REQUEST_TIMEOUT } from './config.js';

export const logicalRequests = new Counter('logical_requests');
export const physicalAttempts = new Counter('physical_attempts');
export const retryAttempts = new Counter('retry_attempts');
export const logicalFailures = new Rate('logical_failures');
export const logicalRequestDuration = new Trend('logical_request_duration', true);

const retryableStatuses = new Set([408, 429, 502, 503, 504]);

export function executeLogicalRequest(requestID, policy) {
  logicalRequests.add(1);
  retryAttempts.add(0);
  const started = Date.now();
  let response = null;
  let success = false;
  let attempts = 0;

  for (let attempt = 1; attempt <= policy.maxAttempts; attempt += 1) {
    attempts = attempt;
    physicalAttempts.add(1);
    if (attempt > 1) {
      retryAttempts.add(1);
    }

    try {
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
    if (success || attempt === policy.maxAttempts || !policy.shouldRetry(response)) {
      break;
    }
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
  return {
    name: 'none',
    maxAttempts: 1,
    shouldRetry: () => false,
    delayMilliseconds: () => 0,
  };
}

export function badRetryPolicy(maxAttempts) {
  return {
    name: 'bad-immediate-retry',
    maxAttempts,
    shouldRetry: () => true,
    delayMilliseconds: () => 0,
  };
}

export function goodRetryPolicy(maxAttempts, baseDelayMilliseconds, maxDelayMilliseconds) {
  return {
    name: 'good-bounded-backoff-jitter',
    maxAttempts,
    shouldRetry: (response) => response === null || response.status === 0 || retryableStatuses.has(response.status),
    delayMilliseconds: (completedAttempt) => {
      const exponential = baseDelayMilliseconds * (2 ** (completedAttempt - 1));
      const bounded = Math.min(exponential, maxDelayMilliseconds);
      return Math.random() * bounded;
    },
  };
}
