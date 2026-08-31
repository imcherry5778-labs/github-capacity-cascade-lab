# Source Register

이 register는 2026-08-17 incident FACT, 2026 reliability context, historical GitHub
architecture, component documentation과 별도 incident를 분리한다. Freshness audit 기준일은
**2026-08-31**이다.

## Source policy

- `FACT`는 `PRIMARY_INCIDENT_SOURCE`가 직접 지원하는 범위 안에서만 작성한다.
- `INFERENCE`는 공개 사실에서 도출한 lab 가설이며 GitHub의 확인된 설명이 아니다.
- `LAB_IMPLEMENTATION`은 이 저장소가 failure effect를 관찰하기 위해 선택한 topology,
  version, config와 metric contract다.
- `UNKNOWN`은 primary source가 공개하지 않은 topology, 값, algorithm 또는 mapping이다.
- Incident claim은 primary source를 우선한다. Context나 historical source가 더 상세해 보여도
  2026-08-17의 원인, topology 또는 configuration을 대신 입증하지 않는다.
- Historical source는 발행 당시의 GitHub architecture 또는 operation만 설명한다.
- Component documentation은 lab configuration, metric, version과 command contract만
  지원한다. GitHub가 2026년에 같은 component나 설정을 사용했다는 증거가 아니다.
- 다른 incident의 비슷한 capacity, retry 또는 recovery pattern은 August 17 Core FACT에
  합치지 않는다.

### Freshness record

- `RCA-01`의 [Status API metadata](https://www.githubstatus.com/api/v2/incidents.json)에서
  resolved update는 2026-08-17 21:15 UTC에
  게시됐고 2026-08-18 19:21 UTC에 마지막으로 수정됐다. 현재 원문과 metadata를
  2026-08-31에 다시 확인했다.
- `RCA-02` page metadata는 2026-08-20 18:36 UTC 발행, 19:32 UTC 수정을 표시한다.
  현재 원문을 2026-08-31에 다시 확인했다.
- 공식 GitHub Status, GitHub Blog와
  [GitHub Availability Report archive](https://github.blog/tag/github-availability-report/)를
  확인했지만
  August 17을 직접 다루는 추가 RCA/addendum는 확인되지 않았다.
- **GitHub availability report: August 2026**은 2026-08-31 현재 발행되지 않았다. Archive의
  최신 월간 보고서는 July 2026이다.
- August 26 Actions incident 자료는 새 공식 자료지만 August 17과 별개의
  `RELATED_INCIDENT`다. `RCA-01`/`RCA-02`와 충돌하거나 이를 보완하는 August 17 source로
  승격하지 않는다.

## Primary incident sources

| ID | Published / Updated | Title | Source type | Supports | Does not support | Relevant learning units | Verification status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| RCA-01 | Incident: 2026-08-17; resolved update edited 2026-08-18 19:21 UTC | [GitHub Status — Incident with GitHub.com](https://www.githubstatus.com/incidents/zkxwbgr0cnmx) | `PRIMARY_INCIDENT_SOURCE` | Incident window, user impact, error rates, service-specific recovery, Central US saturation, sidecar/scaling issue, HAProxy flow exhaustion, retry amplification, recovery actions, codeload complication과 follow-up actions | Exact private topology, exact HPA/Istio/HAProxy values, gateway type, retry algorithm과 Central US의 Azure resource mapping | L00–L07 failure questions; L09 boundary; L10 source integrity | VERIFIED 2026-08-31 |
| RCA-02 | Published 2026-08-20 18:36 UTC; modified 19:32 UTC | [The August 17 outage, and the work ahead](https://github.blog/news-insights/company-news/the-august-17-outage-and-the-work-ahead/) | `PRIMARY_INCIDENT_SOURCE` | Broad impact, traffic peak와 capacity failure framing, staged recovery, client retry loop, code/config change가 trigger가 아니었다는 설명과 August 6/17 이후 reliability commitments | Status RCA의 세부 timeline을 대체하지 않으며, exact component topology/config 또는 August 17만의 모든 후속 조치 완료 여부 | L00 framing; L06–L07 cascade/mitigation; L10 narrative | VERIFIED 2026-08-31 |

`RCA-02`가 August 6과 August 17에 공통으로 적용한다고 명시한 조치는 두 incident에 대한
공동 reliability response다. August 17의 개별 technical FACT가 필요할 때는 `RCA-01`을
사용한다.

## Official reliability context

| ID | Published / Updated | Title | Source type | Supports | Does not support | Relevant learning units | Verification status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CTX-01 | 2026-03-11 | [Addressing GitHub’s recent availability issues](https://github.blog/news-insights/company-news/addressing-githubs-recent-availability-issues-2/) | `OFFICIAL_RELIABILITY_CONTEXT` | 2026 reliability program의 rapid load growth, architectural coupling, load shedding/throttling, isolation, capacity와 Azure migration 방향 | August 17의 cause, topology, component 또는 mitigation 순서 | L05–L07의 context와 L09 source boundary | VERIFIED 2026-08-31 |
| CTX-02 | 2026-04-28 | [An update on GitHub availability](https://github.blog/news-insights/company-news/an-update-on-github-availability/) | `OFFICIAL_RELIABILITY_CONTEXT` | 성장 압력에서 queue/retry/coupling이 결합되는 일반 context, critical-service isolation과 graceful degradation 방향 | August 17의 exact traffic peak, sidecar policy, HAProxy 또는 regional path | L05–L07 interpretation boundary | VERIFIED 2026-08-31 |
| CTX-03 | 2026-07-08 | [GitHub availability report: June 2026](https://github.blog/news-insights/company-news/github-availability-report-june-2026/) | `OFFICIAL_RELIABILITY_CONTEXT` | Azure traffic ramp, stability gate와 점진적 turn-up에 관한 June 2026 program context | August 17의 traffic ramp, region topology 또는 recovery action을 입증하지 않음 | L07 recovery experiment와 L09 cloud-boundary context | VERIFIED 2026-08-31 |
| CTX-04 | 2026-04-17 | [Bringing more transparency to GitHub’s status page](https://github.blog/news-insights/company-news/bringing-more-transparency-to-githubs-status-page/) | `OFFICIAL_RELIABILITY_CONTEXT` | Status severity와 공개 communication 방식의 2026 변경 | August 17의 원인, impact 수치 또는 technical mitigation | L10 evidence/source governance | VERIFIED 2026-08-31 |

## Historical architecture context

이 section의 source type은 모두 `HISTORICAL_ARCHITECTURE_CONTEXT`다.

| ID | Published / Updated | Title | Supports | Required limitation | Relevant learning units | Verification status |
| --- | --- | --- | --- | --- | --- | --- |
| HIST-LB-01 | 2016-09-22 / updated 2019-03-08 | [Introducing the GitHub Load Balancer](https://github.blog/engineering/infrastructure/introducing-glb/) | 발행 당시 GitHub의 GLB design goals와 L4/L7 load-balancing context | This source provides historical GitHub architecture or operational context. It does not establish GitHub's exact August 17, 2026 topology or configuration. | L01 historical vocabulary only | VERIFIED 2026-08-31 |
| HIST-LB-02 | 2016-12-01 / updated 2019-03-08 | [GLB part 2: HAProxy zero-downtime, zero-delay reloads with multibinder](https://github.blog/news-insights/glb-part-2-haproxy-zero-downtime-zero-delay-reloads-with-multibinder/) | 발행 당시 GLB proxy tier와 HAProxy reload/instance 운영 context | This source provides historical GitHub architecture or operational context. It does not establish GitHub's exact August 17, 2026 topology or configuration. | L01 HAProxy context only | VERIFIED 2026-08-31 |
| HIST-K8S-01 | 2017-08-16 | [Kubernetes at GitHub](https://github.blog/engineering/infrastructure/kubernetes-at-github/) | 발행 당시 github.com/API workload의 Kubernetes migration context | This source provides historical GitHub architecture or operational context. It does not establish GitHub's exact August 17, 2026 topology or configuration. | L03 historical context only | VERIFIED 2026-08-31 |
| HIST-K8S-02 | 2023-08-02 | [How we build containerized services at GitHub using GitHub](https://github.blog/engineering/architecture-optimization/how-we-build-containerized-services-at-github-using-github/) | 2023년 GitHub paved path, Kubernetes base layer와 multi-cluster/multi-region 운영 context | This source provides historical GitHub architecture or operational context. It does not establish GitHub's exact August 17, 2026 topology or configuration. | L03–L05 historical context only | VERIFIED 2026-08-31 |

## Component primary documentation

이 section의 source type은 모두 `COMPONENT_PRIMARY_DOCUMENTATION`이다.
아래 source는 repository가 L01–L04에서 실제 선택한 component와 contract에만 적용한다.
`Does not support` 제한은 각 source에 독립적으로 적용된다.

| ID | Version / source | Supports | Does not support | Relevant learning units | Verification status |
| --- | --- | --- | --- | --- | --- |
| COMP-HA-01 | [HAProxy 3.2.23 Configuration Manual](https://docs.haproxy.org/3.2/configuration.html) | L01 `maxconn`, queue, retry/redispatch와 stats field의 configuration 의미 | GitHub의 2026 HAProxy version, topology, flow implementation 또는 limit | L01 | VERIFIED 2026-08-31 |
| COMP-TOX-01 | [Toxiproxy upstream](https://github.com/Shopify/toxiproxy) / [v2.12.0 release](https://github.com/Shopify/toxiproxy/releases/tag/v2.12.0) | L01 proxy/toxic API와 selected release identity | Toxiproxy가 GitHub architecture에 존재한다는 주장 | L01 | VERIFIED 2026-08-31 |
| COMP-ENV-01 | [Envoy v1.39.1 release](https://github.com/envoyproxy/envoy/releases/tag/v1.39.1) | L02 selected upstream release identity | GitHub의 Envoy version, standalone topology 또는 Istio sidecar implementation | L02 | VERIFIED 2026-08-31 |
| COMP-ENV-02 | [Envoy cluster statistics](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats.html) | Cluster request/retry/timeout/overflow metric 의미 | Online `latest` 문서만으로 L02 v1.39.1 actual output 또는 GitHub metric을 입증하지 않음; L02 evidence가 selected binary의 관찰 근거 | L02, L04 metric vocabulary | VERIFIED 2026-08-31; online docs reported 1.40.0-dev |
| COMP-ENV-03 | [Envoy circuit breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking) | `max_requests`와 backpressure/overflow contract | GitHub의 circuit-breaker setting이나 August 17 HAProxy flow limit 의미 | L02, L04 | VERIFIED 2026-08-31; online docs reported 1.40.0-dev |
| COMP-K3D-01 | [k3d v5.9.0 documentation](https://k3d.io/v5.9.0/) / [v5.9.0 release](https://github.com/k3d-io/k3d/releases/tag/v5.9.0) | L03 local K3s-in-Docker cluster command/version contract | GitHub production Kubernetes platform 또는 topology | L03 | VERIFIED 2026-08-31 |
| COMP-K3S-01 | [K3s v1.35.5+k3s1 release](https://github.com/k3s-io/k3s/releases/tag/v1.35.5%2Bk3s1) | L03 pinned K3s release identity | GitHub production Kubernetes distribution/version | L03 | VERIFIED 2026-08-31 |
| COMP-HELM-01 | [helm upgrade](https://helm.sh/docs/helm/helm_upgrade/) | L03 `upgrade --install` command contract | GitHub의 deployment tooling 또는 Helm 사용 | L03 | VERIFIED 2026-08-31 |
| COMP-K8S-01 | [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) | Deployment rollout/replacement와 availability contract | GitHub의 exact workload controller, replica 또는 rollout setting | L03 | VERIFIED 2026-08-31 |
| COMP-K8S-02 | [Kubernetes Service](https://kubernetes.io/docs/concepts/services-networking/service/) | ClusterIP, selector와 target port contract | GitHub의 service/network topology | L03 | VERIFIED 2026-08-31 |
| COMP-IST-01 | [Istio supported releases](https://istio.io/latest/docs/releases/supported-releases/) / [Istio 1.30.4 announcement](https://istio.io/latest/news/releases/1.30.x/announcing-1.30.4/) | L04 selected Istio 1.30.4 release identity와 supported Kubernetes overlap 검토 | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-02 | [Istio Helm install](https://istio.io/latest/docs/setup/install/helm/) | L04 pinned `istio-base` → `istiod` Helm install contract | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-03 | [Automatic sidecar injection](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/) | Namespace label based automatic injection과 Pod-level verification contract | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-04 | [Envoy statistics](https://istio.io/latest/docs/ops/configuration/telemetry/envoy-stats/) | ProxyStatsMatcher와 selected proxy stats discovery/interpretation contract | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. Actual selected proxy output remains the metric-name authority. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-05 | [Sidecar API](https://istio.io/latest/docs/reference/config/networking/sidecar/) | Workload-selected inbound connection pool과 `http2MaxRequests` API meaning | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-06 | [ProxyConfig API](https://istio.io/latest/docs/reference/config/networking/proxy-config/) | `ProxyConfig.concurrency`가 Envoy worker thread setting이며 L04 active-request limit이 아니라는 boundary | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4 |
| COMP-IST-07 | [EnvoyFilter API](https://istio.io/latest/docs/reference/config/networking/envoy-filter/) | Selected 1.30.4 generated inbound retry를 no-retry contract로 교체하는 bounded fallback의 API/upgrade-fragility warning | GitHub의 August 17, 2026 exact Istio version, sidecar configuration, concurrency value 또는 production topology를 지원하지 않는다. | L04 | VERIFIED 2026-08-31; selected version 1.30.4; fallback used |

## Related incidents excluded from Core

이 section의 source type은 모두 `RELATED_INCIDENT`다.

| ID | Incident | Why related | Exclusion rule | Verification status |
| --- | --- | --- | --- | --- |
| REL-01 | [August 6, 2026 — Incident with Actions](https://www.githubstatus.com/incidents/qcvjkzcs7j74) | Capacity/concurrency weakness, cascading impact, throttling과 retry가 등장한다. | August 17의 cause, timeline, impact 또는 component FACT에 합치지 않는다. | VERIFIED 2026-08-31 |
| REL-02 | [August 26, 2026 — Incident with Actions](https://www.githubstatus.com/incidents/y1t7p9fzrlj2) | Database write saturation, burst amplification, throttling과 gradual ramp가 등장한다. | 별도 Actions incident이며 August 17 Core FACT 또는 mitigation evidence가 아니다. | VERIFIED 2026-08-31 |
| REL-03 | [August 26, 2026 — Incident with Actions and Pull Requests](https://www.githubstatus.com/incidents/kfspvrz14xr0) | Saturation detection, retry bound와 backpressure follow-up이 등장한다. | 같은 날짜의 `REL-02`와도 별개이며 August 17 Core에 포함하지 않는다. | VERIFIED 2026-08-31 |

## Reviewed candidates not registered

| Candidate | Disposition | Reason |
| --- | --- | --- |
| [GitHub availability report: May 2026](https://github.blog/news-insights/company-news/github-availability-report-may-2026/) | NOT REGISTERED | `CTX-01`/`CTX-02`와 reliability program 설명이 중복되고 August 17을 직접 다루지 않는다. |
| [GitHub availability report: July 2026](https://github.blog/news-insights/company-news/github-availability-report-july-2026/) | NOT REGISTERED | August 17 이전 발행이며 July incidents와 August 6 preview가 중심이다. August 17 Core에 고유 지원을 추가하지 않는다. |
| GitHub availability report: August 2026 | NOT AVAILABLE | 2026-08-31 현재 official archive에 발행되지 않았다. |
| [GLB: GitHub’s open source load balancer](https://github.blog/engineering/infrastructure/glb-director-open-source-load-balancer/) | NOT REGISTERED | Source quality는 높지만 현재 필요한 historical boundary는 `HIST-LB-01`/`02`로 충족되며 내용이 중복된다. |
| [Debugging network stalls on Kubernetes](https://github.blog/engineering/infrastructure/debugging-network-stalls-on-kubernetes/) | NOT REGISTERED | 2019년의 별도 latency investigation으로 August 17 saturation과 혼동될 위험이 있고 현재 learning question에 고유 지원이 없다. |
| [Deployment reliability at GitHub](https://github.blog/developer-skills/github/deployment-reliability-at-github/) | NOT REGISTERED | Historical deployment mechanics가 중심이며 L00–L07 failure-chain source로 필요하지 않다. |
| [Using ChatOps to help Actions on-call engineers](https://github.blog/engineering/infrastructure/using-chatops-to-help-actions-on-call-engineers/) | NOT REGISTERED | On-call workflow context로 현재 incident claim 또는 component contract를 지원하지 않는다. |
