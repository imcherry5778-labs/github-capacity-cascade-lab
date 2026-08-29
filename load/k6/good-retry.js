import { prepareFault, resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, envInteger, faultSettings, logicalRequestID } from './lib/config.js';
import { createSummaryHandler } from './lib/summary.js';
import { executeLogicalRequest, goodRetryPolicy } from './lib/retry.js';

const settings = arrivalSettings();
const fault = faultSettings({ error_rate: 0.35 });
const policy = goodRetryPolicy(
  envInteger('MAX_ATTEMPTS', 3, 1, 20),
  envInteger('BACKOFF_BASE_MS', 50, 1, 60000),
  envInteger('BACKOFF_MAX_MS', 500, 1, 60000),
);

export const options = arrivalOptions(settings);

export function setup() {
  prepareFault(fault);
}

export default function () {
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
