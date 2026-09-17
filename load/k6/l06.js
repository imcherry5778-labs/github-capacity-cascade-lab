import { Counter } from 'k6/metrics';

import {
  REQUEST_TIMEOUT,
  envDuration,
  envInteger,
  logicalRequestID,
} from './lib/config.js';
import { badRetryPolicy, executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const supportedScenarios = new Set(['cascade-no-retry', 'cascade-retry']);
const scenario = __ENV.L06_SCENARIO || 'cascade-no-retry';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L06_SCENARIO: ${scenario}`);
}

// All arrival phases are identical; client retry is the only comparison variable.
const stableRate = envInteger('STABLE_RATE', 1, 1, 1000000);
const peakRate = envInteger('PEAK_RATE', 4, stableRate, 1000000);
const recoveryRate = envInteger('RECOVERY_RATE', 1, 1, 1000000);
const stableDuration = envDuration('PHASE_STABLE_DURATION', '20s');
const peakDuration = envDuration('PHASE_PEAK_DURATION', '60s');
const recoveryDuration = envDuration('PHASE_RECOVERY_DURATION', '20s');
const preAllocatedVUs = envInteger('PRE_ALLOCATED_VUS', 40, 1, 1000000);
const maxVUs = envInteger('MAX_VUS', 100, preAllocatedVUs, 1000000);
const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || 'l06-cascade-pair';
const maxAttempts = envInteger('MAX_ATTEMPTS', 3, 2, 10);
const policy = scenario === 'cascade-retry' ? badRetryPolicy(maxAttempts) : noRetryPolicy();

const downstreamResponses200 = new Counter('downstream_responses_200');
const downstreamResponses503 = new Counter('downstream_responses_503');
const downstreamResponses504 = new Counter('downstream_responses_504');
const downstreamResponsesOther = new Counter('downstream_responses_other');

const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', 1000, 0, 60000),
  error_rate: 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

export const options = {
  scenarios: {
    workload: {
      executor: 'ramping-arrival-rate',
      startRate: stableRate,
      timeUnit: '1s',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '5s',
      stages: [
        { target: stableRate, duration: stableDuration },
        { target: peakRate, duration: peakDuration },
        { target: recoveryRate, duration: recoveryDuration },
      ],
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  // A dropped iteration would invalidate the logical-workload comparison.
  thresholds: { dropped_iterations: ['count==0'] },
  noConnectionReuse: true,
};

export default function () {
  const result = executeLogicalRequest(logicalRequestID(logicalIDNamespace), policy);
  const status = result.response === null ? 0 : result.response.status;
  if (status === 200) {
    downstreamResponses200.add(1);
  } else if (status === 503) {
    downstreamResponses503.add(1);
  } else if (status === 504) {
    downstreamResponses504.add(1);
  } else {
    downstreamResponsesOther.add(1);
  }
}

export const handleSummary = createSummaryHandler({
  phase: 'L06',
  scenario,
  logicalRate: peakRate,
  duration: `${stableDuration} + ${peakDuration} + ${recoveryDuration}`,
  workloadStages: [
    { phase: 'stable', rate: stableRate, duration: stableDuration },
    { phase: 'peak', rate: peakRate, duration: peakDuration },
    { phase: 'recovery', rate: recoveryRate, duration: recoveryDuration },
  ],
  fault: applicationFault,
  applicationFault,
  logicalIdNamespace: logicalIDNamespace,
  requestPath: __ENV.REQUEST_PATH || 'non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  retrySource: scenario === 'cascade-retry' ? 'client only' : 'none',
  maxAttempts: policy.maxAttempts,
  proxyCapacity: {
    mechanism: 'Sidecar ingress connectionPool http2MaxRequests',
    target: envInteger('SIDECAR_ACTIVE_REQUEST_TARGET', 1, 1, 1000000),
  },
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    haproxy: __ENV.HAPROXY_IMAGE || 'unknown',
    k6: __ENV.K6_IMAGE || 'unknown',
    istio_proxy: __ENV.ISTIO_PROXY_IMAGE || 'unknown',
  },
});
