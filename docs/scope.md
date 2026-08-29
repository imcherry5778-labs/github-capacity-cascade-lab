# Project scope

## Project purpose

GitHub의 2026-08-17 공개 RCA에서 드러난 capacity cascade와 retry amplification의
failure effect를 작은 실험 단위로 학습한다. 이 프로젝트는 GitHub 내부 시스템의
복제품이나 incident 전체 재현이 아니다.

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
