# L05 Curated Evidence

- Learning unit: **L05 — HPA Blind Spot**
- Classification: **Local exploratory evidence; fixed-condition repetition set**
- Source branch: `feat/l05-hpa-blind-spot`
- Source commit: `bc19711f514036e29c678d435903a7afd54f7318`
- Raw runs: `results/hpa-blind-spot/20260915T153531Z/`, `results/hpa-blind-spot/20260915T154330Z/`, and `results/hpa-blind-spot/20260915T155129Z/`

이 set은 clean source에서 실행한 paired local run 세 개를 포함한다. 아래 selected file은 named raw run에서 redaction이나 measured-value 편집 없이 복사했고 `cmp`로 byte-for-byte 확인했다. 세 root/scenario contract는 모두 PASS이고, 세 `metadata.json`은 `git_dirty=false`이며, 모든 `cleanup.json`은 runner exit `0`과 owned container/network/port-forward `0`을 기록한다. Failed 및 dirty-source exploratory run은 append-only raw notebook에만 남긴다.

## Runtime identity와 fixed comparison

각 repetition은 dynamic loopback API exposure의 fresh server-1/agent-0 k3d cluster, K3s `v1.35.5+k3s1`, Kubernetes server `v1.35.5+k3s1`, Istio `1.30.4`, `capacity-cascade/auth-sim:l05-bc19711f5140`, `grafana/k6:2.2.0`을 사용했다. Runner는 current Helm chart route `https://blob.istio.io/istio-release/charts`와 image hub `docker.io/istio`를 기록했다. 이는 local run의 runtime artifact source일 뿐 GitHub topology evidence가 아니다.

두 policy는 source/image, automatic Istio injection, ClusterIP Service data path, sidecar inbound `http2MaxRequests: 1` local target, application latency `1000 ms`, error `0`, application admission unlimited, logical rate `3/s`·`150 s`, request timeout `2 s`, client/proxy retry none, sampling `1 s`, HPA min/max `1/4`, scale-up/down behavior와 exact cleanup을 공유한다. 의도한 comparison variable은 HPA observed metric 하나다.

| Policy | Actual `autoscaling/v2` metric | Local target | HPA exposure |
| --- | --- | --- | --- |
| Blind | `ContainerResource` CPU for `auth-sim` only | average utilization `80%` | Built-in resource metrics API |
| Capacity-aware | Pods custom metric `sidecar_active_requests` | average value `500m` | Minimal in-cluster adapter plus `custom.metrics.k8s.io/v1beta2` APIService |

Adapter는 monitoring stack이 아닌 bounded lab component다. Pod-local exporter가 selected Envoy/application observation endpoint를 읽고, adapter의 RBAC는 namespaced Pod `get`/`list`뿐이다. Workload Service로 노출하지 않는다. Aggregation APIService는 capacity-aware scenario에서만 등록한다. `insecureSkipTLSVerify: true`는 short-lived local cluster에 한정하며 production TLS configuration이 아니다.

## Repeated actual observation

아래 값은 re-measure하지 않고 각 root [`contract.json`](repetition-1/contract.json)에서 복사했다. `200/503`, failure rate, p95는 k6에서 오며 overflow는 fresh selected proxy counter delta다. `B`는 blind, `A`는 capacity-aware다.

| Repetition | B logical / physical / retry | B 200 / 503; failure; p95 | B desired / current peak; overflow | A logical / physical / retry | A 200 / 503; failure; p95 | A desired / current peak; overflow |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 450 / 450 / 0 | 114 / 336; 0.7466666666666667; 1003 ms | 1 / 1; 336 | 450 / 450 / 0 | 274 / 176; 0.39111111111111113; 1003 ms | 2 / 2; 176 |
| 2 | 450 / 450 / 0 | 114 / 336; 0.7466666666666667; 1002 ms | 1 / 1; 336 | 451 / 451 / 0 | 291 / 160; 0.35476718403547675; 1002 ms | 2 / 2; 160 |
| 3 | 451 / 451 / 0 | 114 / 337; 0.7472283813747228; 1003 ms | 1 / 1; 337 | 450 / 450 / 0 | 299 / 151; 0.33555555555555555; 1002 ms | 2 / 2; 151 |

세 repetition에서 blind application admission rejection은 `0`, application token delta는 `114`이고 selected proxy active-overflow는 순서대로 `336`, `336`, `337`이었다. Capacity-aware application admission rejection도 `0`이며 token delta는 `274`, `291`, `299`, active-overflow는 `176`, `160`, `151`이다. 따라서 이 local fixed workload는 aware policy에서 HPA decision이 다르고 user-facing 503/overflow가 더 적다는 결과를 반복해 보인다. 이는 general scaling recommendation, benchmark나 GitHub configuration을 입증하지 않는다.

## Timestamped HPA and signal chain

`samples.jsonl`은 각 policy의 full one-second time series를 보존한다. HPA current/desired replicas, current/target metric, condition/last scale time, Pod Ready/endpoint count, selected proxy downstream/upstream/active/overflow/retry/timeout, application in-flight/token/admission counter가 포함된다. Repetition 1에서 blind final sample은 proxy active-overflow가 `336`에 도달한 뒤에도 desired/current replicas가 모두 `1`, `auth-sim` CPU가 `8%/80%`임을 보존한다. Capacity-aware HPA는 `ValidMetricFound`, actual `500m/500m`을 기록하고 `2026-09-15T15:40:04Z`에 `SuccessfulRescale: New size: 2; reason: pods metric sidecar_active_requests above target` event를 냈다.

각 repetition의 original file은 다음과 같다.

- Root identity, fixed variable, pair contract, cleanup: [`metadata.json`](repetition-1/metadata.json), [`contract.json`](repetition-1/contract.json), [`cleanup.json`](repetition-1/cleanup.json).
- Blind HPA configuration/status/time series: [`hpa-initial.json`](repetition-1/hpa-blind/hpa-initial.json), [`hpa-final.yaml`](repetition-1/hpa-blind/hpa-final.yaml), [`samples.jsonl`](repetition-1/hpa-blind/samples.jsonl), [`k6-summary.json`](repetition-1/hpa-blind/k6-summary.json).
- Capacity-aware custom-metric response/event/time series: [`custom-metric-before.json`](repetition-1/hpa-aware/custom-metric-before.json), [`hpa-events.json`](repetition-1/hpa-aware/hpa-events.json), [`hpa-final.yaml`](repetition-1/hpa-aware/hpa-final.yaml), [`samples.jsonl`](repetition-1/hpa-aware/samples.jsonl).

`repetition-2/`와 `repetition-3/`은 같은 selected file layout을 보존한다. 각 scenario directory에는 actual target inbound cluster/route evidence, workload state, Pod/Deployment/Service state, proxy metric mapping, k6 identity/result, scenario contract와 summary도 있다.

## Selection boundary and limitations

Full config dump, rendered manifest, command/port-forward/Secret lifecycle log, temporary file, failed/raw-only run은 의도적으로 curate하지 않았다. 이 selection에는 token, credential, kubeconfig, complete environment dump나 private absolute path가 없다.

- Sidecar capacity `1`, HPA threshold, 150-second workload, adapter, HPA behavior, local topology와 모든 image/version 선택은 `LAB_IMPLEMENTATION`이다.
- 이 결과는 application container에만 scope된 metric이 target 아래에 머무는 동안 별도로 관찰한 sidecar capacity boundary가 traffic을 거절할 수 있다는 narrow local inference를 지원한다.
- GitHub의 exact HPA metric/threshold/stabilization behavior, sidecar capacity mechanism/value, Pod/resource topology, custom-metric plumbing, production TLS configuration은 `UNKNOWN`이다.
- L06 retry/cascade coupling, KEDA, Prometheus/Grafana, Gateway/Ambient/CNI, cloud/AKS와 production tuning은 L05 범위 밖이다.
