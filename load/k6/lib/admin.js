import http from 'k6/http';
import exec from 'k6/execution';

import { ADMIN_URL, DEFAULT_SEED, assertRemoteFaultSafety } from './config.js';

// 모든 fault를 끄는 표준 초기 상태다. Seed는 다음 비교 실험을 위해 고정한다.
const resetConfig = {
  latency_ms: 0,
  error_rate: 0,
  max_in_flight: 0,
  seed: DEFAULT_SEED,
};

export function prepareFault(config) {
  // 이전 실험 설정을 먼저 지운 뒤 이번 scenario의 완전한 snapshot을 적용한다.
  resetFault();
  putFault(config);
}

export function resetFault() {
  putFault(resetConfig);
}

export function putFault(config) {
  assertRemoteFaultSafety();
  // Admin credential은 환경 변수에서만 읽고 metadata, summary, metric label에 저장하지 않는다.
  const token = __ENV.LAB_ADMIN_TOKEN;
  if (!token) {
    exec.test.abort('LAB_ADMIN_TOKEN is required for fault mutation');
  }
  // Workload traffic과 구분할 수 있도록 control tag를 붙인다.
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
