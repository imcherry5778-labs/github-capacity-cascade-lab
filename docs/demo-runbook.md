# Demo runbook

L10은 새 실험을 만들지 않는다. 이 runbook은 이미 검증된 [portfolio case study](portfolio.md)를
7–10분 안에 보여주기 위한 재현 절차이며, demo가 실패해도 portfolio story가 무너지지 않도록
evidence-only fallback을 항상 함께 둔다.

## Audience

Cloud / Platform / DevOps / SRE 면접관. 처음 이 저장소를 보는 사람 기준으로 command와
evidence file을 그대로 따라갈 수 있게 구성한다.

## Target duration

대략 7–10분. Exact requirement가 아니라 demo target이며, 질문이 들어오면 시간보다 정확한
답을 우선한다.

## Two demo paths — 반드시 구분

| Path | Command | 목적 | Portfolio evidence 여부 |
| --- | --- | --- | --- |
| Fast health/demo path | `make l06-smoke` | Clean bootstrap, request path, cleanup을 짧게 확인 | 아니다 — bounded smoke일 뿐 |
| Full live comparison path | `make l06-verify` | No-retry vs retry 한 pair를 실제로 보여줌 | 아니다 — single live pair는 여전히 exploratory |

Portfolio claim은 이미 curated된 L06 3회 반복
([results/curated/l06/README.md](../results/curated/l06/README.md))이 authority다. Live
demo는 "이 mechanism이 실제로 동작한다"는 것을 보여주는 용도이지, 숫자 자체가 claim의
근거가 아니다.

L07 전체 matrix, L08 Chaos Mesh, L09 AKS는 **이 demo에서 다시 실행하지 않는다.** 길고
불안정해지며, 특히 L09는 Azure cost/quota/network dependency를 demo requirement로 만들기
때문이다. L07–L09는 curated evidence 파일을 열어 설명한다.

## Suggested flow

| 시간 | 내용 | 보여줄 화면/파일 | 핵심 문장 |
| --- | --- | --- | --- |
| 0:00–1:00 | GitHub 2026-08-17 incident FACT와 research question | [README 상단](../README.md), [source register](source-register.md) | "실패가 만든 retry가 추가 실제 요청을 만들어 복구 여유까지 소진하는 순간을 연구한다." |
| 1:00–2:00 | Lab architecture와 bottleneck hypothesis | [portfolio.md §5 core architecture](portfolio.md#5-core-architecture) | "Sidecar concurrency가 병목이고, application CPU만 보는 HPA는 이를 보지 못한다." |
| 2:00–5:00 | L06 live demo (`make l06-smoke`, 선택적으로 `make l06-verify`) 또는 curated L06 pair | 터미널 출력 + [L06 curated evidence](../results/curated/l06/README.md) | "Client retry 하나만 바꿨을 때 physical attempts가 219에서 508–513으로, sidecar overflow가 143에서 430–434로 늘었다." |
| 5:00–7:00 | L07 mitigation trade-offs | [portfolio.md §7](portfolio.md#7-l07--mitigation-trade-offs), [L07 curated evidence](../results/curated/l07/README.md) | "Backoff+jitter는 실패를 줄이지만 부하를 늘리고, load shedding은 backend를 지키지만 client-visible 실패를 명시적으로 늘린다 — 우열이 아니라 trade-off다." |
| 7:00–8:00 | L08 chaos safety | [portfolio.md §8](portfolio.md#8-l08--chaos-engineering-safety), [L08 curated evidence](../results/curated/l08/README.md) | "Fault window와 신호 변화를 declarative하게 상관지었고, sidecar overflow peak는 0이었다 — chaos의 목적은 cascade 재현이 아니라 안전한 통제다." |
| 8:00–9:00 | L09 AKS validation | [portfolio.md §9](portfolio.md#9-l09--aks-validation), [L09 curated evidence](../results/curated/l09/README.md) | "같은 증폭 비율(~2.3x/~3.0x)이 managed AKS에서도 거의 동일하게 나타났고, teardown 후 잔여 resource는 0이었다." |
| 9:00–10:00 | Limitations, cleanup, takeaway | [portfolio.md §11](portfolio.md#11-limitations) | "이건 fixed lab condition의 mechanism-level evidence다. GitHub topology나 production capacity를 증명하지 않는다." |

시간은 target이지 hard boundary가 아니다.

## Audience가 볼 핵심 signal

화면에는 아래 metric만 제한적으로 보여준다.

- logical requests
- physical attempts
- retry attempts
- retry amplification (physical attempts / logical requests)
- selected sidecar overflow
- HPA replicas (desired/current)
- HAProxy-observed propagated sessions / 5xx
- final idle recovery

## Demo failure path

Demo가 실패해도 portfolio story는 curated evidence로 계속 설명 가능해야 한다.

| 실패 상황 | 대응 |
| --- | --- |
| Docker/k3d/Istio prerequisite 실패 (`make l06-doctor`/`l06-check` 실패) | Live result를 fake하지 않는다. 즉시 [L06 curated evidence](../results/curated/l06/README.md)로 fallback하고 실제 contract/README 파일을 연다. |
| Live pair 결과가 curated 값과 다름 | 값을 고치지 않는다. "이 run은 exploratory result다"라고 설명하고, portfolio claim은 curated 3 repetitions에 있다고 명시한다. |
| AKS 관련 질문이 나옴 | AKS를 live로 다시 provision/demo하지 않는다. [L09 curated evidence](../results/curated/l09/README.md)와 destroy-contract.json을 연다. |
| 네트워크/터미널 문제로 아무 것도 실행 못함 | 전체를 curated evidence 파일 walkthrough로 전환한다. `results/curated/l05`–`l09`의 README만으로 6–9절을 그대로 설명할 수 있다. |

## Presentation / recording flow

이 저장소 범위는 실제 촬영/편집이 아니라 아래 텍스트 흐름이다.

1. **화면 순서:** README 상단 → portfolio.md → 터미널(`make l06-smoke`) → L06 curated
   README → portfolio.md L07/L08/L09 절 → 각 curated README.
2. **입력할 command:** `make doctor`, `make l06-doctor`, `make l06-check`,
   `make l06-smoke` (선택: `make l06-verify`).
3. **열어서 보여줄 evidence file:** `results/curated/l06/README.md`,
   `results/curated/l07/README.md`, `results/curated/l08/README.md`,
   `results/curated/l09/README.md`, `results/curated/l09/destroy-contract.json`.
4. **핵심 takeaway 문장:**
   - "Retry는 logical demand를 바꾸지 않고도 physical load를 증폭시킨다."
   - "Scaling이 보는 metric이 실제 bottleneck과 다르면 blind spot이 생긴다."
   - "완화책은 trade-off이지 만능 해법이 아니다."
   - "같은 mechanism이 managed cloud에서도 비슷하게 재현됐다."
5. **반드시 말해야 할 limitation:**
   - 모든 topology/threshold는 `LAB_IMPLEMENTATION`이며 GitHub 사실이 아니다.
   - 각 결과는 fixed local/cloud condition의 최소 3회 반복이며 production benchmark가 아니다.
   - Mitigation 비교는 우열 순위가 아니다.
   - L09 실제 Cost Management observed spend는 문서 작성 시점에 pending이다.

## Preflight before presenting

```bash
make doctor
make l06-doctor
make l06-check
make l10-check
```

`make l10-check`는 portfolio package(문서, curated evidence 참조, private path/credential
부재)가 stale하지 않은지 검사한다. 측정값 자체를 재검증하지 않는다.
