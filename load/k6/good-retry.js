import { prepareFault, resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, envInteger, faultSettings, logicalRequestID } from './lib/config.js';
import { createSummaryHandler } from './lib/summary.js';
import { executeLogicalRequest, goodRetryPolicy } from './lib/retry.js';

// Bad retry와 같은 error profile을 사용하되 전체 시도를 3회로 제한하고 backoff/jitter를 적용한다.
// 이름의 "good"은 보편적 최적이 아니라 bounded policy 비교를 위한 LAB_IMPLEMENTATION을 뜻한다.
const settings = arrivalSettings();
const fault = faultSettings({ error_rate: 0.35 });
const policy = goodRetryPolicy(
  envInteger('MAX_ATTEMPTS', 3, 1, 20),
  envInteger('BACKOFF_BASE_MS', 50, 1, 60000),
  envInteger('BACKOFF_MAX_MS', 500, 1, 60000),
);

// 부하 절감과 logical failure/latency 사이의 trade-off를 관찰하도록 failure threshold를 강제하지 않는다.
export const options = arrivalOptions(settings);

export function setup() {
  prepareFault(fault);
}

export default function () {
  // Bad retry와 같은 logical ID를 사용해 policy 외의 fault 결정을 가능한 한 같게 맞춘다.
  executeLogicalRequest(logicalRequestID('retry-comparison'), policy);
}

export function teardown() {
  resetFault();
}

export const handleSummary = createSummaryHandler({
  scenario: 'good-retry',
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
