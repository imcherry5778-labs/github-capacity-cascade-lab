# August 17, 2026 Incident Timeline

## Scope and source boundary

- 이 문서는 [RCA-01][rca-01]과 [RCA-02][rca-02]만으로 2026-08-17 incident를
  정리한다. Source classification과 freshness 기록은 [Source Register](source-register.md)에
  있다.
- 이 timeline은 공개된 condition, user impact, mitigation과 recovery sequence이며 GitHub의
  정확한 private topology diagram이 아니다.
- 모든 시각은 UTC다. `~`는 primary source가 approximate로 표현한 시각이고, 공개되지 않은
  시각은 `UNKNOWN`으로 남긴다.
- Service별 impact 시작과 내부 조치의 exact execution time이 공개되지 않은 경우 incident
  시작 시각이나 status update 시각으로 대신 추정하지 않는다.

## Timeline

| UTC time | Publicly reported condition/event | External/user impact | Publicly reported mitigation or recovery action | Source | Classification |
| --- | --- | --- | --- | --- | --- |
| 13:28 | RCA가 정한 incident 시작 시각. 새로운 traffic peak에서 Central US load balancer network가 saturation에 도달했다. | GitHub.com의 여러 경험에서 error와 latency가 시작됐다. 개별 service의 exact 시작 시각은 공개되지 않았다. | 아직 공개된 조치 없음 | [RCA-01][rca-01] | `FACT`; per-service start `UNKNOWN` |
| 13:40 | Status page가 impacted performance 조사를 공지했다. | Git Operations, Webhooks, API Requests, Issues, Pull Requests, Actions, Pages와 Copilot이 incident component로 표시됐다. | Investigation 시작을 공개했다. | [RCA-01][rca-01] | `FACT` |
| 13:45 | 여러 experience에서 약 20% error rate를 보고했다. | Pull Requests, Issues와 그 밖의 experience에서 실패가 관찰됐다. | Investigation 진행 중 | [RCA-01][rca-01] | `FACT` |
| 14:04 | Web/API error rate 약 20%, archive와 raw repository content download error rate 약 50%를 보고했다. | Web/API 요청과 archive/raw-content download가 서로 다른 수준으로 저하됐다. | Root cause 조사와 mitigation 진행 중 | [RCA-01][rca-01] | `FACT` |
| 14:24 | SAML/OIDC authentication, SCIM과 Team Sync 영향이 추가로 보고됐다. | Login/federation 및 identity synchronization 관련 기능이 영향을 받았다. | Investigation 계속 | [RCA-01][rca-01] | `FACT` |
| Exact time not published | Istio sidecar pod가 concurrency limit에 도달했고 host service는 보지만 sidecar limit은 반영하지 못한 scaling policy가 제대로 scale하지 못했다고 RCA가 설명한다. Failure가 연쇄 확산되어 네 HAProxy node가 flow limit을 소진했고 gateway auth path가 저하됐다. | Authentication latency와 failure가 여러 서비스로 확산됐다. | 일부 failing traffic을 Central US에서 Northern Virginia로 옮겼고, 해당 HAProxy node를 동시에 pause한 뒤 broad recovery가 나타났다고 보고했다. | [RCA-01][rca-01] | Event/cause `FACT`; exact time `UNKNOWN` |
| 16:36 | Problematic component에 corrective action을 적용한 뒤 strong recovery signal을 보고했다. Resolved summary는 이 시각까지 most services가 recovered됐다고 정리한다. | 대부분의 service가 회복했지만 error rate가 조금 남았고 Actions/Copilot의 최종 회복은 뒤에 이어졌다. | Recovery를 계속 관찰하고 잔여 영향을 복구했다. | [RCA-01][rca-01] | `FACT` |
| ~18:03 | Actions degradation이 이 시각까지 지속됐다고 resolved summary가 정리한다. | Actions 사용자는 broad recovery보다 긴 영향을 받았다. | Actions recovery 완료; exact internal action/time은 공개되지 않았다. | [RCA-01][rca-01] | `FACT`; time approximate |
| 18:11 | Problematic component 조치 후에도 sporadic authentication failure가 남았다고 보고했다. | 일부 authentication request가 계속 실패했다. | 추가 mitigation과 investigation을 계속했다. | [RCA-01][rca-01] | `FACT` |
| 18:23 | Git Operations degradation이 mitigated됐다고 보고했다. | Git Operations의 재발성 degradation이 회복됐다. | Stability monitoring을 시작했다. | [RCA-01][rca-01] | `FACT` |
| 19:01 | API Requests가 정상 동작한다고 보고했다. | API degradation이 회복됐다. | 정상 상태 monitoring | [RCA-01][rca-01] | `FACT` |
| 19:13 | Authentication token retry를 부분적으로 disable한 뒤 개선을 관찰했다. | Sporadic authentication failure가 줄었지만 Copilot recovery는 완료되지 않았다. | Mitigation을 전체 적용하기 전 impact를 monitoring했다. | [RCA-01][rca-01] | `FACT` |
| Exact time not published | Northern Virginia의 retry storm과 residual Copilot authentication failure를 복구하는 동안 gateway retry를 PR로 일시 축소하고, load balancer에서 inbound Copilot Token Service token request를 403으로 차단한 뒤 site별 traffic을 점진적으로 올렸다. | 실패한 token operation의 client retry loop가 traffic을 약 10배 늘렸고, Token Service traffic은 정상 약 7–9K RPS에서 약 70–100K RPS로 증가했다. | 공개된 실행 순서는 gateway retry 축소 → token request 차단 → site별 gradual ramp-up이다. | [RCA-01][rca-01] | Sequence/values `FACT`; exact times `UNKNOWN` |
| Exact time not published | Codeload endpoint를 향한 여러 scraping attack이 recovery를 방해하는 complicating factor였다고 RCA가 설명한다. | Recovery 여유를 줄인 외부 부하였지만 개별 impact 수치와 시각은 공개되지 않았다. | 구체적인 codeload mitigation은 공개되지 않았다. | [RCA-01][rca-01] | Factor `FACT`; details `UNKNOWN` |
| 20:22 | Issues가 정상 동작한다고 보고했다. | Issues의 residual/recurrent degradation이 회복됐다. | 정상 상태 monitoring | [RCA-01][rca-01] | `FACT` |
| 21:02 | Copilot Token Service가 fully recovered된 시각으로 resolved summary에 기록됐다. | Broad service recovery보다 Copilot authentication 영향이 더 오래 지속됐다. | Retry-triggering response를 차단하고 gateway authentication retry를 줄여 Token Service를 안정화했다. | [RCA-01][rca-01] | `FACT` |
| 21:15 | RCA가 정한 incident 종료 및 Status resolved 시각. 총 duration은 7시간 47분이다. | August 17 Core incident가 종료됐다. | 후속 action으로 sidecar-aware autoscaling, Istio limit audit, gateway/client retry와 backoff review, VS Code retry 수정, load-balancer monitoring과 regional failover 개선을 등록했다. | [RCA-01][rca-01] | `FACT` |
| After the incident, published 2026-08-20 | GitHub는 August 6과 August 17 모두 직전 code/configuration change가 아니라 core capacity failure였다고 설명했다. | Incident trigger를 deployment regression으로 해석하지 않아야 한다. | 두 incident 이후 service-to-service retry limit/budget과 variable timeout을 일관되게 적용하고 lower-priority CPU/memory alert를 review한다고 밝혔다. | [RCA-02][rca-02] | `FACT`; joint August 6/17 response는 incident-specific detail이 아님 |

GHEC with Data Residency의 일부 Actions workflow는 public GitHub.com에 있는 workflow step
definition에 의존해 영향을 받았다. `RCA-01`은 이 impact를 직접 확인하지만 exact start,
recovery time과 affected workflow 비율은 공개하지 않았으므로 별도 timestamp를 만들지
않는다.

## Failure-chain summary

공개 RCA가 설명한 chain은 new traffic peak와 sidecar/scaling capacity mismatch에서 시작해
Central US load balancer saturation, 네 HAProxy node의 flow exhaustion과 gateway auth path
degradation으로 확산됐고, optimistic gateway/client retry가 추가 load를 만들었다. Broad
recovery 뒤에도 VS Code retry loop가 Copilot Token Service traffic을 증폭시켜 최종 recovery를
늦췄다. 이는 source가 공개한 failure effect의 순서이지 exact network topology나 모든 내부
의사결정을 재구성한 것이 아니다.

## What remains unknown

- 정확한 network topology와 Central US/Northern Virginia의 infrastructure topology
- 정확한 HPA 또는 다른 autoscaling metric, policy object와 configuration
- 정확한 Istio resource, sidecar concurrency 값과 scaling limit
- 정확한 HAProxy flow implementation, node 배치, version, limit과 timeout
- `gateway auth path`가 Istio IngressGateway였는지 여부
- Gateway와 VS Code의 정확한 retry algorithm, budget, backoff와 loop condition
- 각 mitigation의 exact execution timestamp와 traffic percentage
- Central US infrastructure의 구체 Azure service/resource mapping
- Codeload scraping의 source, volume, filtering 또는 mitigation detail

[rca-01]: https://www.githubstatus.com/incidents/zkxwbgr0cnmx
[rca-02]: https://github.blog/news-insights/company-news/the-august-17-outage-and-the-work-ahead/
