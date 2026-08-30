# envoy-control summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | envoy-control |
| Learning Unit | L02 |
| Logical Requests | 81 |
| Physical Attempts | 81 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 0.00% |
| Logical Duration P95 | 253.00 ms |
| HTTP Request Duration P95 | 252.26 ms |
| Downstream status 200 | 81 |
| Downstream status 503 | 0 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: k6 -> l02_control_listener -> l02_control_routes -> l02_control_cluster -> auth-sim
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: not applicable
- Network toxic: not applicable
- Envoy proxy: {"listener":"l02_control_listener","route":"l02_control_routes","cluster":"l02_control_cluster","stat_prefix":"l02_control","route_timeout":"2s","retry_on":"none","num_retries":0,"circuit_breakers":{"max_connections":100,"max_pending_requests":100,"max_requests":100,"max_retries":100}}
- Retry policy: none
- Max attempts: 1

## Envoy / application delta

| Observer metric | Delta |
| --- | ---: |
| Envoy downstream requests | 81 |
| Envoy upstream attempts | 81 |
| Envoy upstream attempt amplification | 1.000x |
| Envoy retries | 0 |
| Envoy retry limit exceeded | 0 |
| Envoy timeouts | 0 |
| Envoy active overflow | 0 |
| Envoy pending overflow | 0 |
| Envoy retry overflow | 0 |
| Envoy pending requests | 29 |
| auth-sim token requests | 81 |

Metric 이름과 before/after absolute value는 `envoy-stats-delta.json`과
`auth-sim-metrics-delta.json`에 보존했다. 이 값은 단일 local exploratory evidence다.
