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

const supportedScenarios = new Set(['sidecar-control', 'sidecar-constrained']);
const scenario = __ENV.L04_SCENARIO || 'sidecar-control';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L04_SCENARIO: ${scenario}`);
}

// 두 scenario는 같은 logical ID namespace와 no-retry policy를 사용한다.
const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || 'l04-sidecar-pair';
const policy = noRetryPolicy();
const settings = arrivalSettings({ logicalRate: 20, duration: '4s' });
const downstreamResponses200 = new Counter('downstream_responses_200');
const downstreamResponses503 = new Counter('downstream_responses_503');
const downstreamResponses504 = new Counter('downstream_responses_504');
const downstreamResponsesOther = new Counter('downstream_responses_other');

const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', 250, 0, 60000),
  error_rate: 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

export const options = {
  ...arrivalOptions(settings, scenario === 'sidecar-control' ? { logical_failures: ['rate==0'] } : {}),
  // Downstream connection reuse를 끄고 두 scenario의 client behavior를 동일하게 고정한다.
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
  phase: 'L04',
  scenario,
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault: applicationFault,
  applicationFault,
  logicalIdNamespace: logicalIDNamespace,
  requestPath: __ENV.REQUEST_PATH || 'non-injected k6 Job -> ClusterIP Service -> istio-proxy -> auth-sim',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
  proxyCapacity: {
    mechanism: 'Sidecar ingress connectionPool http2MaxRequests',
    target: envInteger('SIDECAR_ACTIVE_REQUEST_TARGET', 100, 1, 1000000),
  },
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    k6: __ENV.K6_IMAGE || 'unknown',
    istio_proxy: __ENV.ISTIO_PROXY_IMAGE || 'unknown',
  },
});
