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
- 성공하지 못한 실험도 삭제하거나 성공처럼 수정하지 않는다.
- Generated result는 기본적으로 commit하지 않는다.
- Portfolio로 승격하기 전 secret, 개인 경로, config 일관성을 다시 검토한다.

## Comparison rules

최종 비교 실험은 최소 3회 반복한다. 각 반복은 같은 workload, duration, fault timing,
seed, binary/container version을 사용한다. Machine load나 dropped iteration이 비교를
왜곡하면 해당 run을 숨기지 않고 invalidation 이유와 함께 보존한다.

Good retry의 physical attempts가 bad retry보다 많다면 기대에 맞게 값을 고치지 않는다.
Logical count, dropped iteration, retry classification, timeout, backoff 동안 필요한 VU,
deterministic profile을 조사한 뒤 새 timestamp로 다시 실행한다.

## Reporting rules

- 측정하지 않은 값은 결과로 작성하지 않는다.
- 예시나 목표 수치는 반드시 `example`, `planned`, `target`으로 표시한다.
- GitHub의 공개 incident 수치와 이 lab의 local 수치를 같은 모집단처럼 비교하지 않는다.
- L00의 retry implementation을 GitHub gateway 또는 VS Code algorithm이라고 부르지 않는다.
- 단일 run으로 capacity, 안정성 또는 mitigation 효과를 일반화하지 않는다.
