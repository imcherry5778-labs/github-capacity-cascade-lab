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
| U01 | UNKNOWN | GitHub의 정확한 network topology와 Northern Virginia infrastructure topology는 공개되지 않았다. | Official sources에서 확인 불가 | Lab diagram을 GitHub topology로 표현하지 않는다. |
| U02 | UNKNOWN | 정확한 Istio resource, concurrency 값, scaling limit과 HPA metric configuration은 공개되지 않았다. | Official sources에서 확인 불가 | 후속 단계의 값은 lab target으로 별도 선택한다. |
| U03 | UNKNOWN | HAProxy flow implementation의 상세 구조와 gateway가 Istio IngressGateway였는지는 확인할 수 없다. | Official sources에서 확인 불가 | 특정 implementation을 incident FACT로 단정하지 않는다. |
| U04 | UNKNOWN | Central US가 정확히 어떤 Azure resource에 매핑됐는지는 이번 FACT에 포함되지 않는다. | Official sources에서 확인 불가 | L09 Azure design과 incident infrastructure를 동일시하지 않는다. |
| U05 | UNKNOWN | GitHub Token Service의 실제 application code와 gateway/VS Code의 구체 retry algorithm은 공개되지 않았다. | Official sources에서 확인 불가 | L00 code와 retry를 effect model로만 설명한다. |
