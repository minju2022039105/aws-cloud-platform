> 이 글은 **AWS WAF + AI 이상 탐지 플랫폼 구축기** 시리즈의 1편입니다.
> 전체 코드는 [GitHub](https://github.com/minju2022039105/aws-devsecops-platform)에서 확인할 수 있습니다.

---

## WAF를 쓰면 안전한 거 아닌가요?

클라우드 보안을 처음 공부할 때 이렇게 생각했습니다. AWS WAF를 붙이면 SQL Injection도 막고, XSS도 막고, 끝 아닌가?

실제로 WAF를 직접 운영해보고 생각이 바뀌었습니다.

WAF의 규칙은 **패턴 기반**입니다. `SELECT`, `UNION`, `DROP` 같은 키워드가 URI에 있으면 차단합니다. 알려진 공격은 잘 막습니다. 그런데 공격자가 Base64로 인코딩하거나, 대소문자를 섞거나, 특수문자를 URL 인코딩하면 같은 SQL Injection이어도 룰을 통과합니다.

더 문제가 되는 건 **Low-and-Slow 공격**입니다. 한 번에 대량의 요청을 보내는 대신, 정상 트래픽처럼 보이는 소량의 요청을 장시간에 걸쳐 보내는 방식입니다. Rate Limit도 안 걸리고, 패턴 매칭도 안 됩니다. 이런 공격은 요청 자체보다 **URI의 정보 구조가 얼마나 비정상적인가**를 측정해야 탐지할 수 있습니다. 3편에서 Shannon Entropy를 피처로 도입한 이유가 바로 여기 있습니다.

WAF는 "알려진 나쁜 것"을 막는 도구입니다. "알려지지 않은 이상한 것"을 잡는 건 다른 접근이 필요합니다.

---

## 그래서 AI를 붙이기로 했습니다

아이디어는 간단합니다. WAF가 모든 요청 로그를 S3에 쌓으니까, 그 로그를 AI 모델로 분석해서 **통계적으로 이상한 요청**을 탐지하면 됩니다.

패턴을 몰라도 됩니다. 정상 트래픽의 분포를 학습하면, 그 분포에서 벗어나는 것을 이상치로 분류할 수 있습니다. 이걸 **비지도 학습(Unsupervised Learning)** 기반 이상 탐지라고 합니다.

알고리즘은 **Isolation Forest**를 선택했습니다.

- Autoencoder: 구조가 복잡하고 리소스가 많이 필요
- One-Class SVM: 대규모 데이터에서 느림
- Isolation Forest: 비지도 + 준실시간 스코어링 가능, 소량 데이터에도 안정적

WAF 로그 분석이라는 특성상 라벨이 없는 데이터를 다뤄야 하고, 실시간에 가깝게 처리해야 합니다. Isolation Forest가 가장 적합했습니다.

---

## 전체 아키텍처
![](https://velog.velcdn.com/images/yapp/post/44c93adf-2328-4d1a-977e-bcf8b60728eb/image.png)

> **아키텍처 전환 중**: 현재 비용 최적화를 위해 ALB+EC2 → API Gateway+Lambda 서버리스 구조로 전환 검토 중입니다. 전환 과정의 의사결정 기록은 [devlog](https://github.com/minju2022039105/aws-devsecops-platform/blob/main/docs/devlog/260507_%EC%95%84%ED%82%A4%ED%85%8D%EC%B2%98-%EC%A0%84%ED%99%98-%EA%B2%80%ED%86%A0.md)에서 확인할 수 있습니다.

Prevention(WAF) → Detection(AI) → Response(자동 차단)으로 역할을 분리했습니다.

AI 엔진 코드는 레포의 `ai/training/`, `ai/inference/` 경로에서 확인할 수 있습니다.

---

## WAF 룰 우선순위 설계가 핵심이었습니다

WAF를 처음 설정할 때 룰 순서를 대충 정했습니다. 그랬더니 비용이 예상보다 훨씬 많이 나왔습니다.

WAF는 요청이 어떤 룰에 매칭되든 **처리한 요청 수만큼 비용**이 발생합니다. 해외 스캐너, 봇, 크롤러가 보내는 무의미한 트래픽도 모든 룰을 순서대로 검사합니다.

그래서 우선순위를 이렇게 재설계했습니다.
![](https://velog.velcdn.com/images/yapp/post/d82fafcb-8dde-4b47-9e79-858ed3e34d0f/image.png)

>| Priority | 룰 | 이유 |
|:---:|---|---|
| 0 | GeoBlock-Non-KR | 한국 외 IP를 입구에서 차단 → 이후 룰 검사 비용 0 |
| 1 | AI-RealTime-Block | AI가 식별한 위협 IP 즉각 차단 |
| 2 | AWS SQLi Managed Rule | 알려진 SQL Injection 패턴 차단 |
| 3 | AWS Common Rule Set | XSS, 경로 순회 등 일반 공격 차단 |
| 4 | IP Reputation List | 평판 불량 IP 차단 |
핵심은 **GeoBlock을 Priority 0**으로 배치한 것입니다. 이 프로젝트의 서비스 대상이 한국이기 때문에 해외 IP는 어차피 차단합니다. 그렇다면 입구에서 먼저 걸러버리면, 그 이후의 고비용 룰 검사를 아예 하지 않아도 됩니다.
결과적으로 WAF 처리 요청 수가 크게 줄었고, 비용도 함께 줄었습니다.

![업로드중..](blob:https://velog.io/90d20661-22a8-4238-a298-0eaa9b4eca9b)
 > **Athena로 실제 WAF 로그를 쿼리한 결과**, 총 1,734건의  
  차단 중 룰별 분포는 다음과 같습니다.
  >
  > | Rule | 차단 수 |
  > |---|---:|
  > | AWS-AWSManagedRulesCommonRuleSet | 1,543 |
  > | GeoBlock-Non-KR | 189 |
  > | AWS-AWSManagedRulesSQLiRuleSet | 2 |
  >
  > GeoBlock(Priority 0)은 비한국 IP를 입구에서 차단하고,   
  한국 IP에서 유입되는 공격은 CommonRuleSet(Priority 3)이   
  잡아내는 구조가 실제 로그에서도 확인됩니다. GeoBlock이    
  없었다면 이 189건이 Priority 2~4 룰 검사를 모두 통과하며  
  추가 비용을 발생시켰을 겁니다.

---

## Terraform으로 전체를 코드화했습니다

"인프라를 코드로 관리한다"는 말이 처음엔 추상적으로 느껴졌습니다. 직접 해보니 의미가 달랐습니다.

AWS 콘솔에서 WAF 룰을 하나씩 클릭해서 만들면, 나중에 "이 룰 왜 만들었지?"를 추적할 수 없습니다. Terraform으로 관리하면 git 히스토리가 곧 인프라 변경 이력이 됩니다.
![](https://velog.velcdn.com/images/yapp/post/63aa82c0-2fa7-48f0-a355-49fc7038e8a4/image.png)

코드만 봐도 "한국 외 모든 IP를 차단"이라는 의도가 바로 읽힙니다.

---

## 이 시리즈에서 다룰 것들

**1편**: WAF의 한계와 AI 보완의 필요성, 전체 아키텍처 개요
**2편**: Terraform으로 WAF 인프라 설계하기 — IaC 전체 코드화, tfsec 보안 게이트
**3편**: Isolation Forest로 이상 징후 탐지하기 — Shannon Entropy 피처, 데이터 품질 진단
**4편**: Weighted Federated Averaging으로 Privacy-Preserving 탐지 구현
**5편**: 트러블슈팅 — KMS $30/일, IAM 최소 권한 재설계, sklearn 1.8.0 이슈

다음 편에서는 WAF 인프라를 Terraform으로 어떻게 설계했는지, 그 과정에서 tfsec으로 보안 취약점을 어떻게 선제적으로 잡았는지 다룹니다.

---

*전체 코드: [github.com/minju2022039105/aws-devsecops-platform](https://github.com/minju2022039105/aws-devsecops-platform)*
