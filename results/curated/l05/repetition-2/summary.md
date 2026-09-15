# L05 HPA blind spot pair summary

> Local exploratory evidence only. The policies, thresholds, local topology and adapter are LAB_IMPLEMENTATION, not GitHub production configuration.

| Scenario | Contract | Desired replica peak | Pod peak | Failure rate | Active overflow delta |
| --- | --- | ---: | ---: | ---: | ---: |
| hpa-blind | true | 1 | 1 | 0.7466666666666667 | 336 |
| hpa-aware | true | 2 | 2 | 0.35476718403547675 | 160 |
