# L08 Chaos Mesh Abort Smoke Summary

> 이 결과는 로컬 ephemeral k3d 환경에서 측정된 local exploratory evidence이며,
> OS signal handling이 아닌 runner의 controlled abort path 및 resource cleanup을 검증합니다.

| 관측 항목 | 측정값 / 상태 |
| --- | --- |
| Abort Contract Satisfied | true |
| Chaos Mesh Version | 2.8.4 |
| Runtime Socket Verified | true |
| Target Identity Verified | true (capacity-cascade-l08-target/auth-sim-8498d7b54f-fv6lh) |
| Injection Active at Abort | true (2026-09-17T18:56:49.162Z) |
| Controlled Abort Triggered | true |
| Chaos CR Remaining After Abort | 0 |
