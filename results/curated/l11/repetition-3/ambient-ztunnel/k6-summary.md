# ambient-ztunnel summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | ambient-ztunnel |
| Learning Unit | L11 |
| Logical Requests | 81 |
| Physical Attempts | 81 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 252.00 ms |
| HTTP Request Duration P95 | 251.54 ms |


## 실행 조건

- Request path: non-injected k6 Job -> ClusterIP Service :8080 -> destination node ztunnel -> auth-sim
- Logical ID namespace: l11-sidecar-ambient-pair
- Logical rate: 20 ops/s
- Duration: 4s
- Workload stages: not applicable
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"observation_unit":"ztunnel-tcp-l4","mechanism":"node-local ztunnel inbound TCP connection/byte counters","note":"ztunnel does not terminate HTTP; there is no HTTP-level counter here. NON-EQUIVALENT to the sidecar HTTP counters above."}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Retry source: unspecified
- Max attempts: 1
