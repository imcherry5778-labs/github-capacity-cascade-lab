# L08 Chaos Mesh Reproduction Summary

> 이 결과는 로컬 ephemeral k3d 환경에서 측정된 local exploratory evidence이며,
> GitHub production benchmark나 실제 장애 복제가 아닙니다.

| 관측 항목 | 측정값 / 상태 |
| --- | --- |
| Contract Passed | true |
| Chaos Mesh Version | 2.8.4 |
| Runtime Socket Verified | true |
| Namespace Blast-Radius Protected | true (enableFilterNamespace=true) |
| Fault Type & Target | NetworkChaos delay (600ms) on auth-sim |
| Injection Injected Timestamp | 2026-09-17T18:05:22.880Z |
| Recovery Timestamp | 2026-09-17T18:05:47.937Z |
| Pre-fault Healthy | true (overflow peak: 0) |
| Fault Window Observed Peak Overflow | 0 |
| Fault Window Observed 5xx | 20 (k6 503 total: 25) |
| Post-fault Recovery | true |
| Dropped Iterations | 0 |
| Chaos CR Deleted | true |
