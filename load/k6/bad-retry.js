import { prepareFault, resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, envInteger, faultSettings, logicalRequestID } from './lib/config.js';
import { badRetryPolicy, executeLogicalRequest } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

// 35% deterministic error profile에서 실패 종류를 구분하지 않고, 전체 시도를 최대 5회로 제한하며 실패 시 즉시 retry하는 비교군이다.
// GitHub gateway나 VS Code의 실제 retry 알고리즘을 복제한 것이 아니다.
const settings = arrivalSettings();
const fault = faultSettings({ error_rate: 0.35 });
const policy = badRetryPolicy(envInteger('MAX_ATTEMPTS', 5, 1, 20));

// Retry의 성공률과 추가 부하 trade-off를 숨기지 않고 evidence로 남기기 위해 failure threshold를 강제하지 않는다.
export const options = arrivalOptions(settings);

export function setup() {
  prepareFault(fault);
}

export default function () {
  // Good retry와 같은 ID namespace를 사용해 같은 ID/attempt에 같은 deterministic fault가 적용되게 한다.
  executeLogicalRequest(logicalRequestID('retry-comparison'), policy);
}

export function teardown() {
  resetFault();
}

export const handleSummary = createSummaryHandler({
  scenario: 'bad-retry',
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
