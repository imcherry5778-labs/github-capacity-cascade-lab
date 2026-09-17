# ramp-steep summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | ramp-steep |
| Learning Unit | L07 |
| Logical Requests | 220 |
| Physical Attempts | 220 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 70.91% |
| Logical Duration P95 | 1003.00 ms |
| HTTP Request Duration P95 | 1002.34 ms |
| Downstream status 200 | 64 |
| Downstream status 429 | 0 |
| Downstream status 503 | 156 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim
- Logical ID namespace: l07-ramp-steep
- Logical rate: 4 ops/s
- Duration: 30s + 1s + 39s + 1s + 29s
- Workload stages: [{"phase":"stable","target":1,"duration":"30s"},{"phase":"ramp-up","target":4,"duration":"1s"},{"phase":"peak","target":4,"duration":"39s"},{"phase":"ramp-down","target":1,"duration":"1s"},{"phase":"recovery","target":1,"duration":"29s"}]
- Request timeout: 2s
- Fault: latency_ms=1000, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Retry source: none
- Max attempts: 1
