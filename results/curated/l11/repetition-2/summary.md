# L11 sidecar vs ambient ztunnel comparison summary

> 이 실행은 단일 local exploratory evidence이며 production benchmark나 어느 architecture가
> 우월하다는 결론이 아니다. Sidecar와 ztunnel-only ambient의 capacity control point는
> 구조적으로 달라 NON-EQUIVALENT다.

| Scenario | Contract | Logical requests | Logical failure rate |
| --- | --- | ---: | ---: |
| sidecar | true | 80 | 0 |
| ambient-ztunnel | true | 81 | 0 |

## Pair and cleanup

- Pair/root contract: true
- Istio: 1.30.4, pinned Helm base/istiod/cni/ztunnel; no waypoint, no Gateway API CRD, no HPA
- Workload: non-injected pinned k6 Job -> ClusterIP Service -> (sidecar) istio-proxy / (ambient) destination node ztunnel -> auth-sim
- Retry: k6 none/max attempts 1; sidecar inbound route retry policy removed via EnvoyFilter; ztunnel has no HTTP-level retry to disable
- Only intended comparison variable: destination proxy placement (Pod-local sidecar vs node-local ztunnel); no artificial capacity parity
- Cleanup: scenario resources=true, Istio=true/true/true/true, namespaces=true, cluster=true
- Residue: containers=0, networks=0, processes=0
- Temporary kubeconfig/Helm state removed: true/true
- Original kube context/global Helm repository config unchanged: true/true

Generated config, actual metric mapping과 timestamped samples는 scenario directory에 보존했다.
