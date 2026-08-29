# baseline summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | baseline |
| Logical Requests | 26 |
| Physical Attempts | 26 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 1.00 ms |
| HTTP Request Duration P95 | 0.65 ms |

## 실행 조건

- Logical rate: 5 ops/s
- Duration: 5s
- Fault: latency_ms=0, error_rate=0, max_in_flight=0, seed=17082026
- Retry policy: none
- Max attempts: 1
