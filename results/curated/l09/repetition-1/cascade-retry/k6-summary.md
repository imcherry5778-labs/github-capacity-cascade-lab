# cascade-retry summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | cascade-retry |
| Learning Unit | L09 |
| Logical Requests | 219 |
| Physical Attempts | 508 |
| Retry Attempts | 289 |
| Retry Amplification | 2.320x |
| Logical Failure Rate | 63.93% |
| Logical Duration P95 | 1003.00 ms |
| HTTP Request Duration P95 | 1001.87 ms |


## 실행 조건

- Request path: non-injected k6 Job -> HAProxy -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim (AKS)
- Logical ID namespace: l09-cascade-pair
- Logical rate: 4 ops/s
- Duration: 20s + 60s + 20s
- Workload stages: [{"phase":"stable","rate":1,"duration":"20s"},{"phase":"peak","rate":4,"duration":"60s"},{"phase":"recovery","rate":1,"duration":"20s"}]
- Request timeout: 2s
- Fault: latency_ms=1000, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"mechanism":"Sidecar ingress connectionPool http2MaxRequests","target":1}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: bad-immediate-retry
- Retry source: client only
- Max attempts: 3
