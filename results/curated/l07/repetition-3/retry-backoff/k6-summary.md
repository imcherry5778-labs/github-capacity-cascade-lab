# retry-backoff summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | retry-backoff |
| Learning Unit | L07 |
| Logical Requests | 220 |
| Physical Attempts | 545 |
| Retry Attempts | 325 |
| Retry Amplification | 2.477x |
| Logical Failure Rate | 60.91% |
| Logical Duration P95 | 1201.65 ms |
| HTTP Request Duration P95 | 1002.20 ms |
| Downstream status 200 | 86 |
| Downstream status 429 | 0 |
| Downstream status 503 | 134 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: non-injected k6 Job -> HAProxy -> ClusterIP Service -> istio-proxy -> auth-sim
- Logical ID namespace: l07-retry-backoff
- Logical rate: 4 ops/s
- Duration: 20s + 60s + 20s
- Workload stages: [{"phase":"stable","target":1,"duration":"20s"},{"phase":"ramp-up","target":4,"duration":"60s"},{"phase":"ramp-down","target":1,"duration":"20s"}]
- Request timeout: 2s
- Fault: latency_ms=1000, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: good-bounded-backoff-jitter
- Retry source: client only
- Max attempts: 3
