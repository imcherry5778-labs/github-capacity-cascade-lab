# sidecar summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | sidecar |
| Learning Unit | L11 |
| Logical Requests | 80 |
| Physical Attempts | 80 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 253.00 ms |
| HTTP Request Duration P95 | 252.31 ms |


## 실행 조건

- Request path: non-injected k6 Job -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim
- Logical ID namespace: l11-sidecar-ambient-pair
- Logical rate: 20 ops/s
- Duration: 4s
- Workload stages: not applicable
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"observation_unit":"sidecar-http-l7","mechanism":"Pod-local istio-proxy inbound HTTP downstream/upstream counters","note":"No artificial capacity constraint in L11; this is a visibility/ownership baseline, not a saturation target."}
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Retry source: unspecified
- Max attempts: 1
