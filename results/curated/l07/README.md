# L07 curated evidence — RCA Mitigations

이 디렉터리는 L07의 clean-source fixed-condition matrix 세 개에서 판정에 필요한 원문을
byte-for-byte로 선별한 local exploratory evidence다. 각 repetition은 fresh k3d cluster에서
실행됐고 source commit은 `23bf7c4d267e3c6f39655fac7cd1710254848d09`, metadata의
`git_dirty`는 모두 `false`다. Scenario, M1–M4 pair, cleanup contract는 모두 PASS다.

| curated repetition | raw source directory | started at UTC | scenario / pair / cleanup |
| --- | --- | --- | --- |
| 1 | `results/rca-mitigations/20260917T152506Z/` | 2026-09-17T15:25:06Z | PASS / PASS / PASS |
| 2 | `results/rca-mitigations/20260917T154410Z/` | 2026-09-17T15:44:10Z | PASS / PASS / PASS |
| 3 | `results/rca-mitigations/20260917T160256Z/` | 2026-09-17T16:02:56Z | PASS / PASS / PASS |

## Fixed local comparison boundary

```text
non-injected k6 Job
  -> HAProxy (retries 0, no redispatch)
  -> auth-sim ClusterIP Service
  -> injected inbound istio-proxy (http2MaxRequests: 1)
  -> auth-sim
```

Istio `1.30.4`, HAProxy `3.2.23-alpine`, k6 `2.2.0`, auth-sim latency `1000 ms`, request
timeout `2 s`, one-second sampling, and final-idle recovery are local fixed conditions. Before
metric discovery, a non-injected HAProxy datapath probe creates the selected Envoy lazy stats;
the runner rejects an absent or ambiguous actual stat name rather than treating it as zero.
The probe is not part of a scenario workload baseline.

Each pair changes exactly one local mechanism:

| pair | control | changed local mechanism | held fixed |
| --- | --- | --- | --- |
| M1 | bounded immediate client retry, max attempts 3 | exponential backoff (100–400 ms) with full jitter, max attempts 3 | fault, schedule, HPA, sidecar, HAProxy and proxy retry |
| M2 | HAProxy forwarding | per-source one-second rate above 2 returns HTTP 429 | client/proxy retry disabled, fault, schedule, HPA and sidecar |
| M3 | `auth-sim` CPU `ContainerResource` HPA | `sidecar_active_requests` Pods custom-metric HPA | L06 path, retry, HPA min/max/behavior, fault and sidecar target |
| M4 | steep arrival shape | gradual arrival shape | retry, HPA, sidecar, HAProxy, duration 100 s, start/end 1/s, peak 4/s and intended 220 logical requests |

HAProxy is not the constrained target. Its backend sessions, 5xx and denials describe
propagated traffic or the local M2 policy; they do not establish HAProxy saturation. The exact
M1 budget, M2 status/threshold, M3 adapter/HPA target, and M4 schedules are
`LAB_IMPLEMENTATION`, not GitHub implementation facts.

## Measured local comparisons

| pair | repetition 1 | repetition 2 | repetition 3 |
| --- | --- | --- | --- |
| M1 immediate → backoff | physical `509→544`, retry `290→324`, failure `0.639→0.605`, p95 `1004→1212 ms`, overflow `430→457` | `512→525`, `293→305`, `0.635→0.614`, `1004→1096 ms`, `432→440` | `511→545`, `291→325`, `0.641→0.609`, `1003→1202 ms`, `432→459` |
| M2 forward → 429 | sessions `220→89`, overflow `144→46`, failure `0.655→0.805`, 429/denial `0→131` | `219→90`, `144→47`, `0.658→0.805`, `0→130` | `219→88`, `143→46`, `0.653→0.808`, `0→131` |
| M3 blind → aware | replicas `1/1→2/2`, overflow `144→56`, failure `0.658→0.256` | `1/1→2/2`, `144→56`, `0.655→0.256` | `1/1→2/2`, `144→71`, `0.655→0.324` |
| M4 steep → gradual | logical `220→220`, overflow `156→144`, failure `0.709→0.655` | `219→219`, `156→143`, `0.712→0.653` | `220→220`, `156→144`, `0.709→0.655` |

All scenarios had zero dropped k6 iterations and final selected sidecar active requests plus
HAProxy current queue/sessions at zero. M1 is an explicit trade-off: under these conditions,
backoff+jitter lowered logical failure but increased physical attempts, overflow and p95. M2
explicitly exchanged client-visible 429/failure for less forwarded pressure. M3 observed actual
custom-metric HPA scale-up before lower overflow/503. M4's intended budget was comparable here;
if a future raw run has a different logical count, absolute overflow alone is not a conclusion.

These three runs do not establish GitHub topology, retry algorithm, HPA configuration, blocking
policy, ramp algorithm, production capacity, causal recovery mechanism, recovery duration, or a
general mitigation ranking/recommendation.

## Selected original files

Each repetition retains `metadata.json`, `m1-contract.json` through `m4-contract.json`, and
`cleanup.json`. Every scenario retains:

- `contract.json`, `k6-metadata.json`, `k6-summary.json`, and `k6-summary.md`
- `samples.jsonl` for timestamped k6, HAProxy, selected sidecar, application, HPA, Pod and
  endpoint state
- HAProxy before/after CSV, selected proxy metric mapping/target config, HPA final
  state/events, applied fault and application-observation bypass proof
- the non-injected datapath probe pod/response that precedes lazy-stat discovery

`scaling-aware` also retains the applied adapter manifest and APIService readiness result. The
curated copy excludes admin credentials, generated secrets, port-forward logs, mutable raw
scratch files and all failed, incomplete, smoke or dirty-source raw runs. Those raw directories
remain append-only under `results/rca-mitigations/`; none was edited, deleted or relabelled as a
successful result.
