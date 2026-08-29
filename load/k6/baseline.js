import { resetFault } from './lib/admin.js';
import { arrivalOptions, arrivalSettings, faultSettings, logicalRequestID } from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const settings = arrivalSettings();
const fault = faultSettings();
const policy = noRetryPolicy();

export const options = arrivalOptions(settings, {
  logical_failures: ['rate==0'],
});

export function setup() {
  resetFault();
}

export default function () {
  executeLogicalRequest(logicalRequestID('baseline'), policy);
}

export function teardown() {
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
