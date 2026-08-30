# L01 Curated Evidence

- Learning unit: **L01 — HAProxy and Toxiproxy Fundamentals**
- Classification: **Local exploratory evidence**
- Source branch: `feat/l01-haproxy-toxiproxy`
- L01 implementation commit: `3541e908b4db9b1f6b7e72c44d604a41e9902b73`

이 curated set은 HAProxy proxy capacity/queue pressure와 Toxiproxy network fault를 한
request path에 섞지 않고 관찰한 최종 clean 검증 run 5개의 사본이다. 각 run은 위 구현
commit에서 `git_dirty=false`로 생성됐고 `cleanup.json`에서 application reset, 해당하는
Toxiproxy reset, Compose down과 잔여 resource 0을 확인했다.

## Selected scenarios

| Scenario | Source raw run | Logical / Physical | Logical failure | Logical P95 | Key signal |
| --- | --- | ---: | ---: | ---: | --- |
| HAProxy control | `haproxy-control/20260829T131607Z` | 81 / 81 | 0.00% | 253.00 ms | backend `qmax=0`, server `smax=6/limit=100`, backend `econ=0`, `5xx=0` |
| HAProxy constrained | `haproxy-constrained/20260829T131616Z` | 81 / 81 | 58.02% | 324.00 ms | backend `qmax=3`, server `smax=2/limit=2`, backend `econ=47`, `5xx=47`, `qtime_max=78 ms` |
| Toxiproxy control | `toxiproxy-control/20260829T131624Z` | 80 / 80 | 0.00% | 3.00 ms | toxic 배열이 적용 전·실행 중·reset 후 모두 비어 있음 |
| Toxiproxy latency | `toxiproxy-latency/20260829T131632Z` | 81 / 81 | 0.00% | 153.00 ms | downstream latency `150 ms`, jitter `0`; 종료 후 toxic 비어 있음 |
| Toxiproxy reset-peer | `toxiproxy-reset-peer/20260829T131640Z` | 81 / 81 | 100.00% | 3.00 ms | downstream `reset_peer`, timeout `0`; k6에서 `EOF` 81건, 종료 후 toxic 비어 있음 |

모든 scenario는 retry policy `none`, max attempts `1`이므로 logical/physical amplification
`1.000x`가 의도된 조건이다. Application error injection은 모두 0이며, HAProxy 비교만
동일한 auth-sim service time `250 ms`를 사용한다. 자세한 request timeout, image/tool
version, capacity와 toxic 설정은 각 `metadata.json`에 있다.

## Selection and retained files

동일 scenario의 모든 local timestamp run을 비교해 최종 구현 commit, clean worktree, 최종
scenario 조건과 cleanup 성공이 함께 확인된 run만 선정했다. Raw directory는 그대로
보존했으며 다음 파일을 byte-for-byte 복사했다.

- 공통: `metadata.json`, `summary.md`, `k6-summary.json`, `cleanup.json`,
  `auth-sim-state-applied.json`, `auth-sim-state-after-reset.json`
- HAProxy: `haproxy-stats-before.csv`, `haproxy-stats.csv`
- Toxiproxy: `toxiproxy-state-before.json`, `toxiproxy-state-applied.json`,
  `toxiproxy-state.json`, `toxiproxy-state-after-reset.json`
- Reset-peer만: connection error 형태를 보존하는 `k6.log`

전체 auth-sim/HAProxy/Toxiproxy log와 중복 signal은 raw local evidence에만 남겼다. Curated
파일에는 redaction을 적용하지 않았고 measured value를 수정하지 않았다.

## Meaningful development observations

- 초기 constrained run `20260829T130532Z`는 5 ops/s에서 backend `qmax=0`, logical
  failure `0.00%`여서 capacity/queue pressure를 증명하지 못했다. 최종 비교 workload는
  control과 constrained 모두 20 ops/s, 4s로 맞췄다.
- constrained run `20260829T130559Z`에서는 server row `qmax=0`이지만 backend aggregate
  `BACKEND` row에서 `qmax=3`이 관찰됐다. 최종 판정은 queue가 집계되는 backend aggregate
  row를 읽는다.

이전 실패/개발 run 전체는 curated set에 복사하지 않았으며 raw local lab notebook에
그대로 보존한다.

## Limitations

- 단일 local machine에서 얻은 결과이며 portfolio final evidence가 아니다.
- Production benchmark나 머신 독립적인 성능 보장이 아니다.
- HAProxy/Toxiproxy 설정값은 학습을 위한 `LAB_IMPLEMENTATION` target이며 GitHub의 실제
  production topology, limit, timeout 또는 network fault 설정을 의미하지 않는다.
- 현재 L01은 retry가 없으므로 amplification `1.000x`가 의도된 조건이다.
- 반복 comparison과 일반화 가능한 해석은 후속 portfolio evidence 단계에서 동일 조건
  최소 3회 반복 후 수행한다.
