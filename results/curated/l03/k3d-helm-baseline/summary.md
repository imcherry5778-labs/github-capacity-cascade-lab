# L03 k3d and Helm baseline summary

> 이 실행은 단일 local exploratory evidence이며 performance benchmark나 production sizing 근거가 아니다.

| Observation | Result |
| --- | --- |
| Contract | true |
| Node Ready | true |
| Deployment Available | true |
| Initial Pod | auth-sim-5548b49c55-4srcb / f40cd024-dfc0-475c-a082-e15e9f51eed8 / ready=true |
| Replacement Pod | auth-sim-64dff7bbc8-pz7wd / a3d996f6-74f8-47c4-9b36-9a02b6eaea86 / ready=true |
| Pod UID changed | true |
| Service backend ready after replacement | true |
| Node usage snapshot | 483m CPU, 433Mi memory |
| Pod usage snapshot | 3m CPU, 2Mi memory |
| L00 smoke logical / physical / retry | 1 / 1 / 0 |
| Helm release removed | true |
| Namespace removed | true |
| Cluster removed | true |
| Remaining cluster containers / networks | 0 / 0 |
| Remaining tracked port-forwards | 0 |
| Temporary kubeconfig removed | true |
| Original kube context unchanged | true |

## Interpretation boundary

- k3d/K3s topology, Helm resources, requests/limits와 port-forward access model은 모두 `LAB_IMPLEMENTATION`이다.
- `kubectl top` 값은 Metrics API의 단일 시점 local snapshot이며 historical monitoring, benchmark, production sizing이 아니다.
- Public path는 host의 loopback-only port-forward를 사용하므로 production ingress 또는 external network path를 검증하지 않는다.
- Restart observation은 container crash restart count가 아니라 Deployment-driven Pod replacement다.
