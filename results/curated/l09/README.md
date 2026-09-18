# L09 curated evidence — Azure AKS Validation

이 디렉터리는 L09의 Azure AKS(Managed Kubernetes) 환경에서 검증한 3회 연속 paired repetition 측정 원문을 선별한 cloud exploratory evidence다. Source commit `75368e390cae5c483d4ec51df4ffd41709ff75ee` 기준으로 실행되었으며, 검증 완료 후 모든 Azure 클라우드 리소스가 완전 회수(0-residual)되었음을 확인했다.

| curated repetition | raw source directory | started at UTC | pair contract |
| --- | --- | --- | --- |
| 1 | `results/aks/20260918T062457Z/capacity-cascade-l09-r1/` | 2026-09-18T06:36:57Z | PASS |
| 2 | `results/aks/20260918T062457Z/capacity-cascade-l09-r2/` | 2026-09-18T06:44:54Z | PASS |
| 3 | `results/aks/20260918T062457Z/capacity-cascade-l09-r3/` | 2026-09-18T06:53:44Z | PASS |

---

## 1. Cloud Experimental Setup & Parameters

```text
non-injected k6 Job (in aks cluster, load namespace)
  -> HAProxy (retries 0, no redispatch)
  -> auth-sim ClusterIP Service
  -> injected inbound istio-proxy (http2MaxRequests: 1)
  -> auth-sim (latency 1000ms, admission limit 0)
```

- **Cloud Platform:** Azure Kubernetes Service (AKS)
- **Region:** `eastus`
- **Kubernetes Version:** `1.35.7`
- **AKS Tier:** `Free` (Management cluster fee $0.00)
- **Node Pool:** 1 Node, `Standard_D4s_v7` (4 vCPU, 16 GiB RAM, Ubuntu 24.04.4 LTS, containerd 2.3.3-2)
- **Networking:** Azure CNI Overlay (`network_plugin=azure`, `network_plugin_mode=overlay`)
- **Container Registry:** Azure Container Registry (Basic SKU)
- **Service Mesh:** Istio `1.30.4` (self-managed Helm install)
- **Proxy Ingress Bound:** `http2MaxRequests: 1` on inbound port 8080
- **HPA Policy:** ContainerResource CPU target `80%` (min 1, max 4) — CPU-blind to sidecar queues
- **Workload Schedule:** ramping-arrival-rate (20s stable 1/s -> 60s ramp 1/s to 4/s -> 20s ramp 4/s to 1/s)

---

## 2. Measured Azure AKS Comparison Matrix

| repetition | scenario | logical req | physical att | retries | 200 OK | 503 Service Unavailable | sidecar active overflow | HAProxy sessions | HAProxy 5xx | HPA replicas (min/max) | recovery idle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **R1** | `cascade-no-retry` | 219 | 219 | 0 | 76 | 143 | 143 | 219 | 143 | 1 / 1 | TRUE |
| **R1** | `cascade-retry` | 219 | 508 | 289 | 79 | 140 | **429** | 508 | 429 | 1 / 1 | TRUE |
| **R2** | `cascade-no-retry` | 219 | 219 | 0 | 75 | 144 | 144 | 219 | 144 | 1 / 1 | TRUE |
| **R2** | `cascade-retry` | 219 | 507 | 288 | 79 | 140 | **428** | 507 | 428 | 1 / 1 | TRUE |
| **R3** | `cascade-no-retry` | 219 | 219 | 0 | 75 | 144 | 144 | 219 | 144 | 1 / 1 | TRUE |
| **R3** | `cascade-retry` | 220 | 513 | 293 | 79 | 141 | **434** | 513 | 434 | 1 / 1 | TRUE |

---

## 3. Comparison with Local (L06 k3d) Evidence

| Metric | Local k3d (L06 Curated Average) | Azure AKS (L09 Curated Average) | Comparison / Notes |
| --- | --- | --- | --- |
| `no-retry` Physical Requests | 219.3 | 219.0 | 1.00x |
| `no-retry` Sidecar Overflow | 143.7 | 143.7 | 1.00x |
| `retry` Physical Requests | 510.3 | 509.3 | 2.32x physical attempt amplification |
| `retry` Sidecar Overflow | 431.7 | 430.3 | L06와 매우 유사한 약 3.0x amplification (2.99x) |
| Successful Tokens (200 OK) | 78~80 | 78~79 | 유사한 백엔드 토큰 처리량 |
| HPA Replicas Max | 1 (blind) | 1 (blind) | 동일한 스케일링 맹점 유지 |
| Application Admission Rejection | 0 | 0 | 관측된 503 에러는 application admission mechanism이 아닌 constrained sidecar boundary에서 발생 |

---

## 4. Mechanism Classification: PRESERVED / CHANGED / INCONCLUSIVE

본 분류는 GitHub의 비공개 운영 사실(`FACT`)에 대한 주장이 아니며, L06(Local k3d)과 L09(Azure AKS)의 실측 증거에 기반한 분석적 추론(`INFERENCE`)이다.

### [PRESERVED]
- **Sidecar Active Overflow Amplification:**
  클라이언트 재시도(max 3 attempts) 시 Envoy inbound circuit breaker (`http2MaxRequests: 1`)에서 발생하는 503 active overflow가 L06와 매우 유사한 약 3.0x amplification(143~144건 -> 428~434건)으로 관찰됨 (`INFERENCE`, based on L06/L09 measured evidence).
- **Application-CPU Blind HPA:**
  애플리케이션 CPU 사용률 기반 HPA는 사이드카 대기열 및 인그레스 거부 트래픽을 감지하지 못하므로, 부하가 피크로 치솟고 503 에러가 폭증해도 Replica가 1개로 유지되는 'Blind Spot' 현상이 클라우드 환경에서도 동일하게 관찰됨 (`INFERENCE`, based on L06/L09 measured evidence).
- **상위 프록시(HAProxy) 전파 일치성:**
  HAProxy 백엔드 관측 세션 수와 5xx 응답 수가 Envoy 사이드카의 물리 요청 및 overflow 통계와 1:1로 일치하여 전파됨 (`INFERENCE`, based on L06/L09 measured evidence).
- **Application Admission Rejection 미발생:**
  모든 관측된 503 에러는 application admission rejection layer가 아닌 제약된 sidecar boundary(`http2MaxRequests: 1`)에서 발생함 (`INFERENCE`, based on L06/L09 measured evidence).

### [CHANGED]
- 본 축소 실험의 제약 조건 하에서 메커니즘 동작(오버플로 발생 및 전파 패턴) 자체의 본질적 변화는 관찰되지 않음 (`INFERENCE`, based on L06/L09 measured evidence).
  (인프라, 네트워크, 운영 및 수명주기 차이는 메커니즘 변화가 아닌 아래 'Cloud Environment & Operational Drift' 섹션으로 분리함).

### [INCONCLUSIVE]
- **Cluster Autoscaler (노드 레벨 자동 확장) 상호작용:**
  구독의 4 vCPU 한도로 인해 1노드 고정 상태에서 실행되었으며 Cluster Autoscaler가 비활성화되었으므로, 노드 오토스케일러가 사이드카 대기열 병목과 어떻게 상호작용하는지는 본 실험에서 결론 내릴 수 없음 (`UNKNOWN`).
- **광역 WAN 네트워크 지연의 복구 영향:**
  k6 부하 생성기가 동일 AKS 클러스터 내의 비주입 네임스페이스에서 실행되었으므로, 인터넷 경계 WAN 지연이나 패킷 손실이 클라이언트 백오프 및 복구 시간에 미치는 영향은 이번 실험 범위에서 측정되지 않음 (`UNKNOWN`).

---

## 5. Cloud Environment & Operational Drift

메커니즘 동작과 별개로, 관리형 클라우드 환경(Azure AKS) 도입에 따라 발생한 인프라 및 운영상의 구체적 차이는 다음과 같으며, 이는 GitHub incident FACT가 아닌 L09의 환경 선택(`LAB_IMPLEMENTATION`) 및 실측 관찰값(`measured L09 observation`)이다:

- **인프라 및 네트워크 데이터패스:**
  Local의 Docker bridge/localhost 루프백 대신 Azure CNI Overlay 및 VNet 서브넷 라우팅(`LAB_IMPLEMENTATION`), 클라우드 호스트 VM 커널(`6.8.0-1067-azure`) 및 containerd 런타임 상에서 구동됨 (`measured L09 observation`).
- **프로비저닝 수명주기 및 대기 시간:**
  Local k3d는 10~20초 내 클러스터 준비가 완료되나, AKS는 ARM API 및 클라우드 제어평면 오케스트레이션으로 인해 클러스터 생성에 약 5분, 전체 프로비저닝에 약 8분이 소요됨 (`measured L09 observation`).
- **이미지 배포 방식:**
  Local 이미지 직접 로드(`imagePullPolicy: Never`) 대신 Azure Container Registry(Basic SKU)로의 TLS 기반 원격 push/pull(`imagePullPolicy: IfNotPresent`) 경로를 사용함 (`LAB_IMPLEMENTATION / measured L09 observation`).
- **컴퓨트 Quota 및 SKU 제약:**
  Local 워크스테이션 사양과 달리, Azure 구독의 `eastus` 리전 vCPU 코어 제한(4 vCPU) 및 `Standard_D4s_v5` SKU 제한으로 인해 `Standard_D4s_v7` 단일 노드로 한정하여 실행해야 했음 (`measured L09 observation`).
- **구독 리소스 공급자 상태 영구 변경 (Persistent Subscription Drift):**
  최초 `NotRegistered` 상태였던 `Microsoft.ContainerService` 및 `Microsoft.ContainerRegistry`가 L09 사전 준비 과정에서 `Registered`로 변경되어 구독 설정의 영구 drift가 발생함 (`subscription-level persistent configuration drift, measured L09 observation`).

---

## 6. Teardown Evidence & Zero Residual Resources

실험 종료 후 `do_destroy`를 통해 클라우드 리소스가 완전 회수되었으며, Azure Resource Graph 및 CLI 조회를 통해 잔여 리소스가 0개임을 검증했다.

- **Primary Resource Group:** `rg-capacity-cascade-l09-09180624` -> `Deleted`
- **Node Resource Group:** `rg-capacity-cascade-l09-09180624-nodes` -> `Deleted`
- **Tagged Resources Remaining:** 0 (`residual_owned_resources: 0`)
- **Destroy Contract:** [`destroy-contract.json`](destroy-contract.json)

---

## 7. Cost & Budget Analysis

- **Azure Retail Prices API 기반 추정 지출액 (Estimated Spend):**
  - `Standard_D4s_v7` (eastus, Linux): $0.265 / 시간
  - `ACR Basic`: ~$0.007 / 시간 ($0.1666 / 일)
  - `Managed OS Disk (128GB)`: ~$0.015 / 시간
  - **예상 시간당 비용:** ~$0.287 / 시간
  - **전체 실행 시간:** 약 44분 (프로비저닝 8분 + 검증 25분 + 회수 8분 + 쿼리 3분)
  - **Retail-price 기반 추정 지출액:** 약 **$0.21 USD** (승인 예산 상한 $2.00 USD 대비 약 10.5% 수준)
  - *주의: 위 $0.21 USD는 확정 청구액(actual cost)이 아니며 리테일 가격표에 기반한 예상 지출액(estimated spend)이다.*
- **Azure Cost Management API 기반 실측 관측 지출액 (Cost Management Observed Spend):**
  - **상태:** `available: true` ([`cost-observation.json`](cost-observation.json))
  - **쿼리 범위:** Subscription scope, exact L09 2개 Resource Group 필터 (`rg-capacity-cascade-l09-09180624`, `rg-capacity-cascade-l09-09180624-nodes`)
  - **관측 지출액 (PreTaxCost):** 약 **223.20 KRW** (정합 수치: `223.20039963118 KRW`, `measured L09 observation`)
    - Primary RG (`rg-capacity-cascade-l09-09180624`): 약 5.43 KRW (ACR Basic 등)
    - Node RG (`rg-capacity-cascade-l09-09180624-nodes`): 약 217.77 KRW (VM Standard_D4s_v7 + Managed OS Disk)
  - **관측 시각:** 2026-09-18T14:07:02Z (`subscription_fingerprint: 6838db8ca34b`)
  - **비용 해석 주의:**
    - 위 관측값은 Azure Cost Management Query API로 확인된 실측 지출액(`Cost Management observed spend`)이며, 카드사/은행 최종 invoice 확정액을 의미하지 않는다.
    - 실행 직후에는 수집 파이프라인 지연으로 인해 `available: false`로 관찰되었으나, 수집 파이프라인 반영 후 `make l09-cost` 재조회를 통해 실측 관측 데이터가 확정되었다.
