# envoy-retry-disabled summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | envoy-retry-disabled |
| Learning Unit | L02 |
| Logical Requests | 80 |
| Physical Attempts | 80 |
| Retry Attempts | 0 |
| Retry Amplification | 1.000x |
| Logical Failure Rate | 100.00% |
| Logical Duration P95 | 2.00 ms |
| HTTP Request Duration P95 | 1.39 ms |
| Downstream status 200 | 0 |
| Downstream status 503 | 80 |
| Downstream status 504 | 0 |
| Downstream status other/transport | 0 |

## 실행 조건

- Request path: k6 -> l02_retry_disabled_listener -> l02_retry_disabled_routes -> l02_retry_disabled_cluster -> auth-sim
- Logical rate: 20 ops/s
- Duration: 4s
- Request timeout: 1s
- Fault: latency_ms=0, error_rate=1, max_in_flight=0, seed=17082026
- Proxy capacity: not applicable
- Network toxic: not applicable
- Envoy proxy: {"listener":"l02_retry_disabled_listener","route":"l02_retry_disabled_routes","cluster":"l02_retry_disabled_cluster","stat_prefix":"l02_retry_disabled","route_timeout":"2s","retry_on":"none","num_retries":0,"circuit_breakers":{"max_connections":100,"max_pending_requests":100,"max_requests":100,"max_retries":100}}
- Retry policy: none
- Max attempts: 1

## Envoy / application delta

| Observer metric | Delta |
| --- | ---: |
| Envoy downstream requests | 80 |
| Envoy upstream attempts | 80 |
| Envoy upstream attempt amplification | 1.000x |
| Envoy retries | 0 |
| Envoy retry limit exceeded | 0 |
| Envoy timeouts | 0 |
| Envoy active overflow | 0 |
| Envoy pending overflow | 0 |
| Envoy retry overflow | 0 |
| Envoy pending requests | 20 |
| auth-sim token requests | 80 |

Metric 이름과 before/after absolute value는 `envoy-stats-delta.json`과
`auth-sim-metrics-delta.json`에 보존했다. 이 값은 단일 local exploratory evidence다.
