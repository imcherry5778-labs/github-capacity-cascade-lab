# L00 Curated Evidence

- Learning unit: **L00 — Minimal Workload and k6**
- Classification: **Local exploratory evidence**
- Source commit: `6c38157ab840e1a9ba54b6aca4e077020db7a8de`

이 curated set은 application fault와 retry policy가 logical request, physical attempt,
logical failure와 latency에 미치는 차이를 관찰한 최종 clean L00 comparison run 4개의
사본이다. Source commit은 L00 구현 계보에 포함되며, 이후 L00 merge 전 변경은 동작을
바꾸지 않는 한글 주석 추가였다. 현재 L00 scenario target도 이 run의 설정과 일치한다.

## Selected scenarios

| Scenario | Source raw run | Logical / Physical | Retry | Amplification | Logical failure | Logical / HTTP P95 | Fault | Retry policy |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| Baseline | `baseline/20260829T092231Z` | 26 / 26 | 0 | 1.000x | 0.00% | 1.00 / 0.65 ms | latency `0 ms`, error `0`, max in-flight `0` | `none`, max 1 |
| Latency | `latency/20260829T093538Z` | 26 / 26 | 0 | 1.000x | 0.00% | 102.00 / 101.00 ms | latency `100 ms`, error `0`, max in-flight `0` | `none`, max 1 |
| Bad retry | `bad-retry/20260829T093742Z` | 25 / 41 | 16 | 1.640x | 0.00% | 2.00 / 0.71 ms | latency `0 ms`, error `0.35`, max in-flight `0` | `bad-immediate-retry`, max 5 |
| Good retry | `good-retry/20260829T094057Z` | 25 / 39 | 14 | 1.560x | 8.00% | 65.40 / 0.59 ms | latency `0 ms`, error `0.35`, max in-flight `0` | `good-bounded-backoff-jitter`, max 3 |

모든 run은 logical rate 5 ops/s, duration 5s와 seed `17082026`을 사용했다. 위 수치는
각 `k6-summary.json`의 raw metric과 `summary.md`를 대조한 값이다. Bad/good retry의
차이는 이 단일 run에서 관찰된 결과일 뿐 어느 policy의 일반적인 우월성을 뜻하지 않는다.

## Selection and retained files

Baseline 4개, latency 3개, bad-retry 3개, good-retry 3개 등 총 13개 raw run을 비교했다.
각 scenario에서 source commit이 같고 `git_dirty=false`이며 최종 설정과 일치하는 후반
run을 선정했다. Smoke는 comparison experiment가 아니라 verification이므로 제외했다.

각 scenario에는 raw run의 다음 파일을 byte-for-byte 복사했다.

- `metadata.json`: source commit, clean 여부, tool version과 scenario 설정
- `k6-summary.json`: logical/physical/retry/failure/latency raw metric
- `summary.md`: 사람이 읽을 수 있는 metric과 조건 요약
- `app.log`: loopback public/admin listener의 시작과 정상 종료 기록

Raw timestamp directory는 이동하거나 삭제하지 않았다. Curated 파일에는 redaction을
적용하지 않았고 measured value를 수정하지 않았다.

## Limitations

- 단일 local machine에서 얻은 exploratory evidence이며 portfolio final evidence가 아니다.
- Production benchmark나 머신 독립적인 성능 보장이 아니다.
- Fault와 retry 설정은 학습을 위한 `LAB_IMPLEMENTATION`이며 GitHub의 실제 algorithm이나
  production 설정을 의미하지 않는다.
- Portfolio comparison과 일반화 가능한 해석에는 동일 조건 최소 3회 반복이 필요하다.
