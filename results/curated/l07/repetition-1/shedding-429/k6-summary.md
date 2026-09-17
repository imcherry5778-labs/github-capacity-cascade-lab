# shedding-429 summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | shedding-429 |
| Learning Unit | L07 |
| Logical Requests | 220 |
| Physical Attempts | 220 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 80.45% |
| Logical Duration P95 | 1003.00 ms |
| HTTP Request Duration P95 | 1002.24 ms |
| Downstream status 200 | 43 |
| Downstream status 429 | 131 |
| Downstream status 503 | 46 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim
- Logical ID namespace: l07-shedding-429
- Logical rate: 4 ops/s
- Duration: 20s + 60s + 20s
- Workload stages: [{"phase":"stable","target":1,"duration":"20s"},{"phase":"ramp-up","target":4,"duration":"60s"},{"phase":"ramp-down","target":1,"duration":"20s"}]
- Request timeout: 2s
- Fault: latency_ms=1000, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Retry source: none
- Max attempts: 1
