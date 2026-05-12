

> 이 글은 **AWS DevSecOps 플랫폼 구축기** 시리즈의 1편입니다.  
> Terraform IaC → WAF 룰 설계 → Isolation Forest 이상 탐지 → Federated Learning까지,  
> 실제 운영 비용·보안 지표를 기준으로 의사결정한 과정을 기록합니다.  
> 전체 코드는 [GitHub](https://github.com/minju2022039105/aws-devsecops-platform)에서 확인할 수 있습니다.

---

# WAF만으로는 부족했다: AI 이상 탐지를 붙인 이유

## “WAF 붙였으니까 안전하겠지”

AWS 보안을 처음 공부할 때는 그렇게 생각했습니다.

WAF만 붙이면 SQL Injection이나 XSS 같은 공격은 대부분 막을 수 있고, 어느 정도 안전한 서비스가 되는 줄 알았습니다.

실제로 운영해보니 생각이 달라졌습니다.

AWS WAF는 기본적으로 **패턴 기반 탐지**입니다.  
예를 들어 `SELECT`, `UNION`, `DROP` 같은 특정 문자열이 요청에 포함되면 차단합니다. 알려진 공격에는 매우 강력합니다.

하지만 공격자가:

- Base64 인코딩을 사용하거나
- 대소문자를 섞거나
- 특수문자를 URL 인코딩하거나
- 요청을 정상 트래픽처럼 분산시키면

같은 SQL Injection이라도 룰을 우회할 수 있습니다.

특히 문제였던 건 **Low-and-Slow 공격**이었습니다.

한 번에 대량 요청을 보내는 대신, 정상 사용자처럼 보이는 소량 요청을 장시간에 걸쳐 보내는 방식입니다.

이 경우:

- Rate Limit에도 잘 걸리지 않고
- 패턴 기반 룰에도 잘 탐지되지 않습니다.

결국 WAF는:

> “알려진 공격”을 막는 데는 강하지만  
> “알려지지 않은 이상 행동”을 탐지하는 데는 한계가 있었습니다.

---

## 그래서 AI 기반 이상 탐지를 붙이기로 했습니다

아이디어는 단순했습니다.

WAF가 모든 요청 로그를 S3에 저장하니,  
그 로그를 AI 모델이 분석해 **통계적으로 이상한 요청**을 탐지하도록 만드는 구조입니다.

핵심은:

> 공격 패턴을 외우는 것이 아니라,  
> “정상 트래픽 분포에서 벗어난 요청”을 찾는 것이었습니다.

패턴을 몰라도 됩니다.

정상 트래픽의 분포를 학습한 뒤,  
그 분포에서 벗어난 요청을 이상치로 분류하면 됩니다.

이 프로젝트에서는 Isolation Forest 기반 이상 탐지를 사용했습니다.  
알고리즘 선택과 Feature Engineering 과정은 4편에서 자세히 다룹니다.

---

## 전체 아키텍처 — Prevention / Detection / Response 분리
![](https://velog.velcdn.com/images/yapp/post/e7d38a43-9cd1-4ece-9ad6-7df32eb7c603/image.png)

전체 구조는 크게 3개 레이어로 나눴습니다.

### 1. Prevention — WAF

AWS WAF가 알려진 공격을 1차 차단합니다.

### 2. Detection — AI 이상 탐지

WAF 로그를 S3에 저장하고, Athena로 분석한 뒤  
Isolation Forest 모델이 이상 요청을 스코어링합니다.

### 3. Response — 자동 대응

위협 IP는 Lambda를 통해 WAF IP Set에 자동 등록됩니다.

탐지부터 차단까지 약 5~10분 정도의 준실시간 구조입니다.

---

## WAF 룰 우선순위 설계가 비용에도 영향을 줬습니다

운영하면서 의외였던 부분은:

> 초기 차단이 없으면 해외 봇 트래픽도 WAF 로그로 쌓이고, Athena 쿼리·Lambda 처리량까지 증가한다는 점이었습니다.

그래서 핵심 전략은:

> GeoBlock을 Priority 0으로 배치하는 것이었습니다.

서비스 대상이 한국 사용자였기 때문에,  
해외 IP는 가장 먼저 차단하도록 설계했습니다.

Athena로 실제 WAF 로그를 분석해 검증했습니다.

| Rule | 차단 수 |
|---|---:|
| AWS-AWSManagedRulesCommonRuleSet | 1,543 |
| GeoBlock-Non-KR | 189 |
| AWS-AWSManagedRulesSQLiRuleSet | 2 |

여기서 한 가지 의문이 생길 수 있습니다.

> "GeoBlock이 Priority 0인데 왜 189건밖에 못 막았나요?"

두 룰은 역할 자체가 다릅니다.

GeoBlock은 **해외 IP를 차단**합니다. 실제 공격 테스트(Nikto 스캐너)는 한국 IP인 로컬 머신에서 실행했기 때문에 GeoBlock을 통과했고, CommonRuleSet에서 탐지됐습니다. GeoBlock이 잡은 189건은 외부 봇·크롤러처럼 해외에서 들어온 무관한 트래픽입니다.

즉 두 룰은 경쟁 관계가 아닙니다. GeoBlock은 **해외 노이즈를 입구에서 걸러** 이후 룰의 검사 부담을 줄이고, CommonRuleSet은 **국내 트래픽 중 실제 공격 패턴을 탐지**합니다.

GeoBlock을 Terraform으로 구현하면 다음과 같습니다.

```hcl
rule {
  name     = "GeoBlock-Non-KR"
  priority = 0
  action {
    block {}
  }
  statement {
    not_statement {
      statement {
        geo_match_statement {
          country_codes = ["KR"]
        }
      }
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "geoBlockNonKR"
    sampled_requests_enabled   = true
  }
}
```

`not_statement`로 KR이 아닌 모든 국가를 차단합니다. GeoBlock에서 먼저 차단된 요청은 이후 고비용 룰 검사를 아예 거치지 않습니다.

단순 보안 정책이 아니라,  
비용 최적화까지 연결된 설계였습니다.

---

## 왜 EC2에서 서버리스 구조로 바꿨나

처음 구조는 아래 형태였습니다.

> CloudFront → WAF → ALB → EC2

![](https://velog.velcdn.com/images/yapp/post/d9110d65-4d56-478d-981a-e592df50edc3/image.png)
하지만 실제 운영에서는 문제가 있었습니다.

보안 로그 분석은 실시간 API 서비스와 다르게:

- 요청이 간헐적으로 발생하고
- 배치 기반으로 처리되며
- 특정 시간대에만 분석이 수행됩니다.

그런데도:

- EC2는 계속 켜져 있어야 하고
- ALB도 계속 과금되며
- OS 패치와 AMI 관리 부담까지 존재했습니다.

그래서 최종적으로:

> API Gateway + Lambda 기반 서버리스 구조로 전환했습니다.

---

## Before / After 아키텍처

**Before — CloudFront → WAF → ALB → EC2**
![](https://velog.velcdn.com/images/yapp/post/d9110d65-4d56-478d-981a-e592df50edc3/image.png)

**After — CloudFront → WAF → API Gateway → Lambda**

![](https://velog.velcdn.com/images/yapp/post/e7d38a43-9cd1-4ece-9ad6-7df32eb7c603/image.png)



---

## 서버리스 전환 결과

| 항목 | ALB + EC2 | API Gateway + Lambda |
|:---|:---:|:---:|
| 월 고정 비용 | 약 $25 | 약 $0.1 이하 |
| 운영 부담 | OS 패치 필요 | 없음 |
| Attack Surface | EC2 OS 노출 | Managed 서비스 |
| 확장성 | 수동 스케일링 | 자동 확장 |
| 로그 처리 | 동기 기반 | 이벤트 기반 |

결과적으로:

> 월 비용은 약 99% 이상 감소했습니다.

그리고 보안은 오히려 강화됐습니다.

---

## 비용 거버넌스도 설계의 일부였습니다

초기 설계에서 리소스마다 KMS 키를 개별 생성했다가 하루 비용이 $30까지 급증하는 일이 있었습니다. CloudTrail 로그로 원인을 추적해 공유 KMS 키 구조로 재설계해 해결했습니다.

자세한 과정은 5편 트러블슈팅에서 다룹니다.

---

## 비용은 줄었지만 보안은 더 강화됐습니다

서버리스를 선택한 이유는 단순 비용 때문만은 아닙니다.

| 보안 항목 | Before | After |
|:---|:---|:---|
| OS 취약점 | EC2 직접 관리 | Managed 서비스 |
| 침해 범위 | 서버 전체 노출 가능 | 함수 단위 격리 |
| IAM 권한 | Role 공유 가능성 | 최소 권한 분리 |
| DDoS 보호 | ALB 기본 보호 | API Gateway + WAF |
| IaC 보안 게이트 | tfsec 적용 | tfsec 동일 적용 |

특히 Lambda 기반 구조에서는:

- 함수별 최소 권한 IAM Role 적용
- 서버 OS 제거
- Attack Surface 축소

가 가능했습니다.

즉:

> 비용은 줄었고, 운영 부담도 줄었으며, 보안성은 오히려 향상됐습니다.

---

# 이 시리즈에서 다룰 내용

- **1편**: WAF의 한계와 AI 이상 탐지 도입 배경 ← 현재 글
- **2편**: 보안은 배포 전에 시작된다 — DevSecOps CI/CD 설계기
- **3편**: WAF 룰 5단계를 Terraform으로 코드화하다 — tfsec이 잡아낸 것들
- **4편**: AI 이상 탐지 엔진 — Isolation Forest, Shannon Entropy, Federated Learning
- **5편**: 트러블슈팅 — KMS 비용 폭증 사고

다음 편에서는 Terraform으로 WAF 인프라를 어떻게 코드화했고,  
tfsec으로 어떤 취약점을 사전에 차단했는지 실제 코드 기준으로 정리해보겠습니다.

---

*전체 코드:*  
[github.com/minju2022039105/aws-devsecops-platform](https://github.com/minju2022039105/aws-devsecops-platform)
