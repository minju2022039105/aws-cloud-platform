# [FinOps] 614만 건의 KMS API 호출 분석을 통한 아키텍처 재설계 및 인프라 비용 92% 절감

> 이 글은 **AWS Cloud Infrastructure Platform 구축기** 시리즈의 3편입니다.
> KMS API 호출 614만 건이 만든 비용 폭증의 원인을 Cost Explorer · CloudTrail로 역추적하고, 공유 키 아키텍처로 재설계해 비용을 92% 절감한 FinOps 사례를 다룹니다.
>
> 이전 글: [2편 — Kubernetes 환경에서의 컨테이너 애플리케이션 배포 자동화 및 Helm 기반 패키지 관리](https://velog.io/@yapp/07.-1.-%EC%84%9C%EB%B2%84%EB%A6%AC%EC%8A%A4-%ED%8F%AC%ED%8A%B8%ED%8F%B4%EB%A6%AC%EC%98%A4%EC%97%90-Kubernetes-%EB%8D%94%ED%95%98%EA%B8%B0-kind%EB%B6%80%ED%84%B0-EKS%EA%B9%8C%EC%A7%80)
> 다음 글: [4편 — AWS WAF v2 인프라 코드화(IaC) 및 tfsec 정적 분석 기반의 컴플라이언스 자동화](https://velog.io/@yapp/03WAF-%EB%A3%B0-5%EB%8B%A8%EA%B3%84%EB%A5%BC-Terraform%EC%9C%BC%EB%A1%9C-%EC%BD%94%EB%93%9C%ED%99%94%ED%95%98%EB%8B%A4)

---

## 예상치 못한 청구서

AWS Billing 대시보드를 열었을 때 **USD 30.60**이 찍혀 있었습니다.

프리 티어 계정에서 실습 중이었고, 평소 월 $2~3 수준이었습니다. 항목을 열어보니 KMS(Key Management Service) 하나가 전체 비용의 60%를 차지하고 있었습니다.

| 서비스 | 요청 수 | 비용 |
|--------|---------|------|
| KMS (us-east-1) | **6,141,359건** | $18.42 |
| S3 (us-east-1) | 6,163,769건 | $2.62 |
| 기타 (ALB, VPC, EC2 등) | — | $9.56 |

KMS 요청이 614만 건. S3 요청과 숫자가 거의 동일했습니다.
![](https://velog.velcdn.com/images/yapp/post/09b99bec-e062-4c5a-a7d9-0af98939f25b/image.png)

<!-- 📸 스크린샷 #1 — 청구서 충격 장면 (필수)
  위치: AWS Billing Console → Bills → 해당 월 클릭 → 서비스별 상세 펼치기
  내용: KMS $18.42 항목이 보이는 청구서 화면 전체. 가능하면 KMS 행을 강조(노란 형광펜 등)
  방법: 브라우저 전체화면(F11) 후 캡처. Cost Explorer → 서비스별 분류 화면도 대체 가능
  효과: 글 도입부에서 "얼마나 심각했는지"를 숫자가 아닌 시각으로 전달하는 핵심 이미지
-->

---

## 원인 분석: 두 숫자가 일치한 이유

S3 요청 수와 KMS 요청 수가 1:1로 일치하는 건 우연이 아닙니다.

S3 버킷에 **SSE-KMS(Server-Side Encryption with KMS)** 를 적용하면, S3가 내부적으로 KMS 요청을 발생시킵니다. 단순화하면 오브젝트를 쓸 때 `kms:GenerateDataKey`가, 읽을 때 `kms:Decrypt`가 호출되는 방식입니다. 대량의 PUT/GET이 반복되면 S3 요청 수와 KMS 요청 수가 함께 증가합니다.

```
S3 PUT 반복  →  kms:GenerateDataKey 반복 호출
S3 GET 반복  →  kms:Decrypt 반복 호출
```

KMS는 월 20,000건까지 무료이고, 이후 **10,000건당 $0.03**이 과금됩니다. SSE-S3도 저장 데이터 암호화를 추가 비용 없이 제공하지만, KMS 키 단위의 세밀한 권한 제어와 감사가 필요한 경우에는 SSE-KMS를 선택해야 합니다. 문제는 실습용 고빈도 로그 버킷에 SSE-KMS를 적용하면서 요청 비용이 폭증했다는 점이었습니다. 암호화 방식 선택 하나가 $18의 차이를 만들었습니다.
![](https://velog.velcdn.com/images/yapp/post/577f3381-d289-41f9-a83b-adcecb2d078a/image.png)

<!-- 📸 스크린샷 #2 — KMS vs S3 요청 수 비교 그래프 (권장)
  위치: AWS Cost Explorer → 사용량 유형(Usage Type) 기준 → KMS 요청 수 / S3 요청 수 같은 기간 선택
  내용: KMS API 호출 수(6,141,359)와 S3 요청 수(6,163,769)가 함께 보이는 차트 또는 표
  방법: Cost Explorer에서 Group by = Usage Type, 해당 월 선택 후 캡처
  효과: "두 숫자가 왜 같은가"를 말로만 설명하는 것보다 그래프로 보여주면 설득력 상승
  대안: 없으면 생략 가능. 이미 표로 설명하고 있어서 없어도 흐름은 충분
-->

---

## 근본 원인: monitor.py의 무한루프

원인은 AI 데모 시연용으로 작성한 `monitor.py`였습니다.

```python
TICK_SEC = 1

while True:                        # 종료 조건 없음
    sample = df.sample(1)
    # ... Isolation Forest 분석 ...
    upload_to_s3(log_entry)        # 매 루프마다 S3 PUT
    time.sleep(TICK_SEC)
```

스크립트는 1초마다 분석 결과를 S3에 업로드했습니다. SSE-KMS가 적용된 버킷이었기 때문에 업로드 1회마다 KMS 호출이 1회 발생했습니다.

EC2 인스턴스(`ip-10-0-1-155`)에서 실행 후 SSH 세션을 닫았는데, 백그라운드에서 스크립트가 계속 돌고 있었습니다. `while True`에 종료 조건이 없었고, 당시 정확한 실행 방식은 기록이 부족하지만 결과적으로 SSH 세션 종료 후에도 EC2 내부에서 프로세스가 계속 살아있었습니다.

1차 원인은 monitor.py의 무한 업로드였고, 2차적으로 Analyzer Lambda가 Athena를 통해 해당 파일들을 반복 조회하면서 `kms:Decrypt` 요청이 추가로 누적됐습니다.

```
[1차] monitor.py 업로드 (PUT) → KMS GenerateDataKey 반복
[2차] Analyzer Lambda 스캔 (GET) → KMS Decrypt 추가 누적
```

이 두 흐름이 한 달간 누적되어 614만 건이 됐습니다.

---

## 긴급 대응

### 1. KMS 키 삭제 예약

```bash
# 활성 키 목록 조회
aws kms list-keys --region us-east-1

# 키 삭제 예약 (최소 대기 기간 7일)
aws kms schedule-key-deletion \
  --key-id <key-id> \
  --pending-window-in-days 7 \
  --region us-east-1
```

일부 키는 권한이 꼬여 일반 IAM 사용자로 삭제 예약이 불가능했습니다. 불가피하게 Root 계정으로 키 정책(Key Policy)을 수정해 관리 권한을 복구한 뒤 삭제 예약했습니다. 이 과정에서 Root 사용은 긴급 복구 상황으로만 제한해야 한다는 점을 다시 정리했습니다.![](https://velog.velcdn.com/images/yapp/post/b1b50cd0-c488-4992-adf7-1962d3b028cf/image.png)

<!-- 📸 스크린샷 #3 — KMS 키 Pending Deletion 상태 (권장)
  위치: AWS KMS Console → Customer managed keys
  내용: 키들이 "Pending deletion" 상태로 표시된 목록 화면
  방법: 콘솔 접속 후 키 목록 전체 캡처. 상태 컬럼에 "Pending deletion"이 보여야 함
  효과: "삭제 예약했다"는 텍스트 설명을 실제 콘솔 화면으로 증명
  참고: 이미 삭제 완료됐다면 생략. 억지로 재현하지 않아도 됨
-->

### 2. 비용 유발 리소스 정리

- **ALB 삭제**: 시간당 $0.0225 과금 중이던 Application Load Balancer 삭제
- **퍼블릭 IPv4 정리**: 323시간치 과금($1.61) 확인 후 관련 리소스 점검

### 3. AWS Support 환불 요청

Billing Support Case를 접수했습니다. 학습 목적의 실수임을 명시하고, 비정상 API 호출 614만 건에 대한 일회성 환불(Waiver)을 요청했습니다.
![](https://velog.velcdn.com/images/yapp/post/378adc5c-313a-4cab-8c1c-f22aef2e9beb/image.png)![](https://velog.velcdn.com/images/yapp/post/8dc869d2-6e65-466a-bc50-1f44aa435c24/image.png)

<!-- 📸 스크린샷 #4 — AWS Support Case 접수 화면 (선택)
  위치: AWS Support Center → Cases → 해당 케이스 클릭
  내용: Billing Support Case 접수 내용 또는 AWS의 응답(환불 승인 여부) 화면
  방법: 케이스 상세 페이지 캡처. 개인정보(이름, 이메일)는 모자이크 처리
  효과: "환불 요청했다"는 주장을 실제 케이스 화면으로 뒷받침. 포트폴리오 신뢰도 향상
  참고: 환불 승인 응답 이메일 캡처가 있다면 더 임팩트 있음
-->

---

## 재발 방지

### 암호화 방식 변경

비용이 중요한 버킷에는 SSE-S3로 변경하고, 규정 준수나 키 관리가 필요한 경우에만 SSE-KMS를 선택하도록 기준을 세웠습니다.

Terraform에서 SSE-KMS를 사용할 경우 `bucket_key_enabled = true`를 반드시 설정합니다. 버킷 키를 활성화하면 오브젝트마다 KMS를 호출하는 대신 버킷 단위로 키를 공유해 **API 호출 횟수를 최대 99% 절감**할 수 있습니다.

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true  # KMS 호출 횟수 대폭 감소
  }
}
```

### AWS Budgets 알림 설정
월 $5 초과 시 이메일 알림을 받도록 Budgets를 설정했습니다. 청구서를 직접 확인하기 전에 임계치에서 먼저 알 수 있게 됩니다.![](https://velog.velcdn.com/images/yapp/post/9ca0f54e-7e5c-4973-8af6-840f49d71ff9/image.png)![](https://velog.velcdn.com/images/yapp/post/da9165ec-73b1-4fcc-9e13-c8a7a56ae70c/image.png)

<!-- 📸 스크린샷 #5 — AWS Budgets 알림 설정 화면 (권장)
  위치: AWS Billing Console → Budgets → 생성한 예산 클릭
  내용: 월 $10 임계치 설정(현재 코드 기준 80% = $8 알림)과 이메일 수신자 설정이 보이는 화면
  방법: Budgets 상세 페이지 캡처. 이메일 주소는 모자이크
  효과: "설정했다"는 말 대신 실제 설정 화면을 보여줘 재발 방지 실천을 증명
-->

### 장기 실행 스크립트 관리 원칙

- EC2에서 스크립트를 실행할 때는 `nohup` 또는 systemd로 명시적으로 관리
- 무한루프가 필요한 경우 반드시 최대 실행 횟수 또는 종료 시각을 조건으로 추가
- 실습 후 EC2 프로세스 목록(`ps aux`) 확인을 습관화

---

## 사고 이후: 전면 개선

재발 방지 계획을 실행하면서 추가 문제를 마주쳤고, 그 과정에서 인프라 전반을 개선했습니다.

### 1. KMS 아키텍처 개편과 실제 비용 결과

기존에는 S3, CloudTrail, CloudWatch 등 리소스마다 개별 KMS 키가 생성되어 관리가 파편화되어 있었습니다. `bucket_key_enabled = true` 설정에 더해, 루트 모듈에 `shared_log_key`를 하나 만들고 모든 모듈이 공유하도록 아키텍처를 개편했습니다.

```hcl
# main.tf — 공유 KMS 키를 루트에서 단일 정의
resource "aws_kms_key" "shared_log_key" {
  description             = "Centralized Shared KMS Key for Security Logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  ...
}

module "security" {
  source             = "./modules/waf"
  shared_kms_key_arn = aws_kms_key.shared_log_key.arn
  ...
}
```

사고 이후 한 달(2026년 5월) 청구서에서 결과를 확인했습니다.

| 항목 | 사고 당시 | 개선 이후 |
|------|---------|---------|
| KMS API 호출 | 6,141,359건 | 대폭 감소 |
| KMS 비용 | **$18.42** | **$1.41** |

$1.41 중 $1.00은 KMS 키 월정액(키 1개 × $1/월)이고, 나머지 $0.41이 실제 API 호출 비용입니다. `bucket_key_enabled`로 오브젝트마다 KMS를 직접 호출하는 대신 버킷 단위로 데이터 키를 캐싱한 결과입니다.![](https://velog.velcdn.com/images/yapp/post/e5cfea73-28a9-4fa7-a6a5-b5f4dea0fe1c/image.png)

<!-- 📸 스크린샷 #6 — 개선 후 KMS 비용 $1.41 확인 화면 (필수)
  위치: AWS Cost Explorer → 서비스별 분류 → Key Management Service 선택 → 5월 기간
  내용: KMS 비용이 $1.41로 표시된 Cost Explorer 화면
  방법: 서비스 필터에 KMS만 선택하거나, 서비스별 합계 표에서 KMS 행이 보이게 캡처
  효과: "$18 → $1.41" 수치가 실제 화면으로 증명됨. 글에서 가장 임팩트 있는 before/after 장면
  참고: 제공해주신 청구서 화면(User 메시지의 텍스트 데이터) 기반으로 캡처하면 됨
-->

### 2. Terraform 재배포 중 Backend 상태 불일치

KMS 키를 개편한 뒤 `terraform apply`를 실행하려니 DynamoDB 잠금 테이블의 체크섬(`terraform.tfstate-md5`)이 S3의 실제 tfstate와 맞지 않아 작업이 중단됐습니다. 키를 수동으로 삭제하는 과정에서 Terraform이 관리하는 상태와 실제 AWS 상태가 어긋난 것이 원인이었습니다.

```bash
# DynamoDB lock table에서 체크섬 항목 삭제
aws dynamodb delete-item \
  --table-name terraform-lock-table \
  --key '{"LockID": {"S": "minju-devsecops-tfstate-virginia/terraform.tfstate-md5"}}'

# 백엔드 재초기화
terraform init -reconfigure
```

수동으로 AWS 리소스를 조작한 뒤에는 반드시 Terraform 상태 동기화를 확인해야 한다는 것을 다시 확인했습니다.

### 3. IAM 최소 권한 분리

기존에 EC2와 Lambda가 하나의 통합 Role을 공유하고 있었습니다. 역할을 분리하고 각각에 필요한 권한만 부여했습니다.

| Role | 용도 | 주요 권한 |
|------|------|---------|
| `ec2_ai_role` | AI 분석 엔진 | S3 읽기, KMS 복호화, Athena 쿼리 |
| `lambda_blocker_role` | WAF 자동 차단 | WAF IPSet 업데이트만 |

```hcl
resource "aws_iam_role" "ec2_ai_role" {
  name = "devsecops-ec2-ai-role"
  assume_role_policy = jsonencode({
    Statement = [{ Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole", Effect = "Allow" }]
  })
}

resource "aws_iam_role" "lambda_blocker_role" {
  name = "devsecops-lambda-blocker-role"
  assume_role_policy = jsonencode({
    Statement = [{ Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole", Effect = "Allow" }]
  })
}
```

통합 Role을 쓰면 EC2가 침해당했을 때 Lambda의 WAF 수정 권한까지 노출됩니다. 역할을 분리하면 피해 반경을 좁힐 수 있습니다.

### 4. SNS 실시간 보안 알림

WAF 설정 변경이나 WebACL 삭제 이벤트가 발생하면 이메일로 즉시 알림을 받도록 파이프라인을 구성했습니다.

```hcl
resource "aws_cloudwatch_event_rule" "waf_block_event" {
  name = "waf-block-detection"
  event_pattern = jsonencode({
    "source"      : ["aws.wafv2"],
    "detail-type" : ["WAF Configuration Change", "AWS API Call via CloudTrail"],
    "detail"      : { "eventName" : ["UpdateWebACL", "DeleteWebACL"] }
  })
}

resource "aws_sns_topic" "security_alerts" {
  name              = "devsecops-security-alerts"
  kms_master_key_id = aws_kms_key.shared_log_key.id  # 알림 내용도 암호화
}
```

SNS 토픽 자체에도 공유 KMS 키를 적용해 알림에 포함되는 IP 주소와 공격 유형 정보를 암호화했습니다.![](https://velog.velcdn.com/images/yapp/post/c079e32f-d9f7-483b-9761-5e1a927b9272/image.png)

<!-- 📸 스크린샷 #7 — SNS 구독 확인 화면 (선택)
  위치: AWS SNS Console → Topics → devsecops-security-alerts → Subscriptions 탭
  또는: 구독 확인(Confirm subscription) 완료 이메일 화면
  내용: 이메일 구독이 "Confirmed" 상태로 표시된 화면
  방법: SNS 콘솔 Subscriptions 탭 캡처. 이메일 주소는 모자이크
  효과: "실제로 동작하는 알림 파이프라인"임을 증명
-->

### 5. WAF 우선순위 재정립

AI 탐지 룰이 매니지드 룰보다 나중에 평가되던 구조를 바꿔, 직접 정의한 룰이 먼저 평가되도록 조정했습니다.

| Priority | 룰 | 역할 |
|---------|-----|------|
| 0 | GeoBlock-Non-KR | 한국 외 IP 전체 차단 |
| 1 | AI-RealTime-Block | AI가 탐지한 이상 IP 즉시 차단 |
| 2 | AWSManagedRulesSQLiRuleSet | SQL 인젝션 방어 |
| 3 | AWSManagedRulesCommonRuleSet | 일반 웹 취약점 방어 |
| 4 | AWSManagedRulesAmazonIpReputationList | AWS 알려진 악성 IP 차단 |

Geo-Blocking을 가장 앞에 두면 해외 트래픽이 뒤의 룰까지 도달하지 않아 불필요한 후속 룰 평가와 로그 분석량을 줄일 수 있습니다.![](https://velog.velcdn.com/images/yapp/post/0f813f44-54b6-4dca-a92f-2976e10597b5/image.png)



<!-- 📸 스크린샷 #8 — WAF 콘솔 룰 우선순위 목록 (권장)
  위치: AWS WAF Console → Web ACLs → devsecops-waf → Rules 탭
  내용: Priority 0(GeoBlock) ~ 4(IP Reputation) 순서로 룰이 나열된 화면
  방법: Rules 탭 전체 캡처. 룰 이름과 Priority 컬럼이 모두 보여야 함
  효과: 테이블로 설명한 우선순위를 실제 콘솔 화면으로 직접 증명
-->

---

## 마치며

$30짜리 청구서 하나가 SSE-KMS의 과금 구조, Key Policy 권한 관리, 클라우드 비용 모니터링의 중요성을 한 번에 가르쳐줬습니다.

비용 사고를 수습하는 과정에서 IAM 권한 파편화, Terraform 상태 관리 허점, WAF 우선순위 설계까지 덩달아 드러났습니다. 보안 프로젝트를 하면서 정작 비용 보안은 놓쳤다는 게 아이러니였습니다. 클라우드에서 비용 통제는 보안의 일부입니다. 이후로는 새 리소스를 띄울 때마다 "이게 얼마나 호출될 수 있는가"를 먼저 따지게 됐습니다.

다음 편에서는 이 인프라의 앞단 보안 레이어인 AWS WAF를 Terraform으로 코드화하고, tfsec 정적 분석으로 컴플라이언스를 자동화한 과정을 다룬다.

---

**시리즈 네비게이션**
이전 글: [2편 — Kubernetes 환경에서의 컨테이너 애플리케이션 배포 자동화 및 Helm 기반 패키지 관리](https://velog.io/@yapp/07.-1.-%EC%84%9C%EB%B2%84%EB%A6%AC%EC%8A%A4-%ED%8F%AC%ED%8A%B8%ED%8F%B4%EB%A6%AC%EC%98%A4%EC%97%90-Kubernetes-%EB%8D%94%ED%95%98%EA%B8%B0-kind%EB%B6%80%ED%84%B0-EKS%EA%B9%8C%EC%A7%80)
다음 글: [4편 — AWS WAF v2 인프라 코드화(IaC) 및 tfsec 정적 분석 기반의 컴플라이언스 자동화](https://velog.io/@yapp/03WAF-%EB%A3%B0-5%EB%8B%A8%EA%B3%84%EB%A5%BC-Terraform%EC%9C%BC%EB%A1%9C-%EC%BD%94%EB%93%9C%ED%99%94%ED%95%98%EB%8B%A4)
