# toxiproxy-reset-peer summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | toxiproxy-reset-peer |
| Learning Unit | L01 |
| Logical Requests | 81 |
| Physical Attempts | 81 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 100.00% |
| Logical Duration P95 | 3.00 ms |
| HTTP Request Duration P95 | 2.02 ms |

## 실행 조건

- Request path: k6 -> Toxiproxy -> auth-sim
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=0, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: not applicable
- Network toxic: {"name":"l01_reset_peer_downstream","type":"reset_peer","stream":"downstream","toxicity":1,"attributes":{"timeout":0}}
- Retry policy: none
- Max attempts: 1
