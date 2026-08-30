# Experiment policy

## Measurement units

- **Logical Request:** 사용자가 의도한 한 번의 token operation. `logical_requests`가 센다.
- **Physical Attempt:** 최초 HTTP call과 모든 retry call. `physical_attempts`가 센다.
- **Retry Attempt:** 첫 call 이후의 physical attempt. `retry_attempts`가 센다.
- **Logical Failure:** max attempts 종료 시 logical operation이 성공하지 못한 비율이다.

Retry amplification은 별도 Gauge로 근사하지 않고 run 종료 시 Counter로 계산한다.

```text
Retry Amplification = physical_attempts / logical_requests
```

L02에서는 client와 proxy 관찰 단위를 추가로 분리한다.

- **Envoy downstream request:** Envoy HCM이 client에서 받은 request
- **Envoy upstream attempt:** 최초 upstream 전달과 Envoy internal retry의 합
- **auth-sim token request delta:** application이 `/token` handler 완료 시 기록한 request 증가량

```text
Client Retry Amplification = k6 physical_attempts / logical_requests
Envoy Upstream Attempt Amplification = Envoy upstream attempts / logical_requests
```

L02 k6 retry는 항상 `none`, max attempts 1이다. Envoy retry를 `physical_attempts`로
재정의하지 않으며 기존 L00/L01 metric 의미를 바꾸지 않는다.

## Exploratory result vs Portfolio evidence

- **Local exploratory result:** 구현 검증과 가설 탐색을 위한 단일 또는 임시 run. 머신
  상태에 종속되며 최종 결론으로 사용하지 않는다.
- **Portfolio evidence:** 고정된 비교 조건, 최소 3회 반복, version/config metadata,
  실패 run, 해석과 한계를 함께 검토한 결과다.

README에는 임시 P95, RPS 또는 amplification 값을 자동 반영하지 않는다.

## Reproducibility controls

1. 비교 run은 같은 workload, logical rate, duration, fault timing, seed와 software
   version을 사용한다.
2. Deterministic error profile은 seed, logical request ID, attempt 조합으로 고정한다.
3. bad/good retry 비교는 같은 logical ID namespace와 fault profile을 사용한다.
4. Retry policy, max attempts, latency, error rate, admission limit을 metadata에 기록한다.
5. Admin token이나 전체 environment dump는 metadata에 넣지 않는다.

## Evidence retention

- `results/<scenario>/<UTC timestamp>/`는 append-only 실행 단위로 취급한다.
- 같은 timestamp가 존재하면 suffix를 사용하며 기존 파일을 덮어쓰지 않는다.
- 성공하지 못한 raw 실험도 local에서 삭제하거나 성공처럼 수정하지 않는다.
- Generated raw result는 기본적으로 ignore하고 commit하지 않는다.
- 사람이 metadata, config, cleanup, secret과 개인 경로를 검토한 사본만
  `results/curated/<learning-unit>/`에 복사해 commit할 수 있다. Raw directory는 이동하거나
  삭제하지 않는다.
- Curated copy는 measured value를 변경하지 않는다. Redaction이 불가피하면 raw는 보존하고
  curated README에 대상과 이유를 기록한다.
- Curated single run도 local exploratory evidence다. Portfolio evidence에는 동일 조건 최소
  3회 반복 규칙을 그대로 적용한다.

## Comparison rules

최종 비교 실험은 최소 3회 반복한다. 각 반복은 같은 workload, duration, fault timing,
seed, binary/container version을 사용한다. Machine load나 dropped iteration이 비교를
왜곡하면 해당 run을 숨기지 않고 invalidation 이유와 함께 보존한다.

Good retry의 physical attempts가 bad retry보다 많다면 기대에 맞게 값을 고치지 않는다.
Logical count, dropped iteration, retry classification, timeout, backoff 동안 필요한 VU,
deterministic profile을 조사한 뒤 새 timestamp로 다시 실행한다.

### L01 HAProxy comparison

- Control과 constrained는 logical rate, duration, request timeout, no-retry policy와
  auth-sim service time을 고정한다.
- Application error rate는 0, `max_in_flight`는 unlimited로 두고 HAProxy capacity만 바꾼다.
- CSV/Prometheus의 queue, current/max sessions, connection/error/5xx signal을 k6 logical
  failure와 P95와 함께 해석한다.
- Queue가 관측되지 않으면 완료로 고치지 않고 failed run을 보존한 뒤 workload/capacity
  조건을 점검해 새 timestamp로 실행한다.

### L01 Toxiproxy comparison

- Control, latency, reset은 logical rate, duration, request timeout과 max attempts 1을 고정한다.
- Application latency/error/max-in-flight는 모두 0으로 유지하고 network toxic만 바꾼다.
- Toxic을 적용하기 전에 `/reset`하고 실제 proxy state를 저장한다. 종료 시 다시 reset한
  뒤 enabled proxy와 빈 toxic 배열을 확인한다.
- Latency는 control과 P95를 비교하되 머신 독립적인 절대 P95 threshold를 자동화하지 않는다.
- Connection fault는 toxic state와 k6 connection error/logical failure를 함께 보존한다.

### L01 evidence

HAProxy stats, Toxiproxy state, 각 component log와 `cleanup.json`을 k6 evidence와 같은
timestamp directory에 둔다. 단일 성공 run은 `local exploratory result`이고 반복·조건
검토 전에는 portfolio evidence 또는 일반적인 성능 결론이 아니다.

### L02 control vs timeout

- Logical rate, duration, k6 request timeout/no-retry, application service time/error/admission과
  cluster circuit breaker threshold를 고정한다.
- `envoy-timeout`은 route timeout만 2s에서 100ms로 바꾼다.
- 실제 downstream status, logical failure, `upstream_rq_timeout`, upstream attempt와 auth-sim
  token/status delta를 함께 본다. Envoy와 application 완료 결과가 다르면 취소/완료 시점을
  조사하고 수치를 맞추지 않는다.

### L02 retry-disabled vs retry-bounded

- Workload, k6 timeout/no-retry, persistent application 503, route timeout, endpoint와 circuit
  breaker threshold를 고정한다.
- Bounded 쪽만 `retry_on: 5xx`, `num_retries: 2`를 적용한다.
- `upstream_rq_retry`, `upstream_rq_retry_limit_exceeded`, `upstream_rq_total`과 auth-sim token
  delta로 internal attempt 증가와 configured bound를 확인한다.
- Persistent failure에서 최종 success가 개선되지 않는 결과도 그대로 보존한다.

### L02 control vs circuit breaker

- Workload, route/k6 timeout, no-retry와 application latency/error/admission을 고정한다.
- Constrained cluster만 `max_requests`를 100에서 1로 낮춘다. 두 값 모두 local `lab target`이다.
- Envoy v1.39.1에서 이 경로의 authoritative signal인 `upstream_rq_active_overflow`를 판정에
  사용하고, `upstream_rq_pending_overflow`와 `upstream_rq_retry_overflow`도 snapshot에 남긴다.
- Upstream pressure 감소와 downstream 503/latency trade-off를 함께 기록하며 보편적인
  안정성 또는 성능 향상으로 일반화하지 않는다.

### L02 evidence

- 동일한 fresh Envoy process 안의 stats before/after delta만 비교한다. 다른 run의 cumulative
  absolute counter를 빼지 않는다.
- `/stats`에서 실제 selected version이 내보내는 `http.<stat_prefix>`와
  `cluster.<name>` metric 이름을 확인한다. 예상 metric이 없으면 이름을 추측하지 않는다.
- Application metrics before는 Envoy stats before보다 먼저, application metrics after는
  Envoy stats after보다 나중에 수집해 observation request를 Envoy workload delta에서 뺀다.
- 단일 clean run도 local exploratory evidence이며 machine-independent benchmark가 아니다.

## Reporting rules

- 측정하지 않은 값은 결과로 작성하지 않는다.
- 예시나 목표 수치는 반드시 `example`, `planned`, `target`으로 표시한다.
- GitHub의 공개 incident 수치와 이 lab의 local 수치를 같은 모집단처럼 비교하지 않는다.
- L00의 retry implementation을 GitHub gateway 또는 VS Code algorithm이라고 부르지 않는다.
- 단일 run으로 capacity, 안정성 또는 mitigation 효과를 일반화하지 않는다.
