# Experiment evidence

`results/` 아래에는 로컬 scenario 실행에서 생성된 evidence가 저장된다. 각 실행은
`results/<scenario>/<UTC timestamp>/` 형태의 새 디렉터리를 사용하며 기존 결과를
덮어쓰지 않는다.

생성 결과는 머신 종속적인 exploratory evidence이므로 기본적으로 Git에서 제외한다.
공유 가능한 portfolio evidence로 승격할 때에는 반복 실행, 동일 조건 비교, secret 검토를
별도로 수행한다.

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

Scenario 도중 실패한 파일도 같은 directory에 보존한다. Admin token, 전체 environment,
credential, 개인 절대 경로는 evidence에 저장하지 않는다.
