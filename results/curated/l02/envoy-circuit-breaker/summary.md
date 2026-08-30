# envoy-circuit-breaker summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | envoy-circuit-breaker |
| Learning Unit | L02 |
| Logical Requests | 80 |
| Physical Attempts | 80 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 82.50% |
| Logical Duration P95 | 252.00 ms |
| HTTP Request Duration P95 | 251.40 ms |
| Downstream status 200 | 14 |
| Downstream status 503 | 66 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: k6 -> l02_circuit_breaker_listener -> l02_circuit_breaker_routes -> l02_circuit_breaker_cluster -> auth-sim
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=250, error_rate=0, max_in_flight=0, seed=17082026
- Proxy capacity: not applicable
- Network toxic: not applicable
- Envoy proxy: {"listener":"l02_circuit_breaker_listener","route":"l02_circuit_breaker_routes","cluster":"l02_circuit_breaker_cluster","stat_prefix":"l02_circuit_breaker","route_timeout":"2s","retry_on":"none","num_retries":0,"circuit_breakers":{"max_connections":100,"max_pending_requests":100,"max_requests":1,"max_retries":100}}
- Retry policy: none
- Max attempts: 1

## Envoy / application delta

| Observer metric | Delta |
| --- | ---: |
| Envoy downstream requests | 80 |
| Envoy upstream attempts | 14 |
| Envoy upstream attempt amplification | 0.175x |
| Envoy retries | 0 |
| Envoy retry limit exceeded | 0 |
| Envoy timeouts | 0 |
| Envoy active overflow | 66 |
| Envoy pending overflow | 0 |
| Envoy retry overflow | 0 |
| Envoy pending requests | 18 |
| auth-sim token requests | 14 |

Metric 이름과 before/after absolute value는 `envoy-stats-delta.json`과
`auth-sim-metrics-delta.json`에 보존했다. 이 값은 단일 local exploratory evidence다.
