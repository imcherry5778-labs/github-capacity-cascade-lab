# L02 Curated Evidence

- Learning unit: **L02 — Envoy Fundamentals**
- Classification: **Local exploratory evidence**
- Source branch: `feat/l02-envoy-fundamentals`
- Source commit: `95b14ae1dbd246cd4575d050cda0e7389833c36b`
- L02 implementation commit: `d2cc000`
- Envoy image: `envoyproxy/envoy:v1.39.1`
- Envoy image digest: `sha256:57e14a549d7bd43c8d3f6d03e8cfa653e037d4b38e133acd9b54f38c524401b4`
- Actual binary: `1.39.1/Clean/RELEASE`

이 curated set은 standalone Envoy의 정상 lifecycle, route timeout, bounded internal retry와
cluster circuit breaker를 각각 분리해 관찰한 최종 clean run 5개의 사본이다. 모든 run은
source commit에서 `git_dirty=false`이고 scenario/contract exit 0, application reset,
Compose down과 잔여 container/network 0을 확인했다.

## Selected scenarios

| Scenario | Source raw run | Logical / client physical | Envoy downstream / upstream | Retry / limit | Timeout | Active overflow | Logical failure | Logical P95 | auth-sim token delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Control | `envoy-control/20260830T084334Z` | 81 / 81 | 81 / 81 | 0 / 0 | 0 | 0 | 0.00% | 253.00 ms | 81 (2xx 81) |
| Timeout | `envoy-timeout/20260830T084343Z` | 80 / 80 | 80 / 80 | 0 / 0 | 80 | 0 | 100.00% | 102.00 ms | 80 (2xx 80) |
| Retry disabled | `envoy-retry-disabled/20260830T084352Z` | 80 / 80 | 80 / 80 | 0 / 0 | 0 | 0 | 100.00% | 2.00 ms | 80 (5xx 80) |
| Retry bounded | `envoy-retry-bounded/20260830T084401Z` | 81 / 81 | 81 / 243 | 162 / 81 | 0 | 0 | 100.00% | 61.00 ms | 243 (5xx 243) |
| Circuit breaker | `envoy-circuit-breaker/20260830T084409Z` | 80 / 80 | 80 / 14 | 0 / 0 | 0 | 66 | 82.50% | 252.00 ms | 14 (2xx 14) |

모든 run은 20 ops/s, 4s, k6 request timeout 1s, k6 retry `none`, max attempts 1을
사용했다. 따라서 client retry amplification은 모두 `1.000x`다. Envoy upstream attempt
amplification은 control/timeout/retry-disabled `1.000x`, retry-bounded `3.000x`,
circuit-breaker `0.175x`였다. 이 값은 해당 단일 local run의 관찰값이며 일반적인 성능
결론이 아니다.

실제 downstream status는 control 200 81건, timeout 504 80건, retry-disabled 503 80건,
retry-bounded 503 81건, circuit-breaker 200 14건/503 66건이었다.

## Actual Envoy metric names

각 scenario의 cluster/stat prefix만 다르고 판정 category는 다음 actual v1.39.1 text stats를
사용했다.

- Downstream requests: `http.<stat_prefix>.downstream_rq_total`
- Upstream attempts: `cluster.<name>.upstream_rq_total`
- Internal retries: `cluster.<name>.upstream_rq_retry`
- Retry bound exhausted: `cluster.<name>.upstream_rq_retry_limit_exceeded`
- Route timeout: `cluster.<name>.upstream_rq_timeout`
- `max_requests` overflow: `cluster.<name>.upstream_rq_active_overflow`
- Additional preserved overflow: `upstream_rq_pending_overflow`, `upstream_rq_retry_overflow`
- Connection-pool pressure context: `cluster.<name>.upstream_rq_pending_total`

Envoy v1.39.1의 selected `max_requests` path에서는 `upstream_rq_active_overflow=66`,
`upstream_rq_pending_overflow=0`이 관찰됐다. 오래된 pending overflow 이름을 대신 사용하거나
두 counter를 같은 의미로 합치지 않았다.

## Selection and retained files

최종 구현/문서 commit 뒤 생성한 다섯 clean run만 선정했다. 각 scenario에서 다음 file을
raw source와 byte-for-byte 동일하게 복사했다.

- Workload/metadata: `metadata.json`, `summary.md`, `k6-summary.json`
- Contract/cleanup: `contract.json`, `cleanup.json`
- Application: applied/reset state, before/after Prometheus snapshot과 delta JSON
- Envoy identity: actual version과 image digest
- Envoy stats: before/after filtered text, before/after filtered Prometheus와 delta JSON

전체 `k6.log`, `auth-sim.log`, `envoy.log`와 full unfiltered Envoy stats는 raw local notebook에
보존하고 curated copy에서는 noisy 중복 evidence로 제외했다. Redaction은 적용하지 않았고
measured value를 수정하지 않았다.

## Meaningful development observations

- 첫 smoke `envoy-control/20260830T083337Z`는 data/cleanup contract는 통과했지만 summary
  heredoc의 unescaped backtick 때문에 두 evidence filename이 빠졌다. Raw run을 보존하고
  escaping과 application status filter를 수정한 뒤 새 timestamp에서 확인했다.
- Timeout clean run은 Envoy가 504/`upstream_rq_timeout=80`을 기록했지만 auth-sim은 같은
  80건을 최종 2xx로 완료했다. Proxy outcome과 application completion 관찰 시점이 같지 않을
  수 있음을 보여 주며 수치를 임의로 맞추지 않았다.
- Persistent 503에서 bounded retry는 최종 성공률을 개선하지 않았고, client attempt 81을
  upstream/auth-sim attempt 243으로 늘렸다. 이 scenario의 학습 결과는 retry 성공 보장이
  아니라 internal load amplification과 bound 확인이다.
- Circuit breaker는 66건을 upstream 전달 전에 503으로 거절해 auth-sim token delta를 14로
  제한했다. 이는 protection과 rejection trade-off의 한 local observation이다.

## Limitations

- 단일 local machine의 exploratory evidence이며 portfolio final evidence가 아니다.
- Production benchmark, machine-independent result 또는 GitHub production 수치가 아니다.
- Envoy topology와 모든 timeout/retry/circuit-breaker/workload 값은 `LAB_IMPLEMENTATION`과
  local `lab target`이다.
- GitHub의 실제 proxy implementation/version/topology/configuration은 `UNKNOWN`이다.
- Portfolio comparison과 일반화 가능한 해석에는 동일 조건 최소 3회 반복이 필요하다.
