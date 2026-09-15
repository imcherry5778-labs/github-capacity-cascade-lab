# hpa-aware L05 summary

> This is local exploratory evidence, not a production benchmark or GitHub configuration evidence.

| Observation | Value |
| --- | ---: |
| Contract | true |
| Logical / physical / retry | 450 / 450 / 0 |
| Downstream 200 / 503 / 504 | 299 / 151 / 0 |
| Logical failure / P95 | 0.33555555555555555 / 1002 ms |
| HPA desired / current replica peak | 2 / 2 |
| Ready workload Pod peak | 2 |
| Proxy active overflow delta | 151 |
| Proxy downstream / upstream delta | 450 / 299 |
| Application token / admission rejection delta | 299 / 0 |
| Timestamped samples | 121 |
