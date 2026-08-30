# Facts and assumptions

이 문서는 incident source와 lab design 사이의 경계를 유지한다.

[status]: https://www.githubstatus.com/incidents/zkxwbgr0cnmx
[blog]: https://github.blog/news-insights/company-news/the-august-17-outage-and-the-work-ahead/

| ID | Classification | Statement | Source | Impact on lab |
| --- | --- | --- | --- | --- |
| F01 | FACT | 장애는 2026-08-17 13:28–21:15 UTC, 총 7시간 47분 지속됐다. | [Status RCA][status] | Incident context의 시간 범위로만 사용한다. |
| F02 | FACT | GitHub.com, API, Issues, Pull Requests, Actions, Copilot, authentication과 여러 서비스에 오류와 지연이 발생했다. | [Status RCA][status], [GitHub blog][blog] | 단일 component capacity failure가 넓은 사용자 영향으로 번질 수 있다는 연구 배경이다. |
| F03 | FACT | 새로운 traffic peak에서 Central US load balancer network가 saturation에 도달했다. | [Status RCA][status] | L00는 peak 자체가 아니라 load-amplifying effect를 측정한다. |
| F04 | FACT | 최초 문제는 Istio sidecar pod의 concurrency limit 도달과 host service만 관찰하고 sidecar capacity를 충분히 반영하지 못한 autoscaling policy로 설명됐다. | [Status RCA][status] | 후속 L04–L05의 sidecar metric과 scaling blind spot 학습 근거다. |
| F05 | FACT | Failure가 연쇄 확산되어 네 HAProxy node가 flow limit을 소진했고 gateway authentication path가 저하됐다. | [Status RCA][status] | 후속 proxy/cascade 단계의 학습 질문을 정의한다. 정확한 topology는 추정하지 않는다. |
| F06 | FACT | Optimistic retry logic가 internal load balancer 부하를 악화시켰다. | [Status RCA][status] | Logical request와 physical attempt를 분리 측정하는 직접 동기다. |
| F07 | FACT | 일부 실패 traffic은 Central US에서 Northern Virginia로 이동해 처리됐다. | [Status RCA][status] | 향후 regional recovery를 검토하되 구체 infrastructure는 추정하지 않는다. |
| F08 | FACT | 복구 중 VS Code의 잠재된 retry behavior가 Copilot Token Service traffic을 약 10배 증폭시켰다. | [Status RCA][status] | Retry amplification을 핵심 관찰값으로 삼는다. 10x를 L00 acceptance로 사용하지 않는다. |
| F09 | FACT | Copilot Token Service traffic은 정상 약 7–9K RPS에서 약 70–100K RPS로 증가했다. | [Status RCA][status] | Official incident 수치이며 local result와 직접 비교하지 않는다. |
| F10 | FACT | Gateway retry 축소, token 요청의 일시적 403 차단, site별 점진적 traffic ramp-up이 복구에 사용됐다. | [Status RCA][status] | 후속 mitigation 단계의 연구 방향이다. |
| F11 | FACT | 후속 조치에는 sidecar-aware autoscaling, Istio limit 점검, gateway/client retry와 backoff 검토, VS Code retry 수정, load balancer monitoring과 regional failover 개선이 포함됐다. | [Status RCA][status] | L04–L09 roadmap 질문의 출처다. |
| F12 | FACT | GitHub는 incident가 직전 code/configuration change로 시작된 것이 아니라 core capacity failure였다고 밝혔다. | [GitHub blog][blog] | Change-trigger reproduction이 아니라 capacity behavior에 초점을 둔다. |
| I01 | INFERENCE | Capacity를 소진하는 component와 scaling metric의 관찰 대상이 다르면 host 지표가 여유로워 보여도 실효 capacity가 부족할 수 있다. | F04에 대한 lab 해석 | L05에서 observable blind spot을 검증할 가설이다. GitHub의 정확한 HPA 설정을 뜻하지 않는다. |
| I02 | INFERENCE | Logical failure에 대한 retry가 physical load를 늘리면 capacity recovery가 지연될 수 있다. | F06, F08에 대한 lab 해석 | Counter 기반 amplification과 recovery 실험 설계의 가설이다. |
| L00-01 | LAB_IMPLEMENTATION | Go `auth-sim`은 고정 placeholder를 반환하는 side-effect-free workload다. GitHub Token Service 복제가 아니다. | Repository L00 design | 실제 auth/JWT/data dependency 없이 request behavior만 통제한다. |
| L00-02 | LAB_IMPLEMENTATION | `max_in_flight`는 application CAS admission limit이며 Istio sidecar concurrency reproduction이 아니다. | Repository L00 design | 초과 request는 queue 없이 즉시 503으로 거절한다. |
| L00-03 | LAB_IMPLEMENTATION | Error decision은 seed, logical request ID, attempt를 hash한 deterministic profile이다. | Repository L00 design | 같은 입력의 비교 재현성을 제공하며 GitHub algorithm을 나타내지 않는다. |
| L00-04 | LAB_IMPLEMENTATION | k6 bad/good retry는 비교용 bounded policy이며 VS Code 또는 GitHub gateway implementation 복제가 아니다. | Repository L00 design | Immediate retry와 bounded backoff/jitter의 physical attempts를 비교한다. |
| L00-05 | LAB_IMPLEMENTATION | Public server와 bearer-protected mutation을 가진 admin server를 loopback 기본값으로 분리한다. | Repository L00 design | Fault control이 workload endpoint와 섞이지 않게 한다. |
| L00-06 | LAB_IMPLEMENTATION | Istio IngressGateway는 현재 L00 범위에 없다. | [Scope](scope.md) | Gateway 종류를 현재 architecture에 그리지 않는다. |
| L01-01 | LAB_IMPLEMENTATION | HAProxy control과 constrained frontend/backend를 한 lab config에 두고 같은 auth-sim service time에서 server `maxconn`과 queue timeout만 비교한다. | Repository L01 config | 선택한 topology와 수치는 GitHub 설정이 아닌 local `lab target`이다. |
| L01-02 | LAB_IMPLEMENTATION | L01 HAProxy와 k6는 retry를 끄고 max attempts 1을 사용한다. | Repository L01 config/scenario | Logical request와 physical attempt가 1:1인 상태에서 proxy capacity를 먼저 관찰한다. |
| L01-03 | LAB_IMPLEMENTATION | Toxiproxy 2.12.0은 HAProxy와 분리된 path에서 downstream latency와 `reset_peer`를 주입한다. | [Toxiproxy upstream](https://github.com/Shopify/toxiproxy) | Toxiproxy는 GitHub 실제 architecture 구성요소가 아니다. |
| L01-04 | LAB_IMPLEMENTATION | HAProxy 3.2.23과 Toxiproxy 2.12.0 image tag, capacity, latency와 timeout 값은 실행 metadata에 기록한다. | Repository L01 runner | 모든 값은 local `lab target`이며 GitHub의 실제 값이나 production 권고가 아니다. |
| L02-01 | LAB_IMPLEMENTATION | `envoyproxy/envoy:v1.39.1` standalone process에 static listener/route/cluster/endpoint를 구성한다. | [Envoy v1.39.1 release](https://github.com/envoyproxy/envoy/releases/tag/v1.39.1), Repository L02 config | 선택한 image와 topology는 local 학습 구현이며 GitHub proxy topology 복제가 아니다. |
| L02-02 | LAB_IMPLEMENTATION | Route timeout 2s/100ms, `retry_on: 5xx`, `num_retries: 2`, cluster `max_requests` 100/1과 20 ops/s·4s workload는 모두 local `lab target`이다. | Repository L02 config/runner | GitHub production 값 또는 권장 tuning으로 표현하지 않는다. |
| L02-03 | LAB_IMPLEMENTATION | k6 `physical_attempts`는 Envoy downstream client attempt이고 `cluster.<name>.upstream_rq_total` delta는 Envoy internal retry를 포함한 upstream attempt다. | [Envoy cluster stats](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats.html), Repository L02 runner | 기존 L00 metric 의미를 유지하면서 proxy 내부 증폭을 별도 계산한다. |
| L02-04 | LAB_IMPLEMENTATION | Envoy v1.39.1의 `max_requests` 소진은 실제 local stats의 `upstream_rq_active_overflow`로 판정하고 pending/retry overflow도 함께 보존한다. | [Envoy circuit breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking), Repository L02 evidence | 오래된 pending overflow 이름만 고정하지 않는다. |
| L02-05 | LAB_IMPLEMENTATION | L02는 향후 Istio sidecar metric 학습을 위한 standalone 기초 단계다. | Repository roadmap | Istio나 GitHub sidecar implementation/config를 재현했다고 주장하지 않는다. |
| U01 | UNKNOWN | GitHub의 정확한 network topology와 Northern Virginia infrastructure topology는 공개되지 않았다. | Official sources에서 확인 불가 | Lab diagram을 GitHub topology로 표현하지 않는다. |
| U02 | UNKNOWN | 정확한 Istio resource, concurrency 값, scaling limit과 HPA metric configuration은 공개되지 않았다. | Official sources에서 확인 불가 | 후속 단계의 값은 lab target으로 별도 선택한다. |
| U03 | UNKNOWN | HAProxy flow implementation의 상세 구조와 gateway가 Istio IngressGateway였는지는 확인할 수 없다. | Official sources에서 확인 불가 | 특정 implementation을 incident FACT로 단정하지 않는다. |
| U04 | UNKNOWN | Central US가 정확히 어떤 Azure resource에 매핑됐는지는 이번 FACT에 포함되지 않는다. | Official sources에서 확인 불가 | L09 Azure design과 incident infrastructure를 동일시하지 않는다. |
| U05 | UNKNOWN | GitHub Token Service의 실제 application code와 gateway/VS Code의 구체 retry algorithm은 공개되지 않았다. | Official sources에서 확인 불가 | L00 code와 retry를 effect model로만 설명한다. |
| U06 | UNKNOWN | GitHub의 정확한 proxy implementation/version, standalone Envoy 여부, proxy topology와 timeout/retry/circuit-breaker 설정은 공개 RCA만으로 확인할 수 없다. | Official sources에서 확인 불가 | L02 Envoy 선택과 모든 설정을 GitHub production 사실로 설명하지 않는다. |
