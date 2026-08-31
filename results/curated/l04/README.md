# L04 Curated Evidence

- Learning unit: **L04 — Istio Sidecar and Proxy Metrics**
- Classification: **Local exploratory evidence**
- Source branch: `feat/l04-istio-sidecar-metrics`
- Source commit: `5a5d1fc8623a6cd4681247678b233eaa96c155ab`
- Source raw run: `results/istio-sidecar/20260831T082718Z/`
- Curated pair: [`istio-sidecar-pair/`](istio-sidecar-pair/)

이 set은 `git_dirty=false` clean source에서 한 번 실행한 paired local run의 검토 사본이다.
Root/pair contract와 cleanup contract가 PASS이고, 아래 파일은 모두 raw 원문과 byte-for-byte
동일하다. 단일 local machine 결과이므로 portfolio evidence, production benchmark, sizing 또는
GitHub production topology/configuration evidence가 아니다.

## Runtime identity and isolation

| Item | Observed value |
| --- | --- |
| k3d / K3s / Kubernetes server | `v5.9.0` / `v1.35.5-k3s1` / `v1.35.5+k3s1` |
| Topology | server 1, agent 0; dynamic loopback Kubernetes API |
| Istio | `1.30.4`; Helm `istio-base` then `istiod`; control-plane replica 1, HPA disabled |
| Istiod image ID | `registry.istio.io/release/pilot@sha256:c236c1df5cc127fe193e5a17d8ece9cdd0dc17c5d89b4e20baf01d464f029dce` |
| Injected proxy image ID | `registry.istio.io/release/proxyv2@sha256:43b6aeab7428470d3d0ea6b6f0bc217e5b36df2b279bba337643df48590226d9` |
| Actual Envoy build | `ce177c56fe75661f16b654e2f164d4ab02058222/1.38.4-dev/Clean/RELEASE/BoringSSL` |
| auth-sim / k6 image | `capacity-cascade/auth-sim:l04-5a5d1fc8623a` / `grafana/k6@sha256:9bd01d6941fca969cb61bb57d2da5ee9b385fe2aa8881df3798c196564d6ace6` |
| Injection / isolation | namespace `istio-injection=enabled`; actual Pod Ready 2/2; separate namespaces, releases, Pods and fresh proxy counters |

Gateway, Ambient, ztunnel, Istio CNI, HPA/KEDA, Prometheus/Grafana and tracing were not installed.
The native-sidecar form records `istio-proxy` as a restarting init container; actual Pod state shows
both `auth-sim` and `istio-proxy` Ready.

## Comparison and datapath

Both scenarios fixed the source/image/version, replica 1, 250 ms latency, error 0,
`max_in_flight=0`/unlimited, 20 ops/s for 4 s, 1 s timeout, seed `17082026`, logical-ID namespace,
client retry none/max attempts 1, proxy retry none, data path and 0.5 s sampling. The intended
comparison variable was target inbound port 8080 Sidecar `http2MaxRequests` only.

| Scenario | Target cluster | Actual `max_requests` | Normalized config |
| --- | --- | ---: | --- |
| sidecar-control | `inbound|8080||` | 100 | PASS |
| sidecar-constrained | `inbound|8080||` | 1 | PASS |

[`comparison-config-actual.diff`](istio-sidecar-pair/comparison-config-actual.diff) retains the target
capacity and required isolation-identity differences. [`comparison-normalization.json`](istio-sidecar-pair/comparison-normalization.json)
documents their removal; [`comparison-config-normalized.diff`](istio-sidecar-pair/comparison-config-normalized.diff)
is empty.

The workload path was non-injected k6 Job → scenario ClusterIP Service FQDN `:8080` → target inbound
sidecar → auth-sim `:8080`. Target proxy downstream delta was 80 in both scenarios. Direct Pod metrics
port-forward was separately proven to be an observation-only bypass (proxy downstream delta 0).

Before the no-retry fallback, selected 1.30.4 inbound routes had `retry_on: reset-before-request` and
`num_retries: 2`. The selected exact `SIDECAR_INBOUND` virtual-host fallback is preserved before/after;
after fresh Pod rollout both scenarios have route retry count/budget 0 and proxy retry delta 0. It is a
version-specific lab fallback, not GitHub configuration evidence.

## Actual observation

The selected proxy emitted scenario-specific `http.inbound_<pod-ip>_8080;.downstream_rq_*` and
`cluster.inbound|8080||;.upstream_rq_*` names. Each actual mapping and stats snapshot is retained.

| Observation | Control | Constrained |
| --- | ---: | ---: |
| k6 logical / physical / retry attempts | 80 / 80 / 0 | 80 / 80 / 0 |
| k6 200 / 503; logical failure rate | 80 / 0; 0 | 14 / 66; 0.825 |
| Proxy downstream / 5xx / upstream delta | 80 / 0 / 80 | 80 / 66 / 14 |
| Proxy active-overflow / pending-overflow delta | 0 / 0 | 66 / 0 |
| Proxy retry / timeout delta | 0 / 0 | 0 / 0 |
| Application token / admission-rejection delta | 80 / 0 | 14 / 0 |
| Application in-flight / proxy active peak | 5 / 5 | 1 / 1 |
| UTC samples total / during workload | 16 / 14 | 16 / 14 |

In the constrained run, proxy active overflow and 503s occur while application admission rejection
remains 0; upstream and application token deltas are 14 against 80 downstream/logical requests. This
is observed local evidence that the rejected requests did not reach auth-sim admission, not an HPA
result or an exact GitHub implementation claim.

The single Metrics API snapshots were control `auth-sim` 3m CPU/3Mi and `istio-proxy` 31m/29Mi,
then constrained 5m/5Mi and 58m/28Mi. They are not a capacity authority, benchmark or sizing advice.

## Cleanup and selected files

`cleanup.json` records runner exit 0; scenario resources, Istio Helm releases, namespaces and exact
cluster removed; zero remaining owned containers/networks/processes; temporary kubeconfig/Helm state
removed; and original kube context/global Helm configuration unchanged.

The curated pair includes root identity/chart/control-plane/config-diff/contract/cleanup/summary and,
for each scenario, injected workload state, Sidecar/EnvoyFilter resource, target cluster/route,
Service/EndpointSlice/datapath proof, actual proxy mapping/stats, application metrics/samples/usage,
k6 metadata/summary and scenario contract. Full config dumps, rendered manifests, command/port-forward/
Secret creation/k6 console logs and temporary files remain in the append-only raw notebook. No redaction
or measured-value editing was applied; development and incomplete raw runs were not curated.

## Limitations

- Portfolio comparison requires at least three fixed repetitions.
- Local K3s topology, Istio version/images, `100 → 1` target, workload and EnvoyFilter are
  `LAB_IMPLEMENTATION` only.
- It does not establish GitHub's exact sidecar version, request-concurrency mechanism/value, Pod
  topology, route/filter config, resources or autoscaling metric/threshold.
- L05 HPA, gateway, Ambient, mTLS, retry experiments, full cascade and production tuning are excluded.
