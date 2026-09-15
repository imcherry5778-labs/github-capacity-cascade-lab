# Project scope

## Project purpose

GitHub의 2026-08-17 공개 RCA에서 드러난 capacity cascade와 retry amplification의
failure effect를 작은 실험 단위로 학습한다. 이 프로젝트는 GitHub 내부 시스템의
복제품이나 incident 전체 재현이 아니다.

## Official source boundary

- August 17의 Core FACT는 [Source Register](source-register.md)의
  `PRIMARY_INCIDENT_SOURCE`가 직접 지원하는 범위로 제한한다.
- 2026 reliability context는 capacity, isolation, coupling, load shedding과 migration의
  program 방향을 설명하지만 August 17의 exact cause나 topology를 입증하지 않는다.
- Historical GitHub architecture는 발행 당시 context일 뿐 August 17, 2026 topology 또는
  configuration proof가 아니다.
- Component documentation은 `LAB_IMPLEMENTATION`의 config, metric, version과 command
  contract에만 사용한다.
- August 6, August 26 등 related incident는 [August 17 timeline](incident-timeline.md)과
  Core FACT에 합치지 않는다.

## Core research question

**What happens when failures generate more traffic than users?**

Logical request 수보다 physical attempt 수가 커지는 조건, 그 증가가 제한된 capacity와
복구 과정에 미치는 영향, 완화책의 trade-off를 재현 가능한 evidence로 설명한다.

## L00 goal

후속 proxy, service mesh, autoscaling, Kubernetes, chaos, cloud 실험이 공통으로 사용할
수 있는 최소 기반을 만든다.

- 통제 가능한 Go workload와 runtime fault control
- logical request / physical attempt를 구분하는 k6 harness
- low-cardinality application metrics
- 덮어쓰지 않는 structured local evidence
- 로컬 build/test/smoke와 명시적 Docker image
- source integrity 문서와 단계별 roadmap

## In scope

- Go 1.26 standard-library HTTP server와 Prometheus Go client
- `/token`, `/auth/status`, `/healthz`, `/readyz`, `/metrics`
- 별도 admin server의 `GET/PUT /admin/fault`
- context-aware latency, deterministic error, fast admission rejection
- smoke, baseline, latency, bad-retry, good-retry k6 scenario
- Makefile, local runner, multi-stage Dockerfile
- L00 unit/integration-style test와 local exploratory evidence

## Out of scope

L00에서는 다음을 구현하지 않는다.

- GitHub의 private topology, Token Service, gateway 또는 VS Code retry 복제
- Docker Compose, Toxiproxy, HAProxy, Envoy, Istio, Kubernetes, Helm
- HPA, KEDA, Prometheus server, Grafana, Chaos Mesh
- Azure, Terraform/OpenTofu, GitHub Actions workflow
- Kafka, Valkey, relational database, 실제 JWT/인증, GitHub API
- Istio Ambient와 external DevOps delivery continuity extension

이 항목은 필요 단계에서만 `Planned` 카드로 다룬다.

## L01 goal

Application 앞의 proxy capacity/queue와 network fault를 서로 다른 request path에서
관찰한다. L00의 auth-sim, logical/physical counter와 append-only evidence를 재사용한다.

## L01 in scope

- k6 → HAProxy → auth-sim control/constrained path
- 같은 workload/service time에서 HAProxy connection capacity와 queue 비교
- k6 → Toxiproxy → auth-sim control, downstream latency, downstream TCP reset
- HAProxy CSV/Prometheus snapshot과 Toxiproxy proxy/toxic JSON state
- application fault, toxic과 Compose resource의 reset/cleanup evidence
- 명시적 HAProxy/Toxiproxy image version과 loopback-only host publish

## L01 out of scope

- GitHub의 HAProxy topology, node 수, flow algorithm, limit 또는 timeout 추정
- HAProxy와 Toxiproxy를 같은 기본 request path에 연결
- production HAProxy tuning 또는 새로운 retry mitigation
- Envoy, Istio, Kubernetes, Helm, HPA/KEDA, Chaos Mesh
- Prometheus server/Grafana, Azure/AKS, Terraform/OpenTofu, GitHub Actions
- full capacity cascade

## L02 goal

Standalone Envoy에서 downstream request가 listener/route를 거쳐 upstream auth-sim으로
전달되는 기본 lifecycle과 route timeout, bounded retry, circuit breaker의 서로 다른 효과를
before/after metric delta로 관찰한다.

## L02 in scope

- k6 host → dynamic loopback Envoy listener → static route/cluster → auth-sim public path
- scenario별 listener, route, cluster와 HCM `stat_prefix`
- control/timeout, retry-disabled/retry-bounded, control/circuit-breaker 단일 변수 비교
- k6 retry `none`, max attempts 1과 Envoy internal retry attempt의 분리
- Envoy `v1.39.1` actual version, text/Prometheus stats와 auth-sim Prometheus snapshot
- actual `upstream_rq_retry`, `upstream_rq_timeout`, `upstream_rq_active_overflow` delta
- dynamic loopback admin port, 실행별 Compose project, reset/down/잔여 resource 0 evidence

## L02 out of scope

- GitHub의 실제 proxy 종류/version/topology 또는 timeout/retry/circuit-breaker 설정 추정
- HAProxy/Toxiproxy를 Envoy request path에 연결하거나 full cascade를 구성
- Envoy Gateway, Istio, Kubernetes, Helm, xDS control plane, service mesh
- TLS/mTLS, HTTP/2, HTTP/3, gRPC, tracing, Lua, WASM
- Prometheus server, Grafana, production tuning 또는 보편적 성능/안정성 결론
- HPA/KEDA, Chaos Mesh, Azure/AKS, Terraform/OpenTofu, GitHub Actions

## L03 goal

이후 mesh/scaling 실험이 재사용할 수 있도록 기존 auth-sim을 작은 local Kubernetes에
배포하고, readiness, Service backend, Pod replacement, resource observation과 전체
lifecycle cleanup을 한 baseline에서 검증한다.

## L03 in scope

- server 1개, agent 0개의 local k3d/K3s cluster와 pinned K3s image
- 기존 auth-sim Docker image build와 k3d local image import
- replica 1개의 최소 Helm Deployment와 public `ClusterIP` Service
- `/readyz` readiness, `/healthz` liveness와 명시적 CPU/memory requests/limits
- Deployment-driven Pod replacement 전후 name/UID/readiness
- Service selector와 EndpointSlice backend 연결
- public Service와 admin Deployment를 위한 분리된 loopback port-forward
- 기존 L00 smoke의 logical/physical/no-retry contract 재사용
- Metrics API의 단일 시점 node/Pod usage snapshot
- Helm install/uninstall, namespace와 cluster delete, container/network/process cleanup evidence
- global context를 건드리지 않는 실행별 임시 kubeconfig

## L03 out of scope

- GitHub production Kubernetes topology, resource 또는 configuration 추정
- Envoy/Istio sidecar, Ambient, Ingress, Gateway, TLS/mTLS
- HPA/KEDA, autoscaling experiment, Chaos Mesh 또는 artificial resource exhaustion
- Prometheus server, Grafana, Loki, tracing, ServiceMonitor
- PersistentVolume, database, Kafka, multi-node HA 또는 cloud parity
- Azure/AKS, Terraform/OpenTofu, GitHub Actions, Argo CD
- production security/performance tuning 또는 단일 snapshot 기반 production sizing

## L04 goal

L03 baseline의 automatic Istio sidecar에서 auth-sim application과 proxy의 서로 다른 capacity
boundary를 같은 workload로 관찰한다. HPA blind spot은 L05의 별도 질문으로 남긴다.

## L04 in scope

- pinned Istio Helm `istio-base`와 `istiod`, namespace-level automatic injection
- auth-sim + injected istio-proxy Ready 2/2, proxy image/build/config/stats actual discovery
- injection이 없는 k6 Job → ClusterIP Service → target inbound sidecar → auth-sim public 8080 path
- control/constrained fresh namespace pair와 Sidecar `inboundConnectionPool` active-request target
- no-client/no-proxy retry contract, application admission unlimited와 deterministic error 0
- bounded before/during/after application/proxy samples, actual overflow/rejection mapping과 cleanup evidence
- selected 1.30.4 generated inbound retry를 제거하기 위한 exact `SIDECAR_INBOUND` EnvoyFilter fallback

## L04 out of scope

- GitHub exact Istio/Kubernetes/topology/resource/concurrency/autoscaling configuration 추정
- HPA, KEDA, autoscaling object/policy comparison 또는 sidecar-aware scale decision
- Istio Gateway, Gateway API, Ingress, Ambient, ztunnel, Istio CNI, mTLS/security policy
- Prometheus server, Grafana, Kiali, tracing, mesh-wide telemetry or production sizing
- retry behavior experiment, full cascade, HAProxy coupling, Chaos Mesh, multi-node/cloud/AKS/CI
- GitHub incident error/RPS/10x value를 local acceptance target으로 사용

## Core vs Optional Extension

- **Core:** L00–L10. 최소 workload에서 시작해 proxy, sidecar metric, autoscaling blind
  spot, cascade, mitigation, chaos, AKS validation, portfolio evidence로 진행한다.
- **Optional Extension:** L11 sidecar vs ambient 비교, L12 external delivery continuity.
  Core research question 완료에 필수 조건이 아니다.

## Definition of project completion

Core project는 다음 조건을 모두 만족할 때 완료로 본다.

1. L00–L10 카드의 `Done` 기준이 실제 evidence로 충족된다.
2. 비교 실험은 같은 workload/config/version으로 최소 3회 반복된다.
3. 실패한 run을 포함한 evidence와 재현 metadata가 보존된다.
4. FACT, INFERENCE, LAB_IMPLEMENTATION, UNKNOWN이 문서와 발표에서 구분된다.
5. GitHub 내부 구현을 복제했다는 과장 없이 관찰과 한계를 설명한다.
6. final demo가 clean checkout에서 재현 가능한 경로를 제공한다.

Optional Extension의 완료 여부는 core project completion을 막지 않는다.
