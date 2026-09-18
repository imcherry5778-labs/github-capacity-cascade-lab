# L11 Curated Evidence

- Learning unit: **L11 — Sidecar vs Ambient Architecture Comparison (Optional Extension)**
- Classification: **Local exploratory evidence; fixed-condition repetition set**
- Source branch: `feat/l11-sidecar-ambient`
- Source commit: `00d6b81af23fe6d6bc696f3608c8b9e31d458362`
- Raw runs: `results/sidecar-ambient/20260918T155700Z/`, `results/sidecar-ambient/20260918T160022Z/`,
  and `results/sidecar-ambient/20260918T160350Z/`

이 set은 clean source에서 실행한 paired local run 세 개를 포함한다. 아래 selected file은
named raw run에서 redaction이나 measured-value 편집 없이 복사했고 `cmp`로 byte-for-byte
확인했다. 세 root/scenario contract는 모두 PASS이고, 세 `metadata.json`은
`git_dirty=false`이며, 모든 `cleanup.json`은 runner exit `0`과 owned
container/network/port-forward `0`을 기록한다. Failed 또는 dirty-source exploratory
run은 append-only raw notebook에만 남긴다.

이 문서는 **어느 architecture가 우월한지 판정하지 않는다.** 목적은 destination proxy
placement가 바뀔 때 observable capacity/resource signal, proxy ownership, request path가
어떻게 달라지는지를 이번 fixed local 실험 범위에서 기록하는 것이다.

## Runtime identity와 fixed comparison

각 repetition은 dynamic loopback API exposure의 fresh server-1/agent-0 k3d cluster,
K3s `v1.35.5+k3s1`, Kubernetes server `v1.35.5+k3s1`, pinned Istio `1.30.4`
(`istio-base` → `istiod` → `istio-cni` → `ztunnel`, waypoint/Gateway API CRD 없음),
`capacity-cascade/auth-sim:l11-00d6b81af23f`, `grafana/k6:2.2.0`을 사용했다. `istiod`
image는 `pilot:1.30.4-distroless`, sidecar proxy는 `proxyv2:1.30.4-distroless`(Envoy
`1.38.4-dev`), Istio CNI는 `install-cni:1.30.4-distroless`, ztunnel은 `ztunnel:1.30.4`다.
`gateway-api-crd-present=false`— L11은 Gateway API CRD를 설치하지 않았고, istiod는 그
상태에서도 Ready를 유지했다(ISTIO OFFICIAL FACT/MEASURED EVIDENCE 경계는 아래 참고).

두 scenario는 source/image, 같은 auth-sim Helm chart, application latency `250 ms`,
error `0`, admission unlimited, logical rate `20 ops/s`·`4 s`, request timeout `1 s`,
client retry none/max attempts `1`, `0.5 s` sampling과 exact cleanup을 공유한다.
Sidecar에는 artificial capacity constraint(`http2MaxRequests` 등)나 `kind: Sidecar` CR을
전혀 만들지 않았다 — 이 비교는 saturation 실험이 아니라 **동일 조건에서의 가시성/소유권**
비교다. 의도한 유일한 변수는 destination proxy placement다.

| Scenario | Destination proxy | Enrollment | Injection |
| --- | --- | --- | --- |
| `sidecar` | Pod-local `istio-proxy` (Envoy) | namespace `istio-injection=enabled` | automatic sidecar injection |
| `ambient-ztunnel` | node-local `ztunnel` (Rust, L3/L4 only) | namespace `istio.io/dataplane-mode=ambient` | none (no Pod-local proxy container) |

## MEASURED EVIDENCE: preflight discovery (pinned 1.30.4 vs actual k3d/K3s runtime)

- **CNI bin path mismatch.** Pinned 1.30.4 `istio/cni` chart's built-in k3d platform
  override (`files/profile-platform-k3d.yaml`, activated by `global.platform=k3d`) sets
  `cniBinDir: /bin`. On this lab's actual `rancher/k3s:v1.35.5-k3s1` node, this is wrong:
  kubelet reported `failed to find plugin "istio-cni" in path
  [/var/lib/rancher/k3s/data/cni]` (`FailedCreatePodSandBox`), and inspecting the node
  filesystem showed flannel/bridge/portmap already living at
  `/var/lib/rancher/k3s/data/cni/*` as symlinks to `/bin/cni`. `l11/cni-ambient-values.yaml`
  explicitly overrides `cni.cniBinDir=/var/lib/rancher/k3s/data/cni` (user-supplied values
  win over the chart's bundled profile merge); after that, ztunnel and istio-cni-node both
  reached Ready. This is a real difference from the chart's bundled assumption for this
  pinned k3s version, not an upstream Istio 1.30.4 documentation error — it is recorded
  here rather than silently worked around.
- **Gateway API CRD not required.** Current upstream "latest" ambient install docs list
  Gateway API CRDs as a prerequisite. At pinned 1.30.4, inspecting the actual
  `istio-base`/`istiod`/`istio-cni`/`ztunnel` chart templates found only RBAC read
  permissions for the `gateway.networking.k8s.io` group (no capability gate on the CRD's
  presence, no `GatewayClass`/`Gateway` object created by these charts). L11 does not
  install the Gateway API CRD; `gateway-api-crd-present=false` in all three repetitions,
  and `istiod` remained Ready with no Gateway-API-related error in its logs. This applies
  to this waypoint-less, Gateway-less scope only.
- **ztunnel metrics/logs.** ztunnel exposes Prometheus text metrics on port `15020` at
  `/stats/prometheus` (confirmed from the chart's own `podAnnotations`, not only from
  docs) and prints one `access: connection complete` log line per finished TCP connection
  at INFO level by default. Both were used as MEASURED EVIDENCE sources below.

## Repeated actual observation

아래 값은 re-measure하지 않고 각 root [`contract.json`](repetition-1/contract.json)과
scenario `contract.json`에서 복사했다. Sidecar는 Pod-local HTTP L7 counter, Ambient는
node-local ztunnel TCP L4 counter다 — **두 counter는 서로 다른 관찰 단위이며 numeric
capacity equivalence를 주장하지 않는다.**

| Repetition | Sidecar logical/physical/retry | Sidecar 200/503; downstream delta; upstream delta; token delta | Ambient logical/physical/retry | Ambient 200/503; TCP opened/closed; sent/received bytes; token delta |
| --- | --- | --- | --- | --- |
| 1 | 81 / 81 / 0 | 81 / 0; 81; 81; 81 | 80 / 80 / 0 | 80 / 0; 80/80; 25740/21990; 80 |
| 2 | 80 / 80 / 0 | 80 / 0; 80; 80; 80 | 81 / 81 / 0 | 81 / 0; 81/81; 26062/22265; 81 |
| 3 | 80 / 80 / 0 | 80 / 0; 80; 80; 80 | 81 / 81 / 0 | 81 / 0; 81/81; 26062/22265; 81 |

세 repetition 모두 두 scenario에서 `logical_requests == physical_attempts`,
`retry_attempts == 0`, `status_503 == 0`, application admission rejection `0`을 보였다
(constant-arrival-rate executor의 정상적인 ±1 jitter로 80/81 왕복이 있다). Sidecar는
Pod가 `Ready 2/2`이고 자동 주입된 `istio-proxy`의 inbound downstream/upstream counter
delta가 logical count와 정확히 일치했다. Ambient는 Pod가 `Ready 1/1`이고 `istio-proxy`
container가 전혀 없으며(`no_sidecar_container=true`), namespace가
`istio.io/dataplane-mode=ambient`로 실제 enrollment되어 있었고(`ambient_enrolled=true`),
destination 노드의 ztunnel TCP `connections_opened`/`connections_closed` delta가 logical
count와 정확히 일치했다(opened == closed, 즉 모든 connection이 정상 종료됨).

두 scenario 모두 direct Pod metrics port-forward가 각각의 target proxy counter(sidecar
downstream / ztunnel opened)를 증가시키지 않음을 별도로 증명했다
(`application_metrics_proxy_bypass` / `application_metrics_ztunnel_bypass` 모두 `true`) —
observation path가 workload data path와 분리되어 있다는 뜻이다.

## Sidecar retry-disable proof (L04와 동일한 fallback, L11 전용 manifest)

Selected 1.30.4 inbound route는 generated retry policy를 가지고 있었다(L04에서 이미
발견한 것과 동일한 version-specific 동작). L11은 L04 파일을 재사용하지 않고 L11 전용
`l11/retry-disabled-sidecar.yaml` `EnvoyFilter`(`SIDECAR_INBOUND` + workload selector로
scope 고정)를 적용해 패치 후 fresh Pod에서
[`target-inbound-http-after-retry-disable.json`](repetition-1/sidecar/target-inbound-http-after-retry-disable.json)의
`retry_policy` 필드가 완전히 제거됐음을 확인했다. 이 fallback은 waypoint로 옮기지 않았고
Ambient scenario에는 적용하지 않았다(ztunnel은 애초에 L7 retry를 수행하지 않는다).

## Ambient observation path (ztunnel-only, L4 중심)

[`ztunnel-metric-mapping.json`](repetition-1/ambient-ztunnel/ztunnel-metric-mapping.json)이
보여주듯, 실제 `/stats/prometheus` 노출값에서 `destination_workload="auth-sim-ambient"`
label을 grep으로 찾아 filter로 선택했다(label 이름을 미리 하드코딩하지 않음). 대응하는
[`ztunnel-access-log-matched.txt`](repetition-1/ambient-ztunnel/ztunnel-access-log-matched.txt)에는
실제 `access: connection complete` 로그가 있다. 예:

```text
2026-09-18T15:48:52.245611Z info access connection complete src.addr=10.42.0.14:46862
dst.addr=10.42.0.12:8080 dst.service="auth-sim-ambient.capacity-cascade-l11-ambient.svc.cluster.local"
dst.workload="auth-sim-ambient-79bccfd99-58nwg" dst.namespace="capacity-cascade-l11-ambient"
direction="inbound" bytes_sent=320 bytes_recv=274 duration="251ms"
```

`duration`이 주입한 application latency(`250 ms`)와 거의 일치하고, `direction="inbound"`,
`dst.workload`가 target auth-sim Pod와 일치한다 — request가 실제로 destination ztunnel을
통과했다는 직접 증거다. 이 로그 줄에는 `src.workload`/`src.identity`가 없다 — k6 load
generator가 out-of-mesh(plain TCP) source이기 때문이며, ztunnel이 source 쪽 ambient
identity를 모른다는 것을 보여준다(source 자체가 Ambient HBONE identity를 가졌다는 뜻이
아니다).

## Topology-only scaling observation (HPA 없음)

각 scenario에서 workload replica를 `1 → 2`로 수동 scale한 뒤 오직 object count만
관찰했다([`topology-scaling-observation.json`](repetition-1/sidecar/topology-scaling-observation.json),
[`topology-scaling-observation.json`](repetition-1/ambient-ztunnel/topology-scaling-observation.json)).

| Scenario | workload Pod count (replicas=2) | proxy container count | node-local CNI+ztunnel DaemonSet ready pods (전/후) |
| --- | --- | --- | --- |
| sidecar | 2 | 2 (Pod당 1개, 1:1) | 2 / 2 (변화 없음) |
| ambient-ztunnel | 2 | 0 | 2 / 2 (변화 없음) |

세 repetition 모두 이 결과가 동일했다. Cluster가 1 node뿐이므로 DaemonSet ready pod
합계는 node 수(1)에 묶여 있고, workload replica 수와 무관하게 유지된다. Sidecar
proxy는 workload Pod와 1:1로 lifecycle이 결합하고, ztunnel/CNI는 node scope에서 공유된다
— 이는 official architecture(per-node ztunnel, per-Pod sidecar)와 이번 실제 topology
관찰이 일치함을 보여줄 뿐, blast-radius 크기나 실제 장애 영향 범위를 측정한 것이 아니다.

## Selection boundary and limitations

Full config dump, ztunnel raw stats inventory, rendered manifest, command/port-forward/Secret
lifecycle log, temporary file, failed/raw-only run은 의도적으로 curate하지 않았다. 이
selection에는 token, credential, kubeconfig, complete environment dump나 private absolute
path가 없다.

- Istio version/install order, namespace label, workload rate/latency/timeout, sampling
  interval, cleanup contract는 모두 `LAB_IMPLEMENTATION`이다.
- ztunnel per-node L3/L4-only 동작, waypoint optional, sidecar/ambient 공존, 표준 TCP
  metric 목록은 official Istio ambient documentation이 지원하는 `ISTIO OFFICIAL FACT`다.
- 이 결과는 **fixed local unconstrained workload에서** sidecar가 Pod-local HTTP L7
  counter를, ztunnel-only ambient가 node-local TCP L4 counter를 노출하며, proxy
  lifecycle/ownership이 각각 Pod-scope/node-scope로 다르다는 narrow local inference를
  지원한다.
- `http2MaxRequests` saturation 재현, HPA, blast-radius fault injection, production
  performance/memory 절감률, GitHub의 실제 Ambient 채택 여부는 이 unit의 범위 밖이며
  `UNKNOWN`/`NOT MEASURED`다.
- Sidecar HTTP counter와 ztunnel TCP counter의 숫자가 비슷하게 나오더라도(예: 위 표의
  bytes 값) 이는 `noConnectionReuse` LAB workload behavior 때문이며 architecture-equivalent
  capacity metric이 아니다. 어느 architecture가 우월한지에 대한 결론은 이 문서 범위 밖이다.
