# hpa-blind L05 summary

> This is local exploratory evidence, not a production benchmark or GitHub configuration evidence.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Logical / physical / retry | 450 / 450 / 0 |
| Downstream 200 / 503 / 504 | 114 / 336 / 0 |
| Logical failure / P95 | 0.7466666666666667 / 1003 ms |
| HPA desired / current replica peak | 1 / 1 |
| Ready workload Pod peak | 1 |
| Proxy active overflow delta | 336 |
| Proxy downstream / upstream delta | 450 / 114 |
| Application token / admission rejection delta | 114 / 0 |
| Timestamped samples | 128 |
