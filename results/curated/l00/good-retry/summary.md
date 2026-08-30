# good-retry summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | good-retry |
| Logical Requests | 25 |
| Physical Attempts | 39 |
| Retry Attempts | 14 |
| Retry Amplification | 1.560x |
| Logical Failure Rate | 8.00% |
| Logical Duration P95 | 65.40 ms |
| HTTP Request Duration P95 | 0.59 ms |

## 실행 조건

- Logical rate: 5 ops/s
- Duration: 5s
- Fault: latency_ms=0, error_rate=0.35, max_in_flight=0, seed=17082026
- Retry policy: good-bounded-backoff-jitter
- Max attempts: 3
