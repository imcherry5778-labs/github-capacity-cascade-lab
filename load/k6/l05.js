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

const supportedScenarios = new Set(['hpa-blind', 'hpa-aware']);
const scenario = __ENV.L05_SCENARIO || 'hpa-blind';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L05_SCENARIO: ${scenario}`);
}

// HPA controller and Pod readiness를 관찰할 수 있는 bounded lab duration이다.
const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || 'l05-hpa-pair';
const settings = arrivalSettings({ logicalRate: 3, duration: '150s' });
const policy = noRetryPolicy();
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
  ...arrivalOptions(settings),
  // 1s service time과 bounded HPA warm-up 중에도 arrival rate를 유지한다.
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
  phase: 'L05',
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
    target: envInteger('SIDECAR_ACTIVE_REQUEST_TARGET', 1, 1, 1000000),
  },
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    k6: __ENV.K6_IMAGE || 'unknown',
    istio_proxy: __ENV.ISTIO_PROXY_IMAGE || 'unknown',
  },
});
