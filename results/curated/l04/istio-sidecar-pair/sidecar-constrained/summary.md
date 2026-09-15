# sidecar-constrained L04 summary

> 단일 local exploratory evidence이며 production benchmark나 GitHub 설정 evidence가 아니다.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Generated inbound max requests | 1 |
| Logical / physical / k6 retry | 80 / 80 / 0 |
| Logical failure rate | 0.825 |
| Downstream 200 / 503 / 504 | 14 / 66 / 0 |
| Proxy downstream / upstream delta | 80 / 14 |
| Proxy downstream 5xx delta | 66 |
| Proxy active / pending overflow delta | 66 / 0 |
| Proxy retry / timeout delta | 0 / 0 |
| Inbound route retry policy count / max budget | 0 / 0 |
| Application token delta | 14 |
| Application admission rejection delta | 0 |
| Application / proxy active peak | 1 / 1 |
| Timestamped samples (during) | 16 (14) |

Actual metric name은 proxy-metric-mapping.json, absolute before/after는 proxy/application
snapshot, 시간 관계는 samples.jsonl에 보존했다.
