# L04 Istio sidecar capacity summary

> 이 실행은 단일 local exploratory evidence이며 production benchmark나 GitHub topology/config evidence가 아니다.

| Scenario | Contract | Generated max requests | Logical requests | Logical failure rate | Active overflow delta |
| --- | --- | ---: | ---: | ---: | ---: |
| sidecar-control | true | 100 | 80 | 0 | 0 |
| sidecar-constrained | true | 1 | 80 | 0.825 | 66 |

## Pair and cleanup

- Pair/root contract: true
- Istio: 1.30.4, pinned Helm base/istiod, gateway/CNI/HPA 없음
- Workload: non-injected pinned k6 Job -> ClusterIP Service -> injected inbound sidecar -> auth-sim
- Application: latency 250 ms, error 0, max_in_flight 0/unlimited
- Retry: k6 none/max attempts 1; selected inbound route retry policy 없음; proxy retry delta 0
- Only intended comparison variable: inbound port 8080 http2MaxRequests 100 vs 1
- Cleanup: scenario resources=true, Istio=true/true, namespaces=true, cluster=true
- Residue: containers=0, networks=0, processes=0
- Temporary kubeconfig/Helm state removed: true/true
- Original kube context/global Helm repository config unchanged: true/true

Generated config, actual metric mapping과 timestamped samples는 scenario directory에 보존했다.
