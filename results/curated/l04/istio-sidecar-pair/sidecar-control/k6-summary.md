# sidecar-control summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | sidecar-control |
| Learning Unit | L04 |
| Logical Requests | 80 |
| Physical Attempts | 80 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 253.00 ms |
| HTTP Request Duration P95 | 252.40 ms |
| Downstream status 200 | 80 |
| Downstream status 503 | 0 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: non-injected k6 Job -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim
- Logical ID namespace: l04-sidecar-pair
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":100}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Max attempts: 1
