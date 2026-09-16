# L06 curated evidence — Full Capacity Cascade

이 디렉터리는 L06의 clean-source fixed-condition pair 세 개에서 판정에 필요한 원문을
byte-for-byte로 선별한 local exploratory evidence다. 각 repetition은 fresh k3d cluster에서
실행했으며, source commit `a85026bd032e13f714279890c83c7303e1a2eec0`와
`git_dirty: false`를 metadata에서 확인했다.

| curated repetition | raw source directory | started at UTC | root/scenario/cleanup contract |
| --- | --- | --- | --- |
| 1 | `results/full-capacity-cascade/20260916T173951Z/` | 2026-09-16T17:39:51Z | PASS / PASS / PASS |
| 2 | `results/full-capacity-cascade/20260916T174614Z/` | 2026-09-16T17:46:14Z | PASS / PASS / PASS |
| 3 | `results/full-capacity-cascade/20260916T175234Z/` | 2026-09-16T17:52:34Z | PASS / PASS / PASS |

## Fixed local comparison

```text
non-injected k6 Job
  -> HAProxy (retries 0, no redispatch)
  -> auth-sim ClusterIP Service
  -> injected inbound istio-proxy (http2MaxRequests: 1)
  -> auth-sim
```

Istio is `1.30.4`, HAProxy is `3.2.23-alpine`, k6 is `2.2.0`, application latency is
`1000 ms`, timeout is `2 s`, and the blind HPA is an actual `ContainerResource`
`auth-sim` CPU utilization target of `80%` (min/max `1/4`). The selected inbound proxy
retry policy is disabled in both scenarios. The HPA path is recorded as an observation/state
signal; it is not used as causal proof for a GitHub production policy.

The fixed schedule is stable `1/s · 20 s`, peak `4/s · 60 s`, then recovery
`1/s · 20 s`, with one-second samples. The only comparison variable is the client policy:

| scenario | client retry policy | maximum attempts |
| --- | --- | --- |
| `cascade-no-retry` | none | 1 |
| `cascade-retry` | bounded immediate retry | 3 |

Recovery passes only if the final timestamped sample after peak shows selected sidecar active
requests and HAProxy current queue/sessions back at zero. All six scenario contracts record
every phase (`baseline`, `stable`, `peak`, `recovery`, `after`) and `recovery_idle: true`.

## Measured local comparison

| repetition | no-retry logical / physical / retry | no-retry sidecar overflow / HAProxy sessions / 5xx | retry logical / physical / retry / amplification | retry sidecar overflow / HAProxy sessions / 5xx |
| --- | --- | --- | --- |
| 1 | 219 / 219 / 0 | 143 / 219 / 143 | 220 / 513 / 293 / 2.332x | 434 / 513 / 434 |
| 2 | 220 / 220 / 0 | 144 / 220 / 144 | 219 / 508 / 289 / 2.320x | 430 / 508 / 430 |
| 3 | 219 / 219 / 0 | 144 / 219 / 144 | 219 / 510 / 291 / 2.329x | 431 / 510 / 431 |

Each scenario recorded a maximum desired/current HPA replica count of `1/1`, no dropped k6
iterations, and zero application admission rejections. This supports a narrow local
interpretation: under this fixed workload and capacity target, immediate bounded client retry
increased physical attempts and the selected sidecar/HAProxy pressure counters. It does not
establish GitHub's topology, retry algorithm, exact settings, causality, production capacity,
or a general retry recommendation.

## Selected original files

Every repetition retains the root `metadata.json`, `contract.json`, and `cleanup.json`.
Both scenario directories retain:

- `contract.json`, `k6-metadata.json`, `k6-summary.json`, and `k6-summary.md`
- `samples.jsonl` for the timestamped k6, HAProxy, selected Istio sidecar, application,
  HPA, Pod, and endpoint chain
- `haproxy-stats-before.csv` and `haproxy-stats-after.csv`
- `proxy-metric-mapping.json`, `target-inbound-cluster.json`, and
  `target-inbound-http-config.json` for the selected actual proxy target/no-retry boundary
- `application-observation-path.json` for the direct metrics-scrape bypass proof
- `hpa-final.yaml` and `hpa-events.json`

Raw runs, including failed or dirty-source exploratory runs, remain append-only under
`results/full-capacity-cascade/` and are intentionally not tracked. Curated evidence excludes
them rather than rewriting or deleting them.
