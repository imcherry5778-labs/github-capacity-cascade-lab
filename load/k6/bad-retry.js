import { prepareFault, resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, envInteger, faultSettings, logicalRequestID } from './lib/config.js';
import { badRetryPolicy, executeLogicalRequest } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const settings = arrivalSettings();
const fault = faultSettings({ error_rate: 0.35 });
const policy = badRetryPolicy(envInteger('MAX_ATTEMPTS', 5, 1, 20));

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
  scenario: 'bad-retry',
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
});
