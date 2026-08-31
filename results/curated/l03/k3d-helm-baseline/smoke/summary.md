# smoke summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | smoke |
| Learning Unit | L03 |
| Logical Requests | 1 |
| Physical Attempts | 1 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 1.00 ms |
| HTTP Request Duration P95 | 4.47 ms |


## 실행 조건

- Request path: host k6 -> loopback kubectl port-forward -> ClusterIP Service -> auth-sim Pod
- Logical rate: not applicable
- Duration: single iteration
- Request timeout: 2s
- Fault: latency_ms=0, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: not applicable
- Network toxic: not applicable
- Envoy proxy: not applicable
- Retry policy: none
- Max attempts: 1
