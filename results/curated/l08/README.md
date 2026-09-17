# L08 curated evidence — Chaos Mesh Reproduction

이 디렉터리는 L08의 clean-source fixed-condition 실험 3회 및 전용 abort-smoke 검증에서 수집된 local exploratory evidence다. 각 repetition과 abort-smoke는 독립적인 fresh k3d cluster에서 실행되었으며, 소스 커밋은 `ecb0086546f71a7e02a36eb5156498c1bd2172e3`, 메타데이터의 `git_dirty`는 모두 `false`다.

모든 실행에서 계약(contract), 메타데이터(metadata), 정리(cleanup), 타겟 식별(target identity) 검증이 모두 PASS되었다.

| curated run | raw source directory | started at UTC | contract / cleanup | target identity | dropped iters | git_dirty |
| --- | --- | --- | --- | --- | --- | --- |
| repetition 1 | `results/chaos-mesh/20260917T184437Z/` | 2026-09-17T18:44:37Z | PASS / PASS | PASS | 0 | false |
| repetition 2 | `results/chaos-mesh/20260917T184758Z/` | 2026-09-17T18:47:58Z | PASS / PASS | PASS | 0 | false |
| repetition 3 | `results/chaos-mesh/20260917T185109Z/` | 2026-09-17T18:51:09Z | PASS / PASS | PASS | 0 | false |
| abort-smoke | `results/chaos-mesh/20260917T185441Z/` | 2026-09-17T18:54:41Z | PASS / PASS | PASS | N/A | false |

---

## 1. Fixed Local Comparison Boundary

```text
non-injected k6 Job (capacity-cascade-l08-load)
  -> HAProxy (retries 0, no redispatch) (capacity-cascade-l08-target)
  -> auth-sim ClusterIP Service :8080
  -> inbound istio-proxy (http2MaxRequests: 1, retries disabled)
  -> auth-sim (capacity-cascade-l08-target)
```

- **Namespace Topology 및 격리 경계**:
  - L08이 직접 생성하는 워크로드 네임스페이스는 부하 생성용 `capacity-cascade-l08-load`와 타겟 및 프록시가 배치된 `capacity-cascade-l08-target` 두 개다 (별도의 `capacity-cascade-l08-proxy` 네임스페이스는 생성하지 않음). Istio(`istio-system`), Chaos Mesh(`chaos-mesh`) 및 Kubernetes system 네임스페이스는 클러스터에 별도로 존재한다.
  - **네임스페이스 격리 경계**: Chaos Mesh의 `controllerManager.enableFilterNamespace: true` 설정을 적용하고 `capacity-cascade-l08-target`에만 `chaos-mesh.org/inject: "enabled"` 어노테이션을 부여함으로써, 워크로드 부하 생성 네임스페이스(`capacity-cascade-l08-load`)를 Chaos Daemon의 조작 대상에서 원천 배제한다.
  - **라벨 셀렉터 격리 경계**: 동일한 `capacity-cascade-l08-target` 네임스페이스 내에 위치한 HAProxy는 `NetworkChaos`의 라벨 셀렉터(`app.kubernetes.io/name: auth-sim`, `app.kubernetes.io/instance: auth-sim`)를 통해 주입 대상에서 엄격히 배제된다. NetworkChaos는 Pod를 타겟으로 동작하며, Istio sidecar와 auth-sim 애플리케이션 컨테이너는 같은 Pod 네트워크 네임스페이스를 공유하므로 주입 대상은 `auth-sim` 워크로드 Pod다. 러너는 `verify_network_chaos_state` 함수를 통해 주입 및 회복 시점에 오직 `capacity-cascade-l08-target/auth-sim-*` Pod identity 하나만 타겟팅되었음을 fail-closed 방식으로 검증한다.
- **Host Kernel Safety Boundary**:
  - 러너에 의한 호스트 커널 변형은 전혀 없다 (`Host mutation by L08 runner: NONE`).
  - 필수 커널 모듈(`iptable_filter`, `sch_netem`)은 `/proc/modules`를 통해 호스트 레벨에서 읽기 전용(read-only)으로 검사하며, 부재 시 자동 로드(privileged docker run modprobe)를 시도하지 않고 즉시 fail-closed로 종료한다.
- **Cluster & Runtime**: K3s `rancher/k3s:v1.35.5-k3s1` on containerd (`/run/k3s/containerd/containerd.sock`).
- **Service Mesh**: Istio `1.30.4` Sidecar mode, inbound capacity limit `http2MaxRequests: 1`, inbound proxy retry disabled via EnvoyFilter.
- **Chaos Engine**: Chaos Mesh `2.8.4` (`enableFilterNamespace: true`, dashboard/DNS disabled, containerd socket path configured).
- **Fault Type**: Single `NetworkChaos` resource (`action: delay`, `latency: 600ms`, `correlation: "0"`, `jitter: "0ms"`, `duration: 25s`).
- **Workload**: Grafana k6 `2.2.0`, `constant-arrival-rate` 3 ops/s, duration 70s, client-side retry disabled.
- **Timeline Window**: Pre-fault 20s -> Declarative NetworkChaos active for 25s -> Post-fault recovery 25s.

---

## 2. Measured Repetition Results

모든 repetition은 동일한 스케줄(총 210~211 requests, 3 ops/s x 70s) 하에서 일관된 failure window 및 recovery 동작을 입증했다:

| 지표 | repetition 1 | repetition 2 | repetition 3 |
| --- | --- | --- | --- |
| **Logical Requests / Attempts** | 211 / 211 | 211 / 211 | 210 / 210 |
| **Client Retry Rate** | 0.0x (retry off) | 0.0x (retry off) | 0.0x (retry off) |
| **Dropped Iterations** | 0 | 0 | 0 |
| **Downstream HTTP 200** | 164 | 161 | 162 |
| **Downstream HTTP 503 / Timeout** | 47 | 50 | 48 |
| **HTTP Request Duration p95** | 1201.8 ms | 1201.7 ms | 1201.7 ms |
| **Fault Window Duration (CR status)** | 25.061 s | 25.062 s | 25.057 s |
| **Target Identity Verified** | true (`auth-sim` 1 Pod target, HAProxy 0) | true (`auth-sim` 1 Pod target, HAProxy 0) | true (`auth-sim` 1 Pod target, HAProxy 0) |
| **Fault Sidecar Active Overflow Peak** | 0 | 0 | 0 |
| **Fault window 중 HAProxy 누적 5xx counter 최대 관측값** | 22 | 28 | 33 |
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
   - Chaos CR status: conditions[AllInjected]=True, Selected=True, AllRecovered=False
   - containerRecords[0].phase="Injected", containerRecords[0].id="capacity-cascade-l08-target/auth-sim-*"
   - target identity 검증 통과 (auth-sim Pod 타겟, HAProxy 주입 배제 확인)
   - t_injected_utc 기록
   ↓
Fault Window 동안 Signal 변화 (20s~45s)
   - 600ms network delay 주입으로 응답 지연 (p95 ~1202ms)
   - auth-sim 처리 지연으로 inbound istio-proxy (limit 1) 및 HAProxy 백엔드에 세션 누적 (sessions 3~4)
   - fault-induced network delay 동안 HAProxy/backend request pressure와 타임아웃/503 발생 (누적 47~50건)
   - (참고: 이 L08 실험에서는 sidecar active overflow peak = 0으로 관찰됨. 503은 sidecar queue 포화/overflow 기반의 capacity cascade가 아니라, 지속적 유입 부하 하에서 네트워크 지연으로 인한 요청 처리 시간 증가 및 클라이언트/프록시 타임아웃에 기인함)
   ↓
Fault 종료 및 자동 회복 (Fault 종료, ~45s)
   - Chaos duration(25s) 만료
   - Chaos CR status: conditions[AllRecovered]=True, conditions[AllInjected]=False, containerRecords[0].phase="Not Injected"
   - (참고: Chaos Mesh 2.8.4의 실제 복구 상태는 phase="Not Injected" 및 condition AllRecovered=True로 표현됨)
   - t_recovered_utc 기록
   ↓
Recovery 확인 (Post-fault, 45s~70s)
   - 잔여 in-flight 요청이 2~3초 내 소진된 후 503 증가 중단
   - HAProxy sessions 0으로 복귀, 이후 모든 유입 요청 HTTP 200 정상 응답
   ↓
Chaos Resource 및 Cluster Cleanup
   - Chaos CR 정상 삭제 확인 (남은 CR 0개)
   - 클러스터 및 background 포트포워딩 완전 삭제 (0 leftover containers/clusters)
```

---

## 4. Blast Radius 격리 및 Host Safety 검증

1. **Namespace Filtering 활성화**:
   - Helm values: `controllerManager.enableFilterNamespace: true`.
   - 대상 네임스페이스 `capacity-cascade-l08-target`에만 `chaos-mesh.org/inject: enabled` 어노테이션 적용.
   - `capacity-cascade-l08-load` 네임스페이스는 어노테이션을 미부여하여 Chaos Daemon의 tc/netem 조작 대상에서 원천 배제.
2. **Label Selector 격리**:
   - 동일 네임스페이스 내 HAProxy는 `selector.labelSelectors`를 통해 보호되며, `verify_network_chaos_state`를 통해 `capacity-cascade-l08-target/auth-sim-*` Pod 외의 주입이 없음이 확증됨.
3. **Host Safety**:
   - 호스트 커널 모듈에 대한 임의 변경을 금지하며, 읽기 전용 preflight 확인만 수행함.
4. **최소 권한 및 공격 표면 최소화**:
   - Dashboard 및 DNS Chaos controller 비활성화 (`dashboard.create: false`, `dnsServer.create: false`).
   - 단 하나의 fault type(`NetworkChaos`)만 적용하여 side effect 제거.
5. **Container Runtime 소켓 검증**:
   - k3s containerd 소켓 `/run/k3s/containerd/containerd.sock`을 chaos-daemon DaemonSet에 명시적으로 연결하여 호스트 소켓 오지정 방지.

---

## 5. Abort Safety 검증 (`results/curated/l08/abort-smoke/`)

주입 도중 실행 취소 또는 중단 시 안전성을 검증하기 위해 전용 controlled abort 테스트를 수행했다:
- 이 검증은 비동기 OS 시그널(SIGINT) 테스트가 아니라, **러너의 controlled abort path 및 안전한 자원 회수 경로**를 검증한다.
- 워크로드 실행 중 fault가 활성화되고 target identity가 검증된 상태(`AllInjected=True`, `phase: Injected`, target `auth-sim`)에서 즉시 controlled abort 트리거.
- 실행 스크립트가 `NetworkChaos` CR을 즉시 삭제(`kubectl delete networkchaos auth-sim-delay --timeout=15s`).
- CR 잔여 여부 검사(`chaos_resources_remaining_after_abort == 0`), 클러스터 파괴 및 잔여 프로세스 정리 완료.
- `abort-contract.json` 및 `metadata.json`을 `results/curated/l08/abort-smoke/`에 보존하여 abort safety 계약 충족을 입증.

---

## 6. Source Boundary (출처 무결성)

- `FACT`: GitHub의 2026-08-17 공식 RCA는 서비스 지연 및 capacity 포화에 의한 연쇄 장애(cascading failure)를 설명했다.
- `INFERENCE`: 선언적이고 시간 제어 가능한 fault injection CRD를 사용할 때, fault window와 proxy/app/load 신호 간의 상관관계를 결정론적으로 측정할 수 있다.
- `LAB_IMPLEMENTATION`: Chaos Mesh 2.8.4의 `NetworkChaos` CRD, k3d 환경의 containerd 소켓 연결, Istio 1.30.4 inbound sidecar(capacity target 1) 및 EnvoyFilter 조합은 이 실습 환경을 위해 구축된 독자적 교육용 재현 구성이다.
- `UNKNOWN`: GitHub 프로덕션 환경의 실제 토폴로지, 장애 분석 시 사용된 구체적인 카오스 엔지니어링 도구 유무나 내부 알고리즘은 공개된 바 없다.
