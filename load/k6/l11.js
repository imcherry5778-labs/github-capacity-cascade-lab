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

// L11은 Sidecar saturation을 재현하지 않는다. 두 architecture scenario 모두 no-retry,
// same schedule, same timeout, same connection behavior를 공유하고 destination proxy
// placement(Pod-local sidecar vs node-local ztunnel)만 다르다.
const supportedScenarios = new Set(['sidecar', 'ambient-ztunnel']);
const scenario = __ENV.L11_SCENARIO || 'sidecar';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L11_SCENARIO: ${scenario}`);
}

const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || 'l11-sidecar-ambient-pair';
const policy = noRetryPolicy();
// L04와 동일한 fixed workload condition(20 ops/s, 4s)을 재사용한다. L11은 여기서 새 수치를
// 만들 이유가 없다.
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

// L11은 sidecar를 인위적으로 saturate하지 않으므로 두 scenario 모두 logical failure 0을
// 기대한다. (L04의 constrained처럼 실패를 기대하는 scenario는 L11에 없다.)
export const options = {
  ...arrivalOptions(settings, { logical_failures: ['rate==0'] }),
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

// Sidecar와 ambient-ztunnel은 관찰 가능한 proxy signal의 종류 자체가 다르다(Pod-local HTTP
// L7 counter vs node-local TCP L4 counter). 이 field는 그 관찰 mechanism만 기록하며, 서로
// 다른 architecture의 숫자를 numeric capacity target으로 나타내지 않는다.
const dataplaneObservation = scenario === 'sidecar'
  ? {
    observation_unit: 'sidecar-http-l7',
    mechanism: 'Pod-local istio-proxy inbound HTTP downstream/upstream counters',
    note: 'No artificial capacity constraint in L11; this is a visibility/ownership baseline, not a saturation target.',
  }
  : {
    observation_unit: 'ztunnel-tcp-l4',
    mechanism: 'node-local ztunnel inbound TCP connection/byte counters',
    note: 'ztunnel does not terminate HTTP; there is no HTTP-level counter here. NON-EQUIVALENT to the sidecar HTTP counters above.',
  };

export const handleSummary = createSummaryHandler({
  phase: 'L11',
  scenario,
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault: applicationFault,
  applicationFault,
  logicalIdNamespace: logicalIDNamespace,
  requestPath: __ENV.REQUEST_PATH
    || (scenario === 'sidecar'
      ? 'non-injected k6 Job -> ClusterIP Service -> istio-proxy -> auth-sim'
      : 'non-injected k6 Job -> ClusterIP Service -> destination node ztunnel -> auth-sim'),
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
  proxyCapacity: dataplaneObservation,
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    k6: __ENV.K6_IMAGE || 'unknown',
    dataplane_proxy: __ENV.DATAPLANE_PROXY_IMAGE || 'unknown',
  },
});
