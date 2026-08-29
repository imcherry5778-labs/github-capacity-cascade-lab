import { prepareFault, resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, faultSettings, logicalRequestID } from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

// Error와 retry는 끄고 /token에 100ms latency만 주입해 지연의 독립적인 영향을 관찰한다.
const settings = arrivalSettings();
const fault = faultSettings({ latency_ms: 100 });
const policy = noRetryPolicy();

export const options = arrivalOptions(settings, {
  // Latency는 증가해도 logical operation은 모두 성공해야 한다.
  logical_failures: ['rate==0'],
});

export function setup() {
  // Control plane으로 기존 fault를 reset한 뒤 이 시나리오의 latency를 적용한다.
  prepareFault(fault);
}

export default function () {
  executeLogicalRequest(logicalRequestID('latency'), policy);
}

export function teardown() {
  // 주입한 latency가 후속 실험에 누출되지 않게 한다.
  resetFault();
}

export const handleSummary = createSummaryHandler({
  scenario: 'latency',
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
