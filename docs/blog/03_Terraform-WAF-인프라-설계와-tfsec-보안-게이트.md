# WAF 룰 5단계를 Terraform으로 코드화하다 — tfsec이 잡아낸 것들

> 이 글은 AWS DevSecOps 플랫폼 구축기 시리즈의 3편입니다.  
> 1편: [WAF만으로는 부족했다: AI 이상 탐지를 붙인 이유](https://velog.io/@yapp/WAF만으로는-부족한-이유)  
> 2편: [완벽한 WAF를 만들고 배포에서 무너지지 않는 법](https://velog.io/@yapp/코드가-보안이다)

---

## "WAF 설정은 콘솔에서 클릭 몇 번이면 되지 않나요?"

맞습니다. AWS 콘솔에서 WAF Web ACL을 만들고 룰을 추가하는 건 어렵지 않습니다.

문제는 그 다음입니다.

- 6개월 뒤 이 설정이 왜 이렇게 되어 있는지 기억할 수 있을까?
- 같은 환경을 다시 만들어야 할 때 콘솔 클릭을 처음부터 다시 해야 하나?
- "Priority 2 룰 조건을 바꿨는데 WAF가 갑자기 모든 요청을 차단한다" — 어떤 변경이 원인인지 어떻게 추적하나?

Terraform으로 WAF를 코드화한 이유입니다. 설정이 코드가 되는 순간, 변경 이력이 Git에 남고, 리뷰가 가능해지고, 재현이 가능해집니다.

이 글에서는 실제 코드 기준으로 WAF 룰 5단계 설계를 어떻게 Terraform으로 표현했는지, 그리고 tfsec이 어떤 문제를 잡아냈는지 정리합니다.

---

## WAF 룰 설계의 핵심 원칙 — 우선순위가 비용을 결정한다

AWS WAF는 룰을 Priority 순서대로 평가합니다. 앞에서 차단된 요청은 뒤 룰을 검사하지 않습니다.

이 구조를 이용하면 비용 최적화가 가능합니다.

AWS WAF의 과금 구조는 이렇습니다.

- Web ACL: 월 $5
- 룰 추가 시: 룰당 월 $1
- 요청 처리: 백만 건당 $0.6

요청이 많아질수록 처리 비용이 증가합니다. 특히 Managed Rule Group(AWSManagedRules*)은 내부에서 다수의 하위 룰을 실행하기 때문에 무거운 편입니다.

그래서 전략은 하나였습니다.

> 비용이 크고 복잡한 룰을 뒤에 배치하고, 빠르고 저렴한 룰로 앞에서 최대한 걸러내자.

최종 Priority 구성은 다음과 같습니다.

| Priority | 룰 | 역할 |
|:---:|:---|:---|
| 0 | GeoBlock-Non-KR | 한국 외 IP 전량 차단 |
| 1 | AI-RealTime-Block | AI가 탐지한 위협 IP 즉시 차단 |
| 2 | AWSManagedRulesSQLiRuleSet | SQL Injection 방어 |
| 3 | AWSManagedRulesCommonRuleSet | 일반 웹 취약점 방어 |
| 4 | AWSManagedRulesAmazonIpReputationList | 악성 IP 사전 차단 |

---

## Priority 0 — GeoBlock이 비용 최적화의 입구다

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
}
```

서비스 대상이 한국 사용자이기 때문에 해외 IP는 가장 앞에서 차단합니다. `not_statement`로 KR이 아닌 모든 국가를 차단하는 구조입니다.

GeoBlock에서 걸린 요청은 Priority 2, 3의 Managed Rule Group 검사를 아예 거치지 않습니다.

실제로 Athena로 WAF 로그를 분석했을 때, GeoBlock이 없었다면 CommonRuleSet과 SQLiRuleSet이 처리해야 할 해외 봇 트래픽이 상당했습니다. GeoBlock 하나로 하위 룰의 검사 부담을 구조적으로 줄인 셈입니다.

---

## Priority 1 — AI SOAR 연동 IP Set

```hcl
rule {
  name     = "AI-RealTime-Block-Rule"
  priority = 1
  action {
    block {}
  }
  statement {
    ip_set_reference_statement {
      arn = aws_wafv2_ip_set.ai_block_list.arn
    }
  }
}

resource "aws_wafv2_ip_set" "ai_block_list" {
  name               = "devsecops-ai-block-list"
  description        = "IP set managed by AI anomaly detection engine"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = []
}
```

빈 IP Set으로 시작하지만, AI 이상 탐지 Lambda가 위협 IP를 탐지하면 이 Set에 자동으로 추가합니다. 탐지부터 차단까지 사람이 개입하지 않는 SOAR 구조입니다.

Priority 1에 배치한 이유는 GeoBlock을 통과한 국내 IP 중에서 AI가 이미 위협으로 판단한 IP는 다른 룰 검사 없이 즉시 차단하기 위해서입니다. 이미 판단이 끝난 IP에 다시 SQLi 패턴 검사를 돌리는 건 낭비입니다.

---

## Priority 2, 3 — Scope-down으로 검사 범위를 좁힌다

Managed Rule Group에서 중요한 최적화가 하나 더 있습니다. `scope_down_statement`입니다.

WAF Managed Rule Group은 기본적으로 모든 요청을 검사합니다. `/health`, `/metrics` 같은 내부 상태 확인 경로도 예외 없이 검사합니다. 불필요한 비용입니다.

`scope_down_statement`는 "이 조건에 해당하는 요청만 이 룰로 검사하라"는 필터입니다. 역으로 `not_statement`와 결합하면 "이 조건에 해당하지 않는 요청만 검사하라"가 됩니다.

SQLi 룰의 경우:

```hcl
scope_down_statement {
  not_statement {
    statement {
      or_statement {
        # /admin/ 경로는 검사 제외
        statement {
          byte_match_statement {
            field_to_match { uri_path {} }
            positional_constraint = "STARTS_WITH"
            search_string         = "/admin/"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        # 신뢰 IP도 검사 제외 (var.trusted_ip_ranges가 있을 때만)
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.trusted_ips[0].arn
          }
        }
      }
    }
  }
}
```

여기서 한 가지 까다로운 부분이 있었습니다.

`or_statement`는 하위 statement가 2개 이상이어야 합니다. 그런데 `trusted_ip_ranges`가 없을 때 IP Set statement를 제거하면 `or_statement` 안에 1개만 남아 Terraform 오류가 납니다.

`dynamic` 블록으로 해결했습니다.

```hcl
dynamic "or_statement" {
  for_each = length(var.trusted_ip_ranges) > 0 ? [1] : []
  content { ... }
}

dynamic "byte_match_statement" {
  for_each = length(var.trusted_ip_ranges) == 0 ? [1] : []
  content { ... }
}
```

`trusted_ip_ranges`가 있을 때는 `or_statement`(URI + IP), 없을 때는 `byte_match_statement`(URI만) 단독으로 생성합니다. Terraform의 `dynamic` 블록으로 조건부 statement 구조를 제어한 케이스입니다.

---

## S3 보안 설계 — WAF 로그 저장소

WAF 로그는 S3에 쌓입니다. 이 버킷에는 세 가지 보안 설정을 적용했습니다.

**퍼블릭 액세스 차단**

```hcl
resource "aws_s3_bucket_public_access_block" "waf_logs_block" {
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

**HTTPS 전용 접근 강제 (ISMS 2.10)**

```hcl
resource "aws_s3_bucket_policy" "waf_logs_ssl" {
  policy = jsonencode({
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
```

`aws:SecureTransport = false`인 요청, 즉 HTTP 요청을 전부 거부합니다.

**KMS 암호화 + Bucket Key**

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs_encryption" {
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.waf_s3_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}
```

`bucket_key_enabled = true`가 중요합니다. 이 설정이 없으면 S3 객체를 읽고 쓸 때마다 KMS API를 직접 호출합니다. WAF 로그처럼 빈번하게 쌓이는 데이터에서는 KMS 호출 비용이 생각 외로 커집니다. Bucket Key를 활성화하면 버킷 레벨에서 데이터 키를 캐싱해 KMS 호출 횟수를 대폭 줄입니다.

이전에 리소스마다 개별 KMS 키를 만들었다가 하루 $30 비용 폭탄을 맞은 경험에서 나온 설정입니다. 자세한 내용은 5편 트러블슈팅에서 다룹니다.

---

## tfsec — 배포 전에 Terraform 코드를 스캔한다

2편에서 CI/CD 파이프라인의 보안 게이트로 Trivy와 Bandit을 다뤘습니다. tfsec은 Trivy IaC 스캔과 함께 Terraform 코드에 특화된 정적 분석 도구입니다.

프로젝트 초기 아키텍처(EC2 + ALB 기반)에 tfsec을 처음 돌렸을 때 나온 결과입니다.

| 심각도 | Rule ID | 내용 |
|:---:|:---|:---|
| CRITICAL | AVD-AWS-0104 | SG egress 규칙이 0.0.0.0/0 허용 |
| CRITICAL | AVD-AWS-0107 | SG ingress가 퍼블릭 인터넷 허용 |
| CRITICAL | AVD-AWS-0054 | ALB 리스너가 HTTPS를 사용하지 않음 |
| HIGH | AVD-AWS-0131 | EC2 루트 블록 디바이스 미암호화 |
| HIGH | AVD-AWS-0028 | IMDSv2 토큰 미사용 (EC2 메타데이터 노출 가능) |
| HIGH | AVD-AWS-0053 | ALB가 퍼블릭으로 노출됨 |
| HIGH | AVD-AWS-0057 | IAM 정책에 `athena:*` 와일드카드 사용 |
| MEDIUM | AVD-AWS-0178 | VPC Flow Logs 미활성화 |
| LOW | AVD-AWS-0099 | SG 기본 설명 사용 |

총 20개 항목. 처음 결과를 보고 막막했습니다.

### 어떤 걸 고쳤고, 어떤 걸 의도적으로 무시했나

무조건 다 고치는 게 답이 아닙니다. tfsec의 경고는 "이 설정은 일반적으로 위험할 수 있다"는 의미이지, "지금 이 아키텍처에서 반드시 취약점이다"는 의미가 아닙니다.

**고친 것들**

`AVD-AWS-0131` (EC2 루트 블록 미암호화) → KMS 키를 연결해 암호화 적용했습니다.

`AVD-AWS-0028` (IMDSv2 미사용) → `metadata_options`에 `http_tokens = "required"` 추가했습니다. IMDSv1은 SSRF 취약점과 결합되면 메타데이터 탈취가 가능합니다.

`AVD-AWS-0178` (VPC Flow Logs 미활성화) → CloudTrail과 함께 VPC Flow Logs를 활성화해 아웃바운드 트래픽 전량 감사 체계를 구축했습니다.

`AVD-AWS-0057` (IAM 와일드카드) → `athena:*` 대신 실제 Lambda가 필요한 액션만 열거하는 최소 권한으로 교체했습니다.

**의도적으로 무시한 것들**

`AVD-AWS-0053` (ALB 퍼블릭 노출) → 외부 사용자 트래픽을 받는 ALB는 퍼블릭이어야 합니다. 설계 의도입니다. WAF Web ACL이 앞단에서 Geo-Blocking과 AI 기반 IP 차단을 수행합니다.

`AVD-AWS-0104` (SG egress 0.0.0.0/0) → EC2가 AWS API(CloudWatch, S3), apt 패키지 관리자에 접근하려면 아웃바운드가 열려 있어야 합니다. VPC Flow Logs로 아웃바운드 전량을 감사합니다.

이 판단들은 `.tfsec-ignore` 주석으로 코드에 직접 기록했습니다.

```hcl
# tfsec:ignore:AVD-AWS-0053 - 외부 트래픽 수신용 퍼블릭 ALB. WAF Web ACL이 앞단 보호.
resource "aws_lb" "main" {
  internal = false
  ...
}
```

코드를 보는 사람이 "왜 이 경고가 무시되어 있지?"를 묻지 않아도 되게 하는 것이 목적입니다.

### 서버리스 전환이 tfsec 결과를 바꿨다

1편에서 EC2 + ALB 구조를 API Gateway + Lambda로 전환한 과정을 다뤘습니다.

그 결과 tfsec 결과도 바뀌었습니다.

`AVD-AWS-0131` (EC2 루트 블록 미암호화), `AVD-AWS-0028` (IMDSv2 미사용), `AVD-AWS-0107` (SG ingress 퍼블릭) — EC2와 ALB가 사라지면서 이 항목들이 아예 없어졌습니다.

보안 설정을 고쳐서 해결한 게 아니라, 해당 리소스가 필요 없어져서 문제 자체가 사라진 경우입니다. Attack Surface를 줄이는 것이 설정을 강화하는 것보다 근본적인 접근이라는 걸 체감한 부분입니다.

---

## Terraform 모듈화 — 재사용과 관심사 분리

WAF 관련 리소스는 `infra/modules/waf/` 모듈로 분리했습니다.

```
infra/
├── modules/
│   ├── waf/
│   │   ├── main.tf      # Web ACL, IP Set, S3, KMS
│   │   ├── variables.tf # trusted_ip_ranges, alert_email 등
│   │   └── outputs.tf   # web_acl_arn, ai_block_list_arn
│   └── vpc/
└── main.tf
```

모듈화의 실질적인 이점은 두 가지였습니다.

첫째, `outputs.tf`로 WAF ARN을 외부에 노출하면 다른 리소스(API Gateway, CloudFront)가 이 ARN을 참조할 수 있습니다. 리소스 간 의존성이 코드로 명시됩니다.

둘째, `variables.tf`의 `trusted_ip_ranges`처럼 환경마다 달라지는 값을 변수로 빼면, 같은 모듈로 개발/운영 환경을 분리해서 구성할 수 있습니다.

---

## 마치며

Terraform으로 WAF를 코드화하는 건 설정 관리의 문제이기도 하지만, 의사결정을 기록하는 문제이기도 합니다.

Priority 0에 GeoBlock을 배치한 이유, Scope-down으로 특정 경로를 검사에서 제외한 이유, tfsec 경고를 무시한 이유 — 이 판단들이 코드와 주석에 남아 있으면, 나중에 이 코드를 보는 사람(혹은 6개월 뒤의 나)이 "왜 이렇게 되어 있지?"를 묻지 않아도 됩니다.

다음 편에서는 이 인프라 위에서 실제로 동작하는 AI 이상 탐지 엔진 — Isolation Forest, Shannon Entropy, Federated Learning의 설계를 다룹니다.

---

*전체 코드:*  
[github.com/minju2022039105/aws-devsecops-platform](https://github.com/minju2022039105/aws-devsecops-platform)
