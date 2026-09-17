import { Counter } from 'k6/metrics';

import { REQUEST_TIMEOUT, envInteger, logicalRequestID } from './lib/config.js';
import { badRetryPolicy, executeLogicalRequest, goodRetryPolicy, noRetryPolicy } from './lib/retry.js';
import { createSummaryHandler } from './lib/summary.js';

const scenarios = new Set([
  'retry-immediate', 'retry-backoff',
  'shedding-control', 'shedding-429',
  'scaling-blind', 'scaling-aware',
  'ramp-steep', 'ramp-gradual',
]);
const scenario = __ENV.L07_SCENARIO || 'retry-immediate';
if (!scenarios.has(scenario)) {
  throw new Error(`unsupported L07_SCENARIO: ${scenario}`);
}

const retryScenario = scenario === 'retry-immediate' || scenario === 'retry-backoff';
const maxAttempts = retryScenario ? envInteger('MAX_ATTEMPTS', 3, 2, 10) : 1;
const policy = scenario === 'retry-immediate'
  ? badRetryPolicy(maxAttempts)
  : scenario === 'retry-backoff'
    ? goodRetryPolicy(maxAttempts, envInteger('BACKOFF_BASE_MS', 100, 1, 60000), envInteger('BACKOFF_MAX_MS', 400, 1, 60000))
    : noRetryPolicy();
const logicalIDNamespace = __ENV.LOGICAL_ID_NAMESPACE || `l07-${scenario}`;
const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', 1000, 0, 60000),
  error_rate: 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

const downstreamResponses200 = new Counter('downstream_responses_200');
const downstreamResponses429 = new Counter('downstream_responses_429');
const downstreamResponses503 = new Counter('downstream_responses_503');
const downstreamResponses504 = new Counter('downstream_responses_504');
const downstreamResponsesOther = new Counter('downstream_responses_other');

function stagesForScenario() {
  if (scenario === 'ramp-steep') {
    // 30*1 + 1*2.5 + 39*4 + 1*2.5 + 29*1 = 220 intended requests.
    return [
      { phase: 'stable', target: 1, duration: '30s' },
      { phase: 'ramp-up', target: 4, duration: '1s' },
      { phase: 'peak', target: 4, duration: '39s' },
      { phase: 'ramp-down', target: 1, duration: '1s' },
      { phase: 'recovery', target: 1, duration: '29s' },
    ];
  }
  // 20*1 + 60*2.5 + 20*2.5 = 220 intended requests.
  return [
    { phase: 'stable', target: 1, duration: '20s' },
    { phase: 'ramp-up', target: 4, duration: '60s' },
    { phase: 'ramp-down', target: 1, duration: '20s' },
  ];
}

const stages = stagesForScenario();
const preAllocatedVUs = envInteger('PRE_ALLOCATED_VUS', 40, 1, 1000000);
const maxVUs = envInteger('MAX_VUS', 100, preAllocatedVUs, 1000000);
const smoke = __ENV.L07_SMOKE === '1';

export const options = {
  scenarios: smoke ? {
    smoke: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      maxDuration: '10s',
    },
  } : {
    workload: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '5s',
      stages: stages.map(({ target, duration }) => ({ target, duration })),
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  thresholds: smoke ? {} : { dropped_iterations: ['count==0'] },
  noConnectionReuse: true,
};

export default function () {
  const result = executeLogicalRequest(logicalRequestID(logicalIDNamespace), policy);
  const status = result.response === null ? 0 : result.response.status;
  if (status === 200) downstreamResponses200.add(1);
  else if (status === 429) downstreamResponses429.add(1);
  else if (status === 503) downstreamResponses503.add(1);
  else if (status === 504) downstreamResponses504.add(1);
  else downstreamResponsesOther.add(1);
}

export const handleSummary = createSummaryHandler({
  phase: 'L07',
  scenario,
  logicalRate: 4,
  duration: stages.map(({ duration }) => duration).join(' + '),
  workloadStages: stages,
  fault: applicationFault,
  applicationFault,
  logicalIdNamespace: logicalIDNamespace,
  requestPath: __ENV.REQUEST_PATH || 'non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  retrySource: retryScenario ? 'client only' : 'none',
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
