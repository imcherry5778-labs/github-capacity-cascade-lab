import { resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, faultSettings, logicalRequestID } from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

// 모든 fault와 retry를 끄고 logical request 1건이 physical attempt 1건인 정상 기준선을 만든다.
const settings = arrivalSettings();
const fault = faultSettings();
const policy = noRetryPolicy();

// Baseline에서 logical failure가 하나라도 발생하면 실행을 실패로 처리한다.
export const options = arrivalOptions(settings, {
  logical_failures: ['rate==0'],
});

export function setup() {
  // 이전 실험의 fault가 남아 있지 않도록 workload 전에 초기화한다.
  resetFault();
}

export default function () {
  executeLogicalRequest(logicalRequestID('baseline'), policy);
}

export function teardown() {
  // 다음 실험이 정상 상태에서 시작하도록 종료 후에도 초기화한다.
  resetFault();
}

export const handleSummary = createSummaryHandler({
  scenario: 'baseline',
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
