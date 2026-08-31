# Curated Evidence Index

`results/curated/<learning-unit>/`는 raw local lab notebook에서 사람이 직접 검토해 선별한
evidence의 누적 index다. 각 learning unit은 source run, 설정, 측정 결과, 선정 기준과
한계를 자체 README에 기록한다.

| Learning unit | Focus | Status | Evidence |
| --- | --- | --- | --- |
| L00 — Minimal Workload and k6 | Retry/workload fundamentals | Local exploratory evidence available | [L00](l00/README.md) |
| L01 — HAProxy and Toxiproxy Fundamentals | Proxy capacity와 network fault 분리 | Local exploratory evidence available | [L01](l01/README.md) |
| L02 — Envoy Fundamentals | Timeout, internal retry, circuit-breaker 관찰 단위 분리 | Local exploratory evidence available | [L02](l02/README.md) |
| L03 — k3d and Helm Baseline | Kubernetes workload lifecycle, resource snapshot와 cleanup | Local exploratory evidence available | [L03](l03/README.md) |
| L04 — Istio Sidecar and Proxy Metrics | Application/sidecar capacity boundary와 proxy overflow | Local exploratory evidence available | [L04](l04/README.md) |
| L05+ | 후속 learning unit | 아직 curated evidence 없음 | — |

Curated evidence도 단일 local run이면 portfolio final evidence나 production benchmark가
아니다. Raw result는 기존 timestamp directory에 append-only로 남고, curated 파일은
measured value를 수정하지 않은 검토 사본만 추적한다. Portfolio comparison에는 동일 조건
최소 3회 반복 규칙을 적용한다.
