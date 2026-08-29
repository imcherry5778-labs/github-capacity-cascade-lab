import http from 'k6/http';
import exec from 'k6/execution';

import { ADMIN_URL, DEFAULT_SEED, assertRemoteFaultSafety } from './config.js';

const resetConfig = {
  latency_ms: 0,
  error_rate: 0,
  max_in_flight: 0,
  seed: DEFAULT_SEED,
};

export function prepareFault(config) {
  resetFault();
  putFault(config);
}

export function resetFault() {
  putFault(resetConfig);
}

export function putFault(config) {
  assertRemoteFaultSafety();
  const token = __ENV.LAB_ADMIN_TOKEN;
  if (!token) {
    exec.test.abort('LAB_ADMIN_TOKEN is required for fault mutation');
  }
  const response = http.put(`${ADMIN_URL}/admin/fault`, JSON.stringify(config), {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    tags: { name: 'PUT /admin/fault', request_kind: 'control' },
    timeout: '2s',
  });
  if (response.status !== 200) {
    exec.test.abort(`fault mutation failed with HTTP ${response.status}`);
  }
}
