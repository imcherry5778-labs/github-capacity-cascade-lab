# L08 curated evidence — Chaos Mesh Reproduction

이 디렉터리는 L08의 clean-source fixed-condition 실험 3회에서 수집된 local exploratory evidence다. 각 repetition은 독립적인 fresh k3d cluster에서 실행되었으며, 소스 커밋은 `c1c79d6a7ce4cd500dd00109fc48f8b78fbc1665`, 메타데이터의 `git_dirty`는 모두 `false`다.

모든 실행에서 계약(contract), 메타데이터(metadata), 정리(cleanup) 검증이 모두 PASS되었다.

| curated repetition | raw source directory | started at UTC | contract / cleanup | dropped iters | git_dirty |
| --- | --- | --- | --- | --- | --- |
| 1 | `results/chaos-mesh/20260917T180314Z/` | 2026-09-17T18:03:14Z | PASS / PASS | 0 | false |
| 2 | `results/chaos-mesh/20260917T180625Z/` | 2026-09-17T18:06:25Z | PASS / PASS | 0 | false |
| 3 | `results/chaos-mesh/20260917T180943Z/` | 2026-09-17T18:09:43Z | PASS / PASS | 0 | false |

---

## 1. Fixed Local Comparison Boundary

```text
non-injected k6 Job (capacity-cascade-l08-load)
  -> HAProxy (retries 0, no redispatch) (capacity-cascade-l08-proxy)
  -> auth-sim ClusterIP Service :8080
  -> inbound istio-proxy (http2MaxRequests: 1, retries disabled)
  -> auth-sim (capacity-cascade-l08-target)
```

- **Cluster & Runtime**: K3s `rancher/k3s:v1.35.5-k3s1` on containerd (`/run/k3s/containerd/containerd.sock`).
- **Service Mesh**: Istio `1.30.4` Sidecar mode, inbound capacity limit `http2MaxRequests: 1`, inbound proxy retry disabled via EnvoyFilter.
- **Chaos Engine**: Chaos Mesh `2.8.4` (`enableFilterNamespace: true`, dashboard/DNS disabled, containerd socket path configured).
- **Fault Type**: Single `NetworkChaos` resource (`action: delay`, `latency: 600ms`, `correlation: "100"`, `jitter: "0ms"`).
- **Workload**: Grafana k6 `2.2.0`, `constant-arrival-rate` 3 ops/s, duration 70s, client-side retry disabled.
- **Timeline Window**: Pre-fault 20s -> Declarative NetworkChaos active for 25s -> Post-fault recovery 25s.

---

## 2. Measured Repetition Results

모든 repetition은 동일한 스케줄(총 211 requests, 3 ops/s x 70s) 하에서 일관된 failure window 및 recovery 동작을 입증했다:

| 지표 | repetition 1 | repetition 2 | repetition 3 |
| --- | --- | --- | --- |
| **Logical Requests / Attempts** | 211 / 211 | 211 / 211 | 211 / 211 |
| **Client Retry Rate** | 0.0x (retry off) | 0.0x (retry off) | 0.0x (retry off) |
| **Dropped Iterations** | 0 | 0 | 0 |
| **Downstream HTTP 200** | 186 | 167 | 173 |
| **Downstream HTTP 503 / Timeout** | 25 | 44 | 38 |
| **HTTP Request Duration p95** | 1201.7 ms | 1201.6 ms | 1202.0 ms |
| **Fault Window Duration (CR status)** | 25.057 s | 25.052 s | 25.053 s |
| **Fault HAProxy 5xx Peak (concurrency)** | 20 | 24 | 17 |
| **Final Active Sessions / Queue** | 0 / 0 | 0 / 0 | 0 / 0 |

---

## 3. Timeline 및 신호 상관관계 (Signal Alignment)

3회의 실행 모두 `samples.jsonl` 시계열 데이터에서 다음의 명확한 단계별 상태 전이를 보였다:

```text
정상 상태 (Pre-fault, 0s~20s)
   - Chaos CR: None
   - HAProxy: sessions 0~1, queue 0, 5xx 0
   - k6: HTTP 200 100%, p95 < 2ms
   ↓
선언적 Chaos resource 적용 및 실제 주입 (Fault 시작, ~20s)
   - Chaos CR status: conditions[AllInjected]=True, Selected=True, containerRecords[phase]=Injected
   - t_injected_utc 기록
   ↓
Fault Window 동안 Signal 변화 (20s~45s)
   - 600ms network delay 주입으로 응답 지연 (p95 ~1201ms)
   - auth-sim 처리 지연으로 inbound istio-proxy (limit 1) 및 HAProxy 백엔드에 세션 누적 (sessions 3~4)
   - 타임아웃 및 capacity cascade로 HAProxy downstream 503 발생 (누적 25~44건)
   ↓
Fault 종료 및 자동 회복 (Fault 종료, ~45s)
   - Chaos duration(25s) 만료, CR status: containerRecords[phase]=Recovered
   - t_recovered_utc 기록
   ↓
Recovery 확인 (Post-fault, 45s~70s)
   - 잔여 in-flight 요청이 2~3초 내 소진된 후 503 증가 중단
   - HAProxy sessions 0으로 복귀, 이후 모든 유입 요청 HTTP 200 정상 응답
   ↓
Chaos Resource 및 Cluster Cleanup
   - Chaos CR 정상 삭제 확인
   - 클러스터 및 background 포트포워딩 완전 삭제 (0 leftover containers/clusters)
```

---

## 4. Blast Radius 격리 검증 (Namespace Filtering)

1. **Namespace Filtering 활성화**:
   - Helm values: `controllerManager.enableFilterNamespace: true`.
   - 대상 네임스페이스 `capacity-cascade-l08-target`에만 `chaos-mesh.org/inject: enabled` 어노테이션 적용.
   - `capacity-cascade-l08-load` 및 `capacity-cascade-l08-proxy` 네임스페이스는 어노테이션을 미부여하여 Chaos Daemon의 tc/netem 조작 대상에서 원천 배제.
2. **최소 권한 및 공격 표면 최소화**:
   - Dashboard 및 DNS Chaos controller 비활성화 (`dashboard.create: false`, `dnsServer.create: false`).
   - 단 하나의 fault type(`NetworkChaos`)만 적용하여 side effect 제거.
3. **Container Runtime 소켓 검증**:
   - k3s containerd 소켓 `/run/k3s/containerd/containerd.sock`을 chaos-daemon DaemonSet에 명시적으로 연결하여 호스트 소켓 오지정 방지.

---

## 5. Abort Safety 검증 (`make l08-abort-smoke`)

주입 도중 비정상 종료 또는 사용자 취소 시 안전성을 검증하기 위해 전용 abort 테스트를 수행했다:
- 워크로드 실행 중 fault가 활성화(`phase: Injected`)된 상태에서 즉시 중단 트리거.
- 실행 스크립트의 trap 핸들러가 `NetworkChaos` CR을 즉시 삭제(`kubectl delete -f ... --wait=true`).
- CR 잔여 여부 검사(`chaos_resources_remaining_after_abort == 0`), 클러스터 파괴 및 잔여 프로세스 정리 완료.
- `abort-contract.json`을 통해 abort safety 계약 충족을 입증.

---

## 6. Source Boundary (출처 무결성)

- `FACT`: GitHub의 2026-08-17 공식 RCA는 서비스 지연 및 capacity 포화에 의한 연쇄 장애(cascading failure)를 설명했다.
- `INFERENCE`: 선언적이고 시간 제어 가능한 fault injection CRD를 사용할 때, fault window와 proxy/app/load 신호 간의 상관관계를 결정론적으로 측정할 수 있다.
- `LAB_IMPLEMENTATION`: Chaos Mesh 2.8.4의 `NetworkChaos` CRD, k3d 환경의 containerd 소켓 연결, Istio 1.30.4 inbound sidecar(capacity target 1) 및 EnvoyFilter 조합은 이 실습 환경을 위해 구축된 독자적 교육용 재현 구성이다.
- `UNKNOWN`: GitHub 프로덕션 환경의 실제 토폴로지, 장애 분석 시 사용된 구체적인 카오스 엔지니어링 도구 유무나 내부 알고리즘은 공개된 바 없다.
