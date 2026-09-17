import { Counter } from 'k6/metrics';

import {
  REQUEST_TIMEOUT,
  envDuration,
  envInteger,
  logicalRequestID,
} from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const rate = envInteger('RATE', 3, 1, 1000000);
const duration = envDuration('DURATION', '70s');
const preAllocatedVUs = envInteger('PRE_ALLOCATED_VUS', 20, 1, 1000000);
const maxVUs = envInteger('MAX_VUS', 50, preAllocatedVUs, 1000000);
const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || 'l08-chaos';
const policy = noRetryPolicy();

const downstreamResponses200 = new Counter('downstream_responses_200');
const downstreamResponses503 = new Counter('downstream_responses_503');
const downstreamResponses504 = new Counter('downstream_responses_504');
const downstreamResponsesOther = new Counter('downstream_responses_other');

const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', 0, 0, 60000),
  error_rate: 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

export const options = {
  scenarios: {
    workload: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '5s',
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
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
  phase: 'L08',
  scenario: __ENV.L08_SCENARIO || 'chaos-network-delay',
  logicalRate: rate,
  duration,
  fault: {
    type: 'NetworkChaos',
    action: 'delay',
    target: 'auth-sim',
    latency: __ENV.FAULT_LATENCY || '600ms',
    duration: __ENV.FAULT_DURATION || '25s',
  },
  applicationFault,
  logicalIdNamespace: logicalIDNamespace,
  requestPath: __ENV.REQUEST_PATH || 'non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  retrySource: 'none',
  maxAttempts: policy.maxAttempts,
  proxyCapacity: {
    mechanism: 'Sidecar ingress connectionPool http2MaxRequests',
    target: envInteger('SIDECAR_ACTIVE_REQUEST_TARGET', 1, 1, 1000000),
  },
});
