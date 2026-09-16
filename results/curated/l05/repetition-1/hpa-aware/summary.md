# hpa-aware L05 summary

> This is local exploratory evidence, not a production benchmark or GitHub configuration evidence.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Logical / physical / retry | 450 / 450 / 0 |
| Downstream 200 / 503 / 504 | 274 / 176 / 0 |
| Logical failure / P95 | 0.39111111111111113 / 1003 ms |
| HPA desired / current replica peak | 2 / 2 |
| Ready workload Pod peak | 2 |
| Proxy active overflow delta | 176 |
| Proxy downstream / upstream delta | 450 / 274 |
| Application token / admission rejection delta | 274 / 0 |
| Timestamped samples | 117 |
