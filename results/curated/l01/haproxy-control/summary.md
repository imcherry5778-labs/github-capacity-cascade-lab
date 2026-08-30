# haproxy-control summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | haproxy-control |
| Learning Unit | L01 |
| Logical Requests | 81 |
| Physical Attempts | 81 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 253.00 ms |
| HTTP Request Duration P95 | 252.31 ms |

## 실행 조건

- Request path: k6 -> HAProxy control -> auth-sim
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: {"frontend":"l01_control","backend":"be_l01_control","backend_server_maxconn":100,"timeout_queue":"1s","retries":0,"redispatch":false}
- Network toxic: {"type":"none"}
- Retry policy: none
- Max attempts: 1
