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
  'haproxy-control',
  'haproxy-constrained',
  'toxiproxy-control',
  'toxiproxy-latency',
  'toxiproxy-reset-peer',
]);
const scenario = __ENV.L01_SCENARIO || 'haproxy-control';
if (!supportedScenarios.has(scenario)) {
  throw new Error(`unsupported L01_SCENARIO: ${scenario}`);
}

// L00 기본값은 바꾸지 않고 L01 비교에만 짧은 capacity 관찰용 target을 선택한다.
const settings = arrivalSettings({ logicalRate: 20, duration: '4s' });
const policy = noRetryPolicy();
const applicationFault = {
  latency_ms: envInteger('APPLICATION_LATENCY_MS', 0, 0, 60000),
  error_rate: 0,
  max_in_flight: 0,
  seed: envInteger('FAULT_SEED', 17082026),
};

// Control/latency는 성공 contract를 검사하고, capacity/reset fault는 관측값을 숨기지 않는다.
const expectsFailure = scenario === 'haproxy-constrained' || scenario === 'toxiproxy-reset-peer';
export const options = {
  ...arrivalOptions(settings, expectsFailure ? {} : { logical_failures: ['rate==0'] }),
  // Connection 단위 현상이 keep-alive reuse에 가려지지 않도록 L01 workload마다 새 연결을 사용한다.
  noConnectionReuse: true,
};

export default function () {
  executeLogicalRequest(logicalRequestID(scenario), policy);
}

const proxyCapacity = scenario.startsWith('haproxy-')
  ? {
      frontend: scenario === 'haproxy-control' ? 'l01_control' : 'l01_constrained',
      backend: scenario === 'haproxy-control' ? 'be_l01_control' : 'be_l01_constrained',
      backend_server_maxconn: scenario === 'haproxy-control' ? 100 : 2,
      timeout_queue: scenario === 'haproxy-control' ? '1s' : '100ms',
      retries: 0,
      redispatch: false,
    }
  : null;

let networkToxic = { type: 'none' };
if (scenario === 'toxiproxy-latency') {
  networkToxic = {
    name: 'l01_latency_downstream',
    type: 'latency',
    stream: 'downstream',
    toxicity: 1,
    attributes: {
      latency: envInteger('TOXIPROXY_LATENCY_MS', 150, 1, 60000),
      jitter: 0,
    },
  };
} else if (scenario === 'toxiproxy-reset-peer') {
  networkToxic = {
    name: 'l01_reset_peer_downstream',
    type: 'reset_peer',
    stream: 'downstream',
    toxicity: 1,
    attributes: { timeout: 0 },
  };
}

export const handleSummary = createSummaryHandler({
  phase: 'L01',
  scenario,
  logicalRate: settings.logicalRate,
  duration: settings.duration,
  fault: applicationFault,
  applicationFault,
  proxyCapacity,
  networkToxic,
  requestPath: __ENV.REQUEST_PATH || 'unknown',
  requestTimeout: REQUEST_TIMEOUT,
  retryPolicy: policy.name,
  maxAttempts: policy.maxAttempts,
  imageTags: {
    auth_sim: __ENV.AUTH_SIM_IMAGE || 'unknown',
    haproxy: __ENV.HAPROXY_IMAGE || 'not-used',
    toxiproxy: __ENV.TOXIPROXY_IMAGE || 'not-used',
  },
});
