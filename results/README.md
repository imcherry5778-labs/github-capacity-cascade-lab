# Experiment evidence

`results/` 아래에는 로컬 scenario 실행에서 생성된 evidence와 검토 후 선별한 사본이
저장된다.

- `results/<scenario>/<UTC timestamp>/`: append-only raw local lab notebook. 각 실행은 새
  디렉터리를 사용하며 기존 성공/실패 결과를 덮어쓰거나 삭제하지 않는다. Git에서는
  기본적으로 제외한다.
- `results/curated/<learning-unit>/`: raw run을 직접 검토한 뒤 원본 측정값 그대로 복사한
  공유용 evidence. GitHub와 ChatGPT에서 설정, 결과, cleanup을 함께 검토할 수 있도록
  필요한 최소 파일만 추적한다.

Curated evidence도 단일 run이면 머신 종속적인 `local exploratory evidence`이며 portfolio
final evidence나 production benchmark가 아니다. Portfolio evidence로 승격하려면 동일
조건 최소 3회 반복과 비교 검토를 별도로 수행한다.

L00 run은 `metadata.json`, `k6-summary.json`, `summary.md`, `app.log`를 남긴다. L01은
같은 기본 파일에 다음을 추가한다.

- `k6.log`: connection error를 포함한 k6 console output
- `auth-sim.log`, `auth-sim-state-applied.json`, `auth-sim-state-after-reset.json`:
  application 조건과 reset 결과
- `haproxy.log`, `haproxy-stats-before.csv`, `haproxy-stats.csv`,
  `haproxy-metrics.prom`: HAProxy scenario의 machine-readable connection/queue/error signal
- `toxiproxy.log`, `toxiproxy-state-before.json`, `toxiproxy-state-applied.json`,
  `toxiproxy-state.json`, `toxiproxy-state-after-reset.json`: proxy/toxic 적용과 reset state
- `cleanup.json`: application/Toxiproxy reset, Compose down, 잔여 container/network 수

Scenario 도중 실패한 파일도 raw directory에 보존한다. Curated copy에는 해석에 필요한
파일만 포함하며 전체 noisy log를 자동으로 복사하지 않는다. Admin token, 전체 environment,
credential, 개인 절대 경로는 raw와 curated evidence 어디에도 저장하지 않는다. 측정값은
수정하지 않으며 redaction이 불가피하면 raw는 그대로 두고 curated README에 대상과 이유를
기록한다.

현재 추적하는 learning unit별 set은 [curated evidence index](curated/README.md)에서 확인한다.
