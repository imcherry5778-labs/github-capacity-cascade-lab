# sidecar-control L04 summary

> 단일 local exploratory evidence이며 production benchmark나 GitHub 설정 evidence가 아니다.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Generated inbound max requests | 100 |
| Logical / physical / k6 retry | 80 / 80 / 0 |
| Logical failure rate | 0 |
| Downstream 200 / 503 / 504 | 80 / 0 / 0 |
| Proxy downstream / upstream delta | 80 / 80 |
| Proxy downstream 5xx delta | 0 |
| Proxy active / pending overflow delta | 0 / 0 |
| Proxy retry / timeout delta | 0 / 0 |
| Inbound route retry policy count / max budget | 0 / 0 |
| Application token delta | 80 |
| Application admission rejection delta | 0 |
| Application / proxy active peak | 5 / 5 |
| Timestamped samples (during) | 16 (14) |

Actual metric name은 proxy-metric-mapping.json, absolute before/after는 proxy/application
snapshot, 시간 관계는 samples.jsonl에 보존했다.
