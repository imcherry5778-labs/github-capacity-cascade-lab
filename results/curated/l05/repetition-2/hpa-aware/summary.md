# hpa-aware L05 summary

> This is local exploratory evidence, not a production benchmark or GitHub configuration evidence.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Logical / physical / retry | 451 / 451 / 0 |
| Downstream 200 / 503 / 504 | 291 / 160 / 0 |
| Logical failure / P95 | 0.35476718403547675 / 1002 ms |
| HPA desired / current replica peak | 2 / 2 |
| Ready workload Pod peak | 2 |
| Proxy active overflow delta | 160 |
| Proxy downstream / upstream delta | 451 / 291 |
| Application token / admission rejection delta | 291 / 0 |
| Timestamped samples | 120 |
