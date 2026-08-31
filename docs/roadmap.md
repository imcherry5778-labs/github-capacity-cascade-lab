# Learning roadmap

각 카드는 향후 GitHub Issue로 독립 복사할 수 있는 수준의 learning contract다. 후속
단계의 YAML, threshold, topology, Azure SKU는 해당 단계 preflight 전에는 확정하지 않는다.

## L00 — Minimal Workload and k6

- **ID:** L00
- **Title:** Minimal Workload and k6
- **Goal:** 모든 후속 단계가 재사용할 통제 가능한 workload, retry 측정, evidence 기반을 만든다.
- **Learn:** Logical request와 physical attempt가 어떻게 달라지는지 이해한다.
- **Build:** Go `auth-sim`, runtime fault API, Prometheus metrics, 5개 k6 scenario, local runner, Docker/Make 흐름.
- **Observe:** Fault별 status, latency, in-flight, rejection, retry amplification, logical failure.
- **Done:** Go verify, k6 inspect/smoke, 4개 scenario 실행, evidence/secret/process 검증, Docker build/smoke가 통과한다.
- **Non-goals:** Proxy, Kubernetes, autoscaling, cloud, 실제 authentication.
- **Dependencies:** Git, Go 1.26+, k6, Make; Docker verification에는 Docker daemon.
- **Status:** Complete — implementation verified; 생성 결과는 local exploratory evidence.

## L01 — HAProxy and Toxiproxy Fundamentals

- **ID:** L01
- **Title:** HAProxy and Toxiproxy Fundamentals
- **Goal:** Application 앞의 proxy capacity와 network fault를 각각 분리해 관찰한다.
- **Learn:** Connection/flow pressure, timeout, queue, network degradation이 request outcome에 미치는 차이를 이해한다.
- **Build:** 최소 HAProxy path와 독립적인 Toxiproxy fault experiment.
- **Observe:** Proxy connection/queue/error와 L00 logical/physical counters의 관계.
- **Done:** 정상, latency, connection fault를 서로 혼동하지 않고 재현·reset·증명한다.
- **Non-goals:** GitHub HAProxy topology 복제, Envoy/Istio, Kubernetes.
- **Dependencies:** L00.
- **Status:** Complete — implementation verified; 생성 결과는 local exploratory evidence.

## L02 — Envoy Fundamentals

- **ID:** L02
- **Title:** Envoy Fundamentals
- **Goal:** Envoy의 기본 request lifecycle과 bounded retry behavior를 standalone 환경에서 학습한다.
- **Learn:** Upstream cluster, timeout, retry, circuit-breaking signal의 역할을 구분한다.
- **Build:** Static bootstrap standalone Envoy, scenario별 listener/route/cluster, no-retry k6 workload, before/after stats와 cleanup contract.
- **Observe:** Downstream request, upstream attempt, timeout, bounded retry, active overflow와 application token request delta의 차이.
- **Done:** Control/timeout, retry-disabled/bounded, control/circuit-breaker pair를 독립 실행하고 실제 v1.39.1 metric과 local evidence로 설명한다.
- **Non-goals:** Istio control plane, service mesh 전체, production tuning.
- **Dependencies:** L00; L01의 proxy 관찰 경험.
- **Status:** Complete — implementation verified; 생성 결과는 local exploratory evidence.

## L03 — k3d and Helm Baseline

- **ID:** L03
- **Title:** k3d and Helm Baseline
- **Goal:** 이후 mesh/scaling 실험을 위한 작은 Kubernetes baseline을 만든다.
- **Learn:** Local cluster resource limit와 workload lifecycle이 측정에 미치는 영향을 이해한다.
- **Build:** k3d cluster와 최소 Helm packaging, 반복 가능한 install/uninstall 경로.
- **Observe:** Pod readiness, resource usage, restart, service request path.
- **Done:** Clean bootstrap부터 L00 smoke까지 재현되고 소유 resource가 정리된다.
- **Non-goals:** Istio, HPA, Chaos Mesh, cloud parity.
- **Dependencies:** L00.
- **Status:** Complete — implementation verified; 생성 결과는 local exploratory evidence.

## L04 — Istio Sidecar and Proxy Metrics

- **ID:** L04
- **Title:** Istio Sidecar and Proxy Metrics
- **Goal:** 같은 Pod의 auth-sim application과 inbound Istio sidecar proxy의 capacity/metric 경계를 직접 관찰한다.
- **Learn:** Application metric만으로 proxy-side saturation을 판정할 수 없는 이유와 counter boundary를 구분한다.
- **Build:** Pinned Istio Helm control plane, namespace automatic injection, Sidecar inbound connection-pool pair, bounded proxy/application observation.
- **Observe:** Application in-flight/admission, proxy downstream/upstream/active/overflow/retry와 timestamped before/during/after 관계.
- **Done:** Actual injected Pod 2/2, sidecar traversal counter delta, generated `100 → 1` inbound capacity diff, control overflow 0/constrained overflow > 0, application admission rejection 0, no-retry와 exact cleanup을 local evidence로 확인한다.
- **Non-goals:** GitHub sidecar setting 복제, HPA/KEDA/autoscaling comparison, Ambient, CNI, gateway, Prometheus/Grafana, ingress gateway 또는 production tuning.
- **Dependencies:** L03; L02 권장.
- **Source prerequisite:** [Source Register](source-register.md)와 [August 17 timeline](incident-timeline.md)의 incident/context 경계를 유지한다.
- **Status:** Complete — implementation verified; 생성 결과는 local exploratory evidence.

## L05 — HPA Blind Spot

- **ID:** L05
- **Title:** HPA Blind Spot
- **Goal:** Scaling metric이 실제 bottleneck capacity를 반영하지 않을 때 생기는 blind spot을 축소 재현한다.
- **Learn:** Observed metric, scaling decision, saturated component 사이의 mismatch를 이해한다.
- **Build:** 한 개의 명확한 blind-spot experiment와 개선 metric 비교.
- **Observe:** Desired/current replicas, application load, sidecar signal, rejection과 latency.
- **Done:** 동일 workload에서 blind policy와 capacity-aware policy의 차이를 반복 evidence로 제시한다.
- **Non-goals:** GitHub의 정확한 HPA config 주장, production recommendation 일반화.
- **Dependencies:** L03, L04.
- **Status:** Planned — next.

## L06 — Full Capacity Cascade

- **ID:** L06
- **Title:** Full Capacity Cascade
- **Goal:** 앞 단계의 mechanism을 연결해 failure가 추가 traffic을 만드는 cascade를 관찰한다.
- **Learn:** Saturation, rejection/timeout, retry amplification, downstream pressure의 피드백 순환을 이해한다.
- **Build:** 최소 components만 연결한 end-to-end lab scenario.
- **Observe:** Logical rate 대비 physical rate, component별 capacity, failure propagation과 recovery time.
- **Done:** Cascade 시작·확산·회복이 timestamped evidence와 제한사항으로 설명된다.
- **Non-goals:** GitHub incident 전체 또는 private topology 재현, 임의의 10x 목표 맞추기.
- **Dependencies:** L01–L05.
- **Status:** Planned.

## L07 — RCA Mitigations

- **ID:** L07
- **Title:** RCA Mitigations
- **Goal:** 공개 RCA가 지시한 완화 방향을 lab mechanism으로 분리 비교한다.
- **Learn:** Retry limit/backoff, load shedding, capacity-aware scaling, gradual ramp-up의 trade-off를 이해한다.
- **Build:** 한 번에 한 mitigation만 바꾸는 비교 matrix와 reset 가능한 run path.
- **Observe:** Amplification, logical success, tail latency, rejection, recovery behavior.
- **Done:** 최소 3회 반복된 동일 조건 비교와 부작용/한계가 기록된다.
- **Non-goals:** GitHub의 실제 mitigation code 또는 exact setting 복제.
- **Dependencies:** L06.
- **Status:** Planned.

## L08 — Chaos Mesh Reproduction

- **ID:** L08
- **Title:** Chaos Mesh Reproduction
- **Goal:** 수동 fault를 선언적이고 시간 제어 가능한 chaos experiment로 옮긴다.
- **Learn:** Fault timing, blast radius, cleanup과 evidence correlation의 중요성을 이해한다.
- **Build:** 최소 Chaos Mesh experiment와 안전한 preflight/cleanup.
- **Observe:** Scheduled fault window와 application/proxy/scaling signal의 정렬.
- **Done:** Abort와 cleanup을 포함해 반복 가능하며 cluster 외부에 영향이 없다.
- **Non-goals:** 광범위 chaos program, production cluster 실행.
- **Dependencies:** L03, L06, L07.
- **Status:** Planned.

## L09 — Azure AKS Validation

- **ID:** L09
- **Title:** Azure AKS Validation
- **Goal:** Local conclusion 중 어떤 부분이 managed Kubernetes 환경에서도 유지되는지 검증한다.
- **Learn:** Local/cloud capacity, network, autoscaling 관찰 차이와 비용 경계를 이해한다.
- **Build:** 별도 승인·비용 preflight 후 최소 AKS validation environment와 destroy evidence.
- **Observe:** Local과 같은 핵심 metric, cloud-specific limitation, 실제 비용.
- **Done:** Provision/destroy, 비용, 결과, drift와 한계가 증명되고 잔여 resource가 없다.
- **Non-goals:** GitHub Central US infrastructure 매핑, production architecture, SKU 사전 확정.
- **Dependencies:** L07–L08; explicit cloud authorization and budget.
- **Status:** Planned.

## L10 — Portfolio Evidence and Demo

- **ID:** L10
- **Title:** Portfolio Evidence and Demo
- **Goal:** 실험을 검토 가능한 SRE narrative와 재현 demo로 정리한다.
- **Learn:** 측정, 인과 한계, mitigation trade-off를 과장 없이 전달하는 방법을 익힌다.
- **Build:** Curated evidence, diagram, demo runbook, 발표/녹화 흐름.
- **Observe:** Clean checkout reproducibility, audience가 확인할 핵심 signals, demo failure path.
- **Done:** Source integrity, 최소 3회 비교, limitation, 재현 명령이 하나의 package로 검토된다.
- **Non-goals:** 미측정 결과 작성, 장애 spectacle, GitHub 내부 구현 주장.
- **Dependencies:** L00–L09의 검증된 core evidence.
- **Status:** Planned.

## L11 — Sidecar vs Ambient Architecture Comparison

- **ID:** L11
- **Title:** Sidecar vs Ambient Architecture Comparison
- **Goal:** 같은 연구 질문에서 sidecar와 ambient architecture의 capacity visibility 차이를 비교한다.
- **Learn:** Proxy placement가 bottleneck, scaling signal, failure domain에 미치는 영향을 이해한다.
- **Build:** Core 완료 후 동일 workload를 사용하는 최소 비교 experiment.
- **Observe:** Request path, resource/capacity signal, blast radius와 operational complexity.
- **Done:** 같은 조건의 evidence와 적용 한계를 제시한다.
- **Non-goals:** 어느 architecture가 보편적으로 우월하다는 결론, 현재 L00 scope 확대.
- **Dependencies:** L04–L10.
- **Status:** Optional / Planned.

## L12 — External DevOps Delivery Continuity Extension

- **ID:** L12
- **Title:** External DevOps Delivery Continuity Extension
- **Goal:** Source platform 장애 시 delivery continuity라는 별도 질문을 탐색한다.
- **Learn:** Runtime availability와 software delivery dependency failure를 구분한다.
- **Build:** Core lab과 격리된 최소 continuity scenario와 decision record.
- **Observe:** Dependency outage 동안 build/deploy 가능 범위와 security/consistency trade-off.
- **Done:** Core incident lab과 혼동되지 않는 독립 evidence와 limitation을 제공한다.
- **Non-goals:** 현재 범위에서 external system 도입, GitHub outage 회피를 보장한다는 주장.
- **Dependencies:** L10 완료와 별도 scope 승인.
- **Status:** Optional / Planned.
