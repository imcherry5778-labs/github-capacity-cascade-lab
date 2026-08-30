# L03 Curated Evidence

- Learning unit: **L03 — k3d and Helm Baseline**
- Classification: **Local exploratory evidence**
- Source branch: `feat/l03-k3d-helm-baseline`
- Source commit: `926336252c9118f17eb6e4fc52cc4c261fc25612`
- L03 implementation commit: `5a77ecb`
- Source raw run: `results/k3d-helm-baseline/20260830T134044Z/`
- Curated scenario: [`k3d-helm-baseline/`](k3d-helm-baseline/)

이 curated set은 clean source commit에서 server 1개, agent 0개의 local k3d/K3s cluster를
생성하고 기존 auth-sim image를 import한 뒤, Helm deploy, Deployment-driven Pod replacement,
Metrics API snapshot, 기존 L00 smoke와 전체 cleanup을 확인한 단일 baseline run의 사본이다.
Source metadata는 `git_dirty=false`이고 `contract.json`과 `cleanup.json`은 모든 요구 조건을
통과했다.

## Runtime identity and topology

| Item | Observed value |
| --- | --- |
| k3d / default K3s | `v5.9.0` / `v1.35.5-k3s1` |
| Selected K3s image | `rancher/k3s:v1.35.5-k3s1` |
| Kubernetes server / kubectl client | `v1.35.5+k3s1` / `v1.36.1` |
| Helm | `v4.2.3` |
| Topology | server 1, agent 0, k3d API load balancer |
| Disabled packaged components | Traefik, ServiceLB, local-storage |
| Chart / release / namespace | `charts/auth-sim` / `auth-sim` / `capacity-cascade-l03` |
| auth-sim image | `capacity-cascade/auth-sim:l03-926336252c91` |
| Docker image ID | `sha256:9b653a21b08a4f261451ab210c5a9f89e52f7cbec4de812ae93651a9aa9b8cb4` |
| Pull policy | `Never` |

Kubernetes API, public Service와 admin Deployment port-forward는 모두 host loopback의 동적
port만 사용했다. Public Service는 `ClusterIP`와 named `public` port `8080`만 노출했고,
admin `9090`은 Service에 포함하지 않았다. Admin credential은 ephemeral Secret으로 만들었고
Secret data나 kubeconfig 내용은 evidence에 보존하지 않았다.

## Readiness, replacement and backend

| Observation | Result |
| --- | --- |
| Node Ready | PASS |
| Deployment Available | PASS |
| Initial Pod | `auth-sim-5548b49c55-4srcb` / `f40cd024-dfc0-475c-a082-e15e9f51eed8` / Ready |
| Replacement Pod | `auth-sim-64dff7bbc8-pz7wd` / `a3d996f6-74f8-47c4-9b36-9a02b6eaea86` / Ready |
| Pod UID changed | PASS |
| Replacement EndpointSlice backend | replacement UID / `ready: true` |
| L00 smoke logical / physical / retry | `1 / 1 / 0` |
| L00 smoke logical failure | `0.00%` |

이 restart는 container crash restart count 증가가 아니라 `kubectl rollout restart`로 수행한
Deployment-driven Pod replacement다. 새 Pod가 Ready가 된 뒤 EndpointSlice가 새 UID를 ready
backend로 참조했고, 그 다음 Service와 admin에 별도 port-forward를 열어 기존 L00 smoke를
실행했다.

## Resource target and observed snapshot

| Resource | Request | Limit | Single observed usage |
| --- | ---: | ---: | ---: |
| auth-sim Pod | `25m` CPU / `32Mi` memory | `250m` CPU / `128Mi` memory | `3m` CPU / `2Mi` memory |
| k3d server node | — | — | `483m` CPU / `433Mi` memory |

Requests/limits는 local smoke를 안정적으로 실행하기 위한 `lab target`이고 usage는 Metrics API의
단일 시점 snapshot이다. 이 값은 historical monitoring, performance benchmark,
machine-independent result 또는 production sizing 근거가 아니다.

## Cleanup

- Helm release absent: PASS
- Namespace와 ephemeral Secret absent: PASS
- Exact k3d cluster absent: PASS
- Remaining cluster containers/networks: `0 / 0`
- Remaining tracked port-forward processes: `0`
- Temporary kubeconfig removed: PASS
- Original current-context unchanged: PASS (`unset` 상태 유지)

## Selection and retained files

다음 category를 source raw run에서 byte-for-byte 동일하게 복사했다.

- Run identity/판정: `metadata.json`, `summary.md`, `contract.json`, `cleanup.json`
- Runtime/Node: Kubernetes version, Node Ready/capacity/allocatable와 Metrics API state
- Workload: initial/after-replacement Deployment·ReplicaSet·Pod·Service state, Service와
  before/after EndpointSlice, requests/limits
- Replacement: initial/replacement Pod identity와 rollout command/status
- Resource usage: `top-nodes.txt`, `top-pods.txt`
- Helm/image lifecycle: image import, install/status, uninstall/list와 namespace/cluster delete
- Smoke: `smoke/metadata.json`, `smoke/k6-summary.json`, `smoke/summary.md`

전체 Docker build/k3d create log, rendered chart, empty transient error log, Secret creation log,
port-forward log와 k6 console log는 noisy하거나 source/config/summary와 중복되어 raw notebook에만
남겼다. Redaction은 적용하지 않았고 measured value를 수정하지 않았다.

## Meaningful development observations

- `20260830T133033Z`는 k3d v5.9.0이 `127.0.0.1:0`을 Docker에 동적 publish하면서도 출력
  kubeconfig에 literal port `0`을 남겨 kubectl 연결이 실패했다. Summary Markdown의 unescaped
  backtick도 cleanup 중 shell command substitution으로 해석됐다. 실패 raw run을 보존하고,
  실제 Docker loopback binding을 임시 kubeconfig에만 반영하며 backtick을 escape했다.
- `20260830T133137Z`는 lifecycle contract는 통과했지만 readonly shell 변수와 k6 environment
  이름이 충돌해 경고가 발생하고 smoke metadata의 image identity가 비었다. 해당 raw run을
  선별하지 않고 내부 변수명을 분리한 뒤 새 timestamp에서 검증했다.
- 최종 source run 전 local import를 더 직접적으로 검증하도록 pull policy를 `Never`로 바꾸고,
  필요 없는 default service-account token mount를 비활성화했다. 두 변경은 별도 development
  lifecycle에서 통과한 뒤 source commit에 포함됐다.

## Limitations

- 단일 local machine의 exploratory evidence이며 portfolio final evidence가 아니다.
- Production benchmark, production sizing, cloud parity 또는 GitHub production topology
  evidence가 아니다.
- k3d/K3s topology, Helm chart, resource target, image import와 port-forward model은 모두
  `LAB_IMPLEMENTATION`이다.
- Port-forward는 production ingress, external load balancer, network path나 TLS/mTLS를
  검증하지 않는다.
- Istio, HPA/KEDA, Chaos Mesh, Prometheus/Grafana와 AKS는 포함하지 않았다.
- Portfolio comparison이나 일반화 가능한 해석에는 동일 조건 최소 3회 반복이 필요하다.
