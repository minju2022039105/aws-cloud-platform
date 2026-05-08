# 614만 건의 KMS 호출 — 무한루프가 $30 청구서를 만든 날

> 이 글은 **AWS WAF + AI 이상 탐지 플랫폼 구축기** 시리즈의 5편입니다.
> 실습 중 발생한 비용 사고의 원인 분석부터 긴급 대응, 재발 방지까지 기록합니다.
> 전체 코드는 [GitHub](https://github.com/minju2022039105/aws-devsecops-platform)에서 확인할 수 있습니다.

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

---

## 원인 분석: 두 숫자가 일치한 이유

S3 요청 수와 KMS 요청 수가 1:1로 일치하는 건 우연이 아닙니다.

S3 버킷에 **SSE-KMS(Server-Side Encryption with KMS)** 를 적용하면, 오브젝트를 쓸 때마다 `kms:GenerateDataKey`가, 읽을 때마다 `kms:Decrypt`가 자동으로 호출됩니다. API를 직접 호출하지 않아도, S3 작업 하나당 KMS 호출이 하나 따라오는 구조입니다.

```
S3 PUT 1회  →  kms:GenerateDataKey 자동 호출
S3 GET 1회  →  kms:Decrypt 자동 호출
```

KMS는 월 20,000건까지 무료이고, 이후 **10,000건당 $0.03**이 과금됩니다. SSE-S3(AES-256)는 같은 암호화를 무료로 제공합니다. 암호화 방식 선택 하나가 $18의 차이를 만들었습니다.

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

EC2 인스턴스(`ip-10-0-1-155`)에서 실행 후 SSH 세션을 닫았는데, 백그라운드에서 스크립트가 계속 돌고 있었습니다. `while True`에 종료 조건이 없었고, nohup이나 systemd 없이 실행했음에도 SSH 세션이 끊긴 뒤에도 프로세스가 살아있었습니다.

여기에 Analyzer Lambda가 Athena를 통해 이 파일들을 반복 스캔하면서 `kms:Decrypt` 호출이 추가로 쌓였습니다.

```
monitor.py 업로드 (PUT) → KMS GenerateDataKey
Analyzer Lambda 스캔 (GET) → KMS Decrypt
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

일부 키는 `AccessDenied`가 발생했습니다. Root 계정으로 키 정책(Key Policy)을 직접 수정해 관리 권한을 확보한 뒤 삭제 예약했습니다.

### 2. 비용 유발 리소스 정리

- **ALB 삭제**: 시간당 $0.0225 과금 중이던 Application Load Balancer 삭제
- **퍼블릭 IPv4 정리**: 323시간치 과금($1.61) 확인 후 관련 리소스 점검

### 3. AWS Support 환불 요청

Billing Support Case를 접수했습니다. 학습 목적의 실수임을 명시하고, 비정상 API 호출 614만 건에 대한 일회성 환불(Waiver)을 요청했습니다.

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

월 $5 초과 시 이메일 알림을 받도록 Budgets를 설정했습니다. 청구서를 직접 확인하기 전에 임계치에서 먼저 알 수 있게 됩니다.

### 장기 실행 스크립트 관리 원칙

- EC2에서 스크립트를 실행할 때는 `nohup` 또는 systemd로 명시적으로 관리
- 무한루프가 필요한 경우 반드시 최대 실행 횟수 또는 종료 시각을 조건으로 추가
- 실습 후 EC2 프로세스 목록(`ps aux`) 확인을 습관화

---

## 마치며

$30짜리 청구서 하나가 SSE-KMS의 과금 구조, Key Policy 권한 관리, 클라우드 비용 모니터링의 중요성을 한 번에 가르쳐줬습니다.

보안 프로젝트를 하면서 정작 비용 보안은 놓쳤다는 게 아이러니했습니다. 클라우드에서 비용 통제는 보안의 일부입니다. 이후로는 새 리소스를 띄울 때마다 "이게 얼마나 호출될 수 있는가"를 먼저 따지게 됐습니다.
