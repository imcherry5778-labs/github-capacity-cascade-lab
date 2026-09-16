# hpa-blind summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | hpa-blind |
| Learning Unit | L05 |
| Logical Requests | 451 |
| Physical Attempts | 451 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 74.72% |
| Logical Duration P95 | 1003.00 ms |
| HTTP Request Duration P95 | 1001.97 ms |
| Downstream status 200 | 114 |
| Downstream status 503 | 337 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: non-injected k6 Job -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim
- Logical ID namespace: l05-hpa-pair
- Logical rate: 3 ops/s
- Duration: 150s
- Request timeout: 2s
- Fault: latency_ms=1000, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Max attempts: 1
