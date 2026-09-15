# L05 HPA blind spot pair summary

> Local exploratory evidence only. The policies, thresholds, local topology and adapter are LAB_IMPLEMENTATION, not GitHub production configuration.

| Scenario | Contract | Desired replica peak | Pod peak | Failure rate | Active overflow delta |
| --- | --- | ---: | ---: | ---: | ---: |
| hpa-blind | true | 1 | 1 | 0.7472283813747228 | 337 |
| hpa-aware | true | 2 | 2 | 0.33555555555555555 | 151 |
