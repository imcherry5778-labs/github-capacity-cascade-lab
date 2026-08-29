import exec from 'k6/execution';

export const BASE_URL = trimTrailingSlash(__ENV.BASE_URL || 'http://127.0.0.1:8080');
export const ADMIN_URL = trimTrailingSlash(__ENV.ADMIN_URL || 'http://127.0.0.1:9090');
export const REQUEST_TIMEOUT = envDuration('REQUEST_TIMEOUT', '2s');
export const DEFAULT_SEED = envInteger('FAULT_SEED', 17082026);

export function arrivalSettings() {
  const logicalRate = envInteger('LOGICAL_RATE', 5, 1, 1000000);
  const preAllocatedVUs = envInteger('PRE_ALLOCATED_VUS', Math.max(10, logicalRate * 2), 1, 1000000);
  const maxVUs = envInteger('MAX_VUS', Math.max(50, preAllocatedVUs * 2), preAllocatedVUs, 1000000);
  return {
    logicalRate,
    duration: envDuration('DURATION', '5s'),
    preAllocatedVUs,
    maxVUs,
  };
}

export function arrivalOptions(settings, thresholds = {}) {
  return {
    scenarios: {
      workload: {
        executor: 'constant-arrival-rate',
        rate: settings.logicalRate,
        timeUnit: '1s',
        duration: settings.duration,
        preAllocatedVUs: settings.preAllocatedVUs,
        maxVUs: settings.maxVUs,
        gracefulStop: '2s',
      },
    },
    thresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  };
}

export function smokeOptions() {
  return {
    scenarios: {
      smoke: {
        executor: 'shared-iterations',
        vus: 1,
        iterations: envInteger('SMOKE_ITERATIONS', 1, 1, 10),
        maxDuration: '10s',
      },
    },
    thresholds: {
      checks: ['rate==1'],
      logical_failures: ['rate==0'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  };
}

export function faultSettings(defaults = {}) {
  return {
    latency_ms: envInteger('FAULT_LATENCY_MS', defaults.latency_ms || 0, 0, 60000),
    error_rate: envNumber('FAULT_ERROR_RATE', defaults.error_rate || 0, 0, 1),
    max_in_flight: envInteger('FAULT_MAX_IN_FLIGHT', defaults.max_in_flight || 0, 0, 1000000),
    seed: DEFAULT_SEED,
  };
}

export function logicalRequestID(profile) {
  return `${profile}-${exec.scenario.iterationInTest}`;
}

export function envInteger(name, fallback, minimum = Number.MIN_SAFE_INTEGER, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return parsed;
}

export function envNumber(name, fallback, minimum, maximum) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be a number between ${minimum} and ${maximum}`);
  }
  return parsed;
}

export function envDuration(name, fallback) {
  const value = __ENV[name] || fallback;
  if (!/^\d+(ms|s|m)$/.test(value)) {
    throw new Error(`${name} must use a k6 duration such as 500ms, 5s, or 1m`);
  }
  return value;
}

export function assertRemoteFaultSafety() {
  const localPattern = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i;
  if (!localPattern.test(ADMIN_URL) && __ENV.ALLOW_REMOTE_FAULTS !== '1') {
    exec.test.abort('remote ADMIN_URL fault mutation requires ALLOW_REMOTE_FAULTS=1');
  }
}

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, '');
}
