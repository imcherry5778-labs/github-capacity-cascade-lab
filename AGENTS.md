# 저장소 운영 계약

## 프로젝트 목표

- GitHub의 2026-08-17 공개 RCA에서 설명한 failure effect를 작은 단위로 학습하고 축소 재현한다.
- 이 lab이 GitHub의 비공개 architecture나 implementation을 복제한다고 주장하지 않는다.

## 출처 무결성

- `FACT`, `INFERENCE`, `LAB_IMPLEMENTATION`, `UNKNOWN`을 명확히 구분한다.
- 공개되지 않은 topology, 설정, algorithm을 GitHub의 사실처럼 설명하지 않는다.
- 예시값과 예정값은 `example`, `planned`, `target`으로 표시하고 실제 측정값처럼 쓰지 않는다.
- incident 관련 주장은 공식 RCA 등 primary source를 근거로 작성한다.

## 범위 원칙

- 작업 전에 현재 branch와 diff, `README.md`, `AGENTS.md`, `docs/roadmap.md`, 관련 코드를 확인한다.
- 현재 learning unit의 목표를 증명하는 최소 범위만 구현한다.
- roadmap 순서보다 앞선 기술을 추가하거나 완료된 단계를 임의로 다시 설계하지 않는다.
- 관련 없는 refactor, 추측성 abstraction, 불필요한 dependency를 추가하지 않는다.

## 엔지니어링

- 기존 코드와 local instruction을 먼저 읽고 현재 구현을 우선 재사용한다.
- container image는 명시적인 version을 사용하고 `latest`를 사용하지 않는다.
- public metric은 low-cardinality를 유지하고 request ID나 사용자 입력을 label에 넣지 않는다.
- health/readiness 동작은 injected fault와 독립적으로 유지한다.
- public workload plane과 admin control plane을 분리한다.
- admin credential은 secret으로 취급하고 log, metric, evidence에 기록하지 않는다.

## 검증

- 각 변경에 직접 관련된 test와 verification을 실제로 실행한다.
- learning unit 완료 전 `make verify`와 해당 단계의 전용 verify target이 있으면 함께 실행한다.
- 실행하지 않은 검증을 commit이나 Pull Request에 수행했다고 기록하지 않는다.
- 최종 diff에서 scope, secret, generated file, misleading claim을 self-review한다.
- 동작이나 실험 조건이 바뀌면 관련 문서도 함께 갱신한다.

## Git 및 Pull Request

- `main` 또는 `master`에서 직접 구현하지 않는다.
- learning unit마다 하나의 feature branch를 사용하고, 독립적인 repository 정책 변경은 별도 작은 branch로 분리한다.
- 변경은 작고 독립적인 Conventional Commit으로 나누며 관련 없는 변경을 섞지 않는다.
- commit과 PR title의 `type`과 `scope`는 영어로, 사람이 읽는 요약과 body는 기본적으로 한국어로 작성한다.
  - 예: `feat(l02): Envoy 기본 요청 경로 추가`
  - 예: `docs(repo): Git 및 Pull Request 작성 규칙 정리`
- 중요한 설계 판단이 있는 commit body에는 변경 이유, 범위, 검증 결과를 간결하게 기록한다.
- PR body에는 배경과 학습 질문, 주요 변경, 검증, 의도적으로 제외한 범위와 한계를 한국어로 설명한다.
- 해당 변경의 verification이 통과한 뒤 commit한다.
- push, merge, rebase, force-push, amend는 사용자가 명시적으로 요청할 때만 수행한다.

## 환경 안전

- `sudo`, package manager, `curl | sh`를 실행하지 않는다.
- 누락된 system tool을 자동 설치하거나 system repository를 변경하지 않는다.
- 명시적인 scope와 승인 없이 Azure resource를 provision하거나 destroy하지 않는다.
- secret, credential, kubeconfig, state file, local environment file을 commit하지 않는다.

## Evidence 관리

- 기존 result directory를 덮어쓰지 않는다.
- secret이나 개인 절대 경로 없이 재현 metadata를 기록한다.
- 실패한 raw experiment도 local evidence로 보존한다.
- generated raw result는 기본적으로 Git에서 제외하고, 무결성과 secret을 검토한 사본만 `results/curated/`에서 추적한다.
- curated evidence의 측정값을 수정하지 않는다.
- 단일 curated run은 local exploratory evidence이며 portfolio evidence나 production benchmark가 아니다.