# chaos-network-delay summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | chaos-network-delay |
| Learning Unit | L08 |
| Logical Requests | 210 |
| Physical Attempts | 210 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 22.86% |
| Logical Duration P95 | 1202.00 ms |
| HTTP Request Duration P95 | 1201.70 ms |


## 실행 조건

- Request path: non-injected k6 Job -> HAProxy -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim
- Logical ID namespace: l08-chaos
- Logical rate: 3 ops/s
- Duration: 70s
- Workload stages: not applicable
- Request timeout: 2s
- Fault: latency_ms=undefined, error_rate=undefined, max_in_flight=undefined, seed=undefined
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Retry source: none
- Max attempts: 1
