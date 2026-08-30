import { Counter } from 'k6/metrics';

import {
  REQUEST_TIMEOUT,
  arrivalOptions,
  arrivalSettings,
  envInteger,
  logicalRequestID,
} from './lib/config.js';
import { executeLogicalRequest, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const supportedScenarios = new Set([
  'envoy-control',
  'envoy-timeout',
  'envoy-retry-disabled',
  'envoy-retry-bounded',
  'envoy-circuit-breaker',
]);
const scenario = __ENV.L02_SCENARIO || 'envoy-control';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L02_SCENARIO: ${scenario}`);
}

// L02의 client는 항상 한 번만 호출한다. Envoy internal retry는 이 counter에 포함되지 않는다.
const policy = noRetryPolicy();
const settings = arrivalSettings({ logicalRate: 20, duration: '4s' });
const downstreamResponses200 = new Counter('downstream_responses_200');
const downstreamResponses503 = new Counter('downstream_responses_503');
const downstreamResponses504 = new Counter('downstream_responses_504');
const downstreamResponsesOther = new Counter('downstream_responses_other');

const isRetryScenario = scenario === 'envoy-retry-disabled' || scenario === 'envoy-retry-bounded';
const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', isRetryScenario ? 0 : 250, 0, 60000),
  error_rate: isRetryScenario ? 1 : 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

export const options = {
  ...arrivalOptions(settings, scenario === 'envoy-control' ? { logical_failures: ['rate==0'] } : {}),
  // Client connection reuse가 Envoy의 upstream connection-pool 관찰과 섞이지 않게 downstream은 새 연결을 쓴다.
  noConnectionReuse: true,
};

export default function () {
  const result = executeLogicalRequest(logicalRequestID(scenario), policy);
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
  phase: 'L02',
  scenario,
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault: applicationFault,
  applicationFault,
  requestPath: __ENV.REQUEST_PATH || 'k6 -> standalone Envoy -> auth-sim',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
  envoyProxy: {
    listener: __ENV.ENVOY_LISTENER || 'unknown',
    route: __ENV.ENVOY_ROUTE || 'unknown',
    cluster: __ENV.ENVOY_CLUSTER || 'unknown',
    stat_prefix: __ENV.ENVOY_STAT_PREFIX || 'unknown',
    route_timeout: __ENV.ENVOY_ROUTE_TIMEOUT || 'unknown',
    retry_on: __ENV.ENVOY_RETRY_ON || 'none',
    num_retries: envInteger('ENVOY_NUM_RETRIES', 0, 0, 1000),
    circuit_breakers: {
      max_connections: envInteger('ENVOY_MAX_CONNECTIONS', 100, 1, 1000000),
      max_pending_requests: envInteger('ENVOY_MAX_PENDING_REQUESTS', 100, 1, 1000000),
      max_requests: envInteger('ENVOY_MAX_REQUESTS', 100, 1, 1000000),
      max_retries: envInteger('ENVOY_MAX_RETRIES', 100, 0, 1000000),
    },
  },
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    envoy: __ENV.ENVOY_IMAGE || 'unknown',
  },
});
