# AWS DevSecOps CI/CD Platform

> **Terraform IaC + GitHub Actions OIDC + tfsec Security Gate + Serverless 보안 자동화**  
> CI/CD 파이프라인이 인프라를 배포하고, 배포된 인프라가 실제로 보안 자동화를 수행하는 플랫폼

---

## 1. Project Overview

AWS WAF의 정적 룰이 탐지하지 못하는 변칙적 공격 패턴을 AI 엔진으로 보완하고, 위협 탐지부터 차단까지를 서버리스로 자동화한 DevSecOps 플랫폼입니다.

**이 프로젝트의 차별점**은 CI/CD로 끝나지 않는다는 점입니다.  
파이프라인이 배포한 인프라가 실제로 WAF 차단, AI 이상 탐지, Lambda 자동 대응, CloudWatch 관제까지 동작합니다.

| 역할 | 구성 |
| :--- | :--- |
| **CI/CD** | GitHub Actions → tfsec → Terraform → Lambda 배포 |
| **Prevention** | AWS WAF v2 (룰 4종 + AI 기반 IP Set 자동 업데이트) |
| **Detection** | Isolation Forest 이상 탐지 + Athena WAF 로그 분석 |
| **Response** | Lambda SOAR (WAF IP Set 자동 차단 + SNS 알림) |
| **Observability** | Grafana Cloud + CloudWatch 운영 관제 |

---

## 2. DevSecOps CI/CD Pipeline

```
[Push to main]
      │
      ▼
┌─────────────────────┐
│   Job 1: Security   │  Trivy IaC scan (HIGH/CRITICAL 차단)
│       Gates         │  tfsec Terraform 정적 분석
│                     │  Bandit Python 코드 분석
└─────────┬───────────┘
          │ 통과 시
          ▼
┌─────────────────────┐
│  Job 2: Terraform   │  terraform init → plan → apply
│    Plan / Apply     │  PR에 Plan 결과 자동 코멘트
└─────────┬───────────┘
          │ main push 시
          ▼
┌─────────────────────┐
│  Job 3: Lambda      │  SecurityAnalyzer / SecurityPreventer
│    Deploy           │  NormalTrafficGenerator 배포
└─────────────────────┘
```

- 코드가 AWS에 닿기 전에 보안 검증이 완료됩니다
- PR 단계에서 Terraform Plan 결과를 코멘트로 확인 가능합니다
- main 브랜치 push 시에만 실제 배포가 실행됩니다

---

## 3. Security Gates (tfsec)

Terraform 배포 전 `tfsec`으로 IaC 취약점을 선제 식별합니다.

### 초기 스캔 결과 및 조치

| 심각도 | 초기 건수 | 조치 후 |
| :---: | :---: | :---: |
| Critical | 1 | **0** |
| High | 10 | **0** |
| Medium | 8 | CI 제외 (--minimum-severity HIGH) |
| Low | 11 | CI 제외 |

### 실제 수정 사례

- **Cognito 패스워드 재사용 방지**: `3회 → 24회` 강화
- **S3 SSL 전용 접근**: 누락된 버킷 정책 추가
- 설계상 감수 항목은 `tfsec:ignore` 주석에 사유 명시

```yaml
# .github/workflows/deploy.yml
- name: tfsec
  uses: aquasecurity/tfsec-action@v1.0.0
  with:
    working_directory: ./infra
    tfsec_args: --minimum-severity HIGH
```

---

## 4. OIDC Authentication

장기 자격증명(Access Key) 없이 GitHub Actions → AWS 배포를 구현했습니다.

```
GitHub Actions Runner
      │  OIDC Token 발급
      ▼
AWS STS AssumeRoleWithWebIdentity
      │  Condition: repo + main 브랜치 한정
      ▼
github-actions-oidc-role
      │
      ▼
Terraform apply / Lambda deploy
```

```hcl
# main 브랜치 push만 허용
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:sub" =
      "repo:minju2022039105/aws-devsecops-platform:ref:refs/heads/main"
  }
}
```

**예외**: `grafana-cloudwatch-readonly` IAM user (CloudWatchReadOnlyAccess)는 Grafana Cloud 연동 목적으로 Access Key 사용. Terraform 관리 제외 — state 파일 보안 리스크 때문.

---

## 5. Terraform Infrastructure

전체 AWS 리소스를 Terraform으로 코드화해 재현 가능성을 확보했습니다.

```
infra/
├── main.tf            # Provider, Backend (S3 + DynamoDB)
├── apigateway.tf      # API Gateway REST v1
├── lambda.tf          # Lambda 함수 3종
├── cloudfront.tf      # CloudFront + Lambda@Edge
├── cloudtrail.tf      # 감사 로깅
├── config.tf          # ISMS Config Rules 11개
├── budget.tf          # 비용 거버넌스
├── traffic_generator.tf
└── modules/
    ├── waf/           # Regional WAF (API Gateway)
    └── vpc/
```

### WAF 우선순위 설계

| Priority | 규칙 | 근거 |
| :---: | :--- | :--- |
| 0 | GeoBlock-Non-KR | 한국 외 입구 차단 → 이후 모든 룰 검사 비용 절감 |
| 1 | AI-RealTime-Block | AI가 식별한 위협 IP 즉각 차단 |
| 2–4 | AWS Managed Rules | SQLi, XSS 등 알려진 패턴 방어 |
| 5 | IP Reputation List | 평판 불량 IP 차단 |

---

## 6. Serverless Security Automation (SOAR)

```
WAF Block 이벤트
      │
      ▼
Lambda SecurityAnalyzer     ← Isolation Forest 이상 탐지
      │  위협 확정 시
      ▼
Lambda SecurityPreventer
      │
      ├── WAF IP Set 자동 업데이트 (차단)
      └── SNS → 이메일 알림
```

### Lambda 함수 역할

| 함수 | 역할 |
| :--- | :--- |
| `SecurityAnalyzer` | WAF 로그 수신 → AI 이상 탐지 스코어 계산 |
| `SecurityPreventer` | 위협 IP → WAF IP Set 등록 + SNS 알림 발송 |
| `NormalTrafficGenerator` | 6시간마다 정상 트래픽 생성 (AI 모델 학습용) |

---

## 7. AI-based WAF Detection

AWS WAF 정적 룰의 사각지대를 **비지도 학습 Isolation Forest**로 보완합니다.

### 모델 구성

| 항목 | 내용 |
| :--- | :--- |
| 알고리즘 | Isolation Forest (비지도 학습) |
| 학습 데이터 | 공격 400건 (Nikto SQLi/XSS) + 정상 1,400건 = **1,800건** |
| contamination | **0.25** (공격 비율 22.2% + 오차 여유. 초기 0.15 → 정상 트래픽 혼합 후 상향) |
| n_estimators | **200** (소량 데이터 과적합 방지) |
| 탐지 결과 | 이상 345건 / 19.2%, Score IQR=0.0611 |

### 피처 설계 (4개)

| 피처 | 설명 |
| :--- | :--- |
| `country_code` | GeoIP — 한국 외 IP는 이상치로 분류 |
| `rule_code` | 매칭 WAF 룰 코드 — 동일 룰 반복 = 스캔 공격 징후 |
| `uri_len` | URI 길이 — SQLi 페이로드는 비정상적으로 길어짐 |
| `uri_entropy` | **Shannon Entropy** — 인코딩된 페이로드 탐지 핵심 피처 |

**Shannon Entropy 도입 이유**: 통계 피처(평균/표준편차)는 소량 데이터에서 불안정하지만, 엔트로피는 단일 문자열의 정보 구조를 측정해 샘플 수에 덜 의존적입니다.

### 모델 성능 평가 (eval_model_v2.py 기준)

`action` 컬럼(WAF 차단 여부)을 정답 레이블로 사용해 현행 모델의 탐지 성능을 측정했습니다.

| 지표 | 값 | 설명 |
| :--- | :---: | :--- |
| Precision | **58.0%** | AI 이상 탐지 345건 중 200건이 실제 WAF 차단 공격과 일치 |
| Recall | **50.0%** | WAF 차단 공격 400건 중 200건을 AI가 독립 검증 |
| F1-Score | **0.54** | 비지도 학습 모델 기준 준수한 수준 |
| FPR (오탐률) | **10.4%** | 정상 1,400건 중 145건 추가 이상 탐지 |
| 건당 처리 속도 | **0.016ms** | 실시간 처리 가능 |

**Before / After 비교**

| 구분 | 탐지 건수 | 방식 |
| :--- | :---: | :--- |
| WAF 단독 | 400건 | 정적 룰 매칭 |
| WAF + AI | **545건** | WAF 400 + AI 추가 145 |
| 탐지 범위 확대 | **+36.3%** | WAF가 허용한 트래픽 중 AI 추가 탐지 |

> Precision이 100%가 아닌 이유: 비지도 학습은 레이블 없이 분포 이상을 탐지합니다. WAF가 허용한 145건은 실제 제로데이 위협일 수 있으며, WAF 룰의 사각지대를 보완하는 AI의 핵심 역할입니다.

### Weighted Federated Averaging

분산 보안 노드에서 원본 WAF 로그를 전송하지 않고 모델 파라미터만 집계합니다.

```python
weights = [n_samples / total_samples for n_samples in node_samples]
# IDC 60.0% / 지사 24.9% / 소규모 지점 15.1%
```

---

## 8. Monitoring & Observability

### Observability 3계층 구조

```
[Local / Demo]     monitoring/prometheus-demo/monitor.py
                    └─ Prometheus metrics (:8000) — 로컬 데모·실험용

[Production]       WAF / Lambda / API Gateway
                    └─ AWS CloudWatch Metrics & Logs

[Visualization]    Grafana Cloud (devsecai.grafana.net)
                    └─ CloudWatch datasource
```

> Prometheus는 직접 구현해 검토했으나, 서버리스 환경에서는 스크래핑할 고정 엔드포인트가 없어 CloudWatch로 전환했습니다. 이 판단 과정 자체가 아키텍처 설계 역량을 보여줍니다.

### Grafana 대시보드 패널

| 패널 | 데이터소스 | 설명 |
| :--- | :--- | :--- |
| WAF 시간대별 차단 추이 | CloudWatch | BlockedRequests (Rule=ALL) Time series |
| 룰별 차단 건수 | CloudWatch | 4개 룰 분리 Bar chart |
| 공격 유형 분포 | Athena | WAF 로그 기반 Pie chart |
| 국가별 차단 | Athena | Geomap |
| 공격 IP Top10 | Athena | Table |

### CloudWatch vs Athena — 역할 분리 설계

두 데이터소스를 병행하는 이유는 속도와 분석 유연성의 트레이드오프 때문입니다.

| 항목 | CloudWatch | Athena (S3 WAF 로그) |
| :--- | :--- | :--- |
| **반영 속도** | ~1분 (준실시간) | ~5~15분 (Firehose 버퍼 + S3 적재) |
| **분석 대상** | 집계 메트릭 (차단 건수, 룰별 통계) | 원본 로그 (IP, URI, 국가, User-Agent) |
| **쿼리 방식** | 고정 메트릭 API | 자유 SQL (임의 조건, 집계, 조인) |
| **용도** | 긴급 대응, 이상 징후 탐지 | 원인 분석, 보안 인텔리전스 |

```
[긴급 대응]  차단 급증 감지 → CloudWatch 패널 (1분 이내)
                │
                ▼
[원인 분석]  어느 국가 / 어떤 URI / Top IP → Athena 패널 (5~15분)
```

CloudWatch는 WAF가 메트릭을 직접 push하므로 빠르지만, 원본 로그의 필드(IP, URI, 국가 등)에는 접근할 수 없습니다. Athena는 S3의 WAF 원본 로그를 SQL로 자유롭게 분석할 수 있어 공격 유형 분포, Top 공격 IP, URI 패턴 분석이 가능하지만 Kinesis Firehose 버퍼링으로 인해 지연이 발생합니다.

> **면접 한 줄 답변**: "CloudWatch는 빠른 이상 징후 탐지와 운영 모니터링에, Athena는 WAF 원본 로그 기반 심층 분석에 각각 강점이 있어 속도와 분석 유연성을 모두 확보하기 위해 두 경로를 병행했습니다."

---

### ISMS 컴플라이언스 (AWS Config)

Config Rules 11개로 ISMS 통제항목을 자동 점검합니다.

| ISMS 항목 | Config Rule | 상태 |
| :--- | :--- | :---: |
| 2.5 인증·권한관리 | Root 액세스 키 미사용 | ✅ |
| 2.5 인증·권한관리 | IAM 패스워드 정책 (14자, 90일 만료) | ✅ |
| 2.6 접근통제 | S3 퍼블릭 읽기/쓰기 차단 | ✅ |
| 2.6 접근통제 | VPC 기본 보안그룹 비활성화 | ✅ |
| 2.9 로그관리 | CloudTrail 활성화 + 무결성 검증 | ✅ |
| 2.10 시스템 보안 | S3 HTTPS 전용 접근 | ✅ |
| 2.11 사고 대응 | GuardDuty 활성화 | ✅ |

NON_COMPLIANT 감지 → EventBridge → 기존 `devsecops-security-alerts` SNS 토픽 알림

---

## 9. IAM & Network Security

### IAM 최소 권한 설계

역할마다 필요한 작업만 허용하고, 리소스 ARN을 명시해 와일드카드(`*`) 범위 접근을 제거했습니다.

| Principal | Role | 허용 권한 | 설계 의도 |
| :--- | :--- | :--- | :--- |
| **GitHub Actions** | `github-actions-oidc-role` | OIDC 조건부 신뢰 / EC2 RunInstances: `t3.micro` 타입만 / Terminate: `Project=devsecops-platform` 태그 리소스만 | 장기 자격증명 없음. 인스턴스 타입 조건으로 비용 폭탄 방지. 태그 없는 리소스 삭제 불가 |
| **Analyzer + Preventer Lambda** | `lambda_blocker_role` | S3 `results/*` GetObject만 / WAF `GetIPSet` + `UpdateIPSet` (특정 ARN 고정) / CloudWatch Logs 기본 | WAF WebACL 생성·삭제 권한 없음. IP Set 업데이트만 허용. S3는 results/ 경로만 |
| **Lambda@Edge** | `edge_lambda` | S3 `models/*` GetObject만 / CloudWatch Logs 기본 | 모델 파일 읽기 전용. 쓰기·삭제 없음. 모델 버킷 외 S3 접근 불가 |
| **VPC Flow Logs** | `vpc_flow_log_role` | 지정 Log Group ARN에만 `PutLogEvents` | CloudWatch 전체가 아닌 해당 로그 그룹만 쓰기 허용 |
| **Grafana Cloud** | `grafana-cloudwatch-readonly` (IAM User) | `CloudWatchReadOnlyAccess` | 유일한 IAM User 예외. Terraform state에 credentials 포함 시 보안 리스크 → Terraform 관리 제외 |

**GitHub Actions OIDC 신뢰 정책 — 장기 자격증명을 사용하지 않는 구조**

```hcl
# 이 레포지토리에서 발급된 OIDC 토큰만 역할 Assume 가능
Condition = {
  StringLike = {
    "token.actions.githubusercontent.com:sub" =
      "repo:minju2022039105/aws-devsecops-platform:*"
  }
}
```

GitHub Secrets가 유출되어도 이 Condition이 없는 외부 환경에서는 AWS 접근이 불가능합니다.

---

### 네트워크 보안 구조

**VPC 설계**

| 구성 | 값 | 설계 이유 |
| :--- | :--- | :--- |
| VPC CIDR | `10.0.0.0/16` | 퍼블릭 인터넷과 격리된 사설 네트워크 경계 |
| Public Subnet A | `10.0.1.0/24` (us-east-1a) | 멀티 AZ 가용성 확보 |
| Public Subnet B | `10.0.2.0/24` (us-east-1b) | |
| Private Subnet | **없음** | 서버리스 전환 후 EC2 없음. Lambda는 AWS 관리 VPC에서 실행 — Private Subnet은 관리 비용만 추가 |

**Security Group 인바운드 규칙**

| 포트 | 허용 대상 | 이유 |
| :---: | :--- | :--- |
| 22 (SSH) | `var.my_ip` 단일 IP | 관리자 IP 화이트리스트. 인터넷 전체 SSH 차단 |
| 3000 (Grafana) | `var.my_ip` 단일 IP | 대시보드 인터넷 노출 방지 |
| 그 외 | 전체 차단 | 명시적 허용만 통과 |

```hcl
# Default SG 비활성화 — AWS 기본값은 동일 SG 간 통신 허용
resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.main.id
  ingress = []
  egress  = []
}
```

**전송 중 암호화 (TLS)**

| 구간 | 설정 | 보안 효과 |
| :--- | :--- | :--- |
| 사용자 → CloudFront | `redirect-to-https` | HTTP 접근 시 자동 HTTPS 리다이렉트 |
| CloudFront → API Gateway | `https-only` + TLSv1.2 강제 | 오리진 구간 평문 통신 차단 |
| S3 버킷 정책 | `DenyNonSSL` (모든 버킷 공통) | HTTPS 아닌 S3 요청은 버킷 정책 레벨에서 거부 |

**지역 차단 이중 방어**

| 레이어 | 방법 | 적용 범위 |
| :--- | :--- | :--- |
| CloudFront | `geo_restriction whitelist: KR` | CloudFront 경유 요청 |
| WAF (Priority 0) | `GeoBlock-Non-KR` BLOCK 룰 | API Gateway 직접 접근 요청 |

CloudFront geo_restriction은 CloudFront 경로에서만 동작합니다. API Gateway 직접 접근에는 WAF GeoBlock이 차단을 담당해 두 레이어가 서로의 우회 경로를 막습니다.

---

### 감사 로깅 체계

```
[API 감사]     CloudTrail → S3 (전 리전 + KMS 암호화 + 로그 무결성 검증)
[네트워크]     VPC Flow Logs → CloudWatch 30일 보관 + S3 장기 보관 (이중화)
[리소스 노출]  IAM Access Analyzer → 계정 전체 외부 접근 가능 리소스 자동 탐지
```

**CloudTrail 주요 설정**

| 설정 | 값 | 보안 의미 |
| :--- | :--- | :--- |
| `is_multi_region_trail` | `true` | 리전 우회 API 호출도 전부 기록 |
| `enable_log_file_validation` | `true` | 로그 파일 해시 체인으로 변조(tamper) 감지 |
| KMS 암호화 | 공유 KMS 키 (`enable_key_rotation = true`) | S3 접근 권한이 있어도 복호화 없이 내용 열람 불가 |
| S3 버킷 정책 `SourceArn` 조건 | 이 계정의 이 Trail ARN만 허용 | 다른 계정의 Trail이 이 버킷에 쓰는 것을 차단 |

**VPC Flow Logs 이중 저장**

| 저장소 | 보관 기간 | 용도 |
| :--- | :---: | :--- |
| CloudWatch Logs | 30일 | 실시간 쿼리, CloudWatch Insights 분석 |
| S3 Archive | 장기 | 포렌식, 규정 준수 장기 보관 |

`traffic_type = "ALL"` 이유: REJECT 로그는 포트스캔 탐지에, ACCEPT 로그는 Lateral Movement 패턴 탐지에 사용합니다. 한쪽만 수집하면 공격 패턴의 절반을 놓칩니다.

---

## 10. Troubleshooting

### 1) KMS 비용 급증 ($30/일)
- **원인**: 리소스별 개별 KMS 키 생성 → API 호출 비용 급증
- **추적**: Cost Explorer → CloudTrail 역추적으로 호출 출처 특정
- **해결**: 공유 KMS 키 구조로 전환 + S3 Bucket Key 활성화

### 2) IAM AccessDenied → OIDC Condition 재설계
- **원인**: `StringLike` Condition으로 모든 브랜치에서 Assume 가능 → 보안 취약
- **해결**: `StringEquals`로 변경해 main 브랜치 배포만 허용

### 3) WAF WebACL 고정비 누수 ($5.33/월)
- **원인**: `cleanup.sh`가 WAF WebACL 의존성 순서를 무시하고 삭제 실패
- **해결**: 의존성 순서 파악 후 삭제 로직 재구성

### 4) sklearn 1.8.0 Private 속성 접근 오류
- **원인**: 버전 업데이트로 `_decision_path_lengths` 내부 속성이 Private으로 변경
- **해결**: 버전 다운그레이드 대신 `getattr` 기반 안전한 속성 추출로 재구성

### 5) VPC Default SG 컴플라이언스 위반
- **원인**: Terraform 관리 외 기본 VPC의 default SG에 self-referencing 규칙 잔존
- **해결**: `aws_default_security_group` 리소스로 Terraform에 편입 + 기본 VPC 규칙 CLI 제거

---

## 11. 프로젝트 구조

```
aws-devsecops-platform/
├── infra/                    # Terraform IaC
│   └── modules/              # waf/, vpc/ 재사용 모듈
├── lambda/                   # Lambda 함수
│   ├── analyzer/             # SecurityAnalyzer
│   ├── preventer/            # SecurityPreventer
│   ├── edge_security/        # CloudFront Lambda@Edge
│   └── traffic_generator/    # NormalTrafficGenerator
├── ai/                       # AI/ML 엔진
│   ├── data/                 # 학습 데이터 (1,800건)
│   ├── models/               # Isolation Forest, Scaler
│   ├── training/             # train_model.py, federated_learning.py
│   └── inference/            # 평가·분석 스크립트
├── monitoring/               # Observability (역할 기준 분리)
│   ├── prometheus-demo/      # monitor.py — 로컬 데모용
│   └── cloudwatch/           # Athena DDL, Grafana 대시보드
├── scripts/                  # 트래픽 시뮬레이션
├── docs/                     # 블로그, 작업일지
└── tfsec/                    # Terraform 보안 스캔 결과
```

---

## 12. Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| **Compute** | AWS Lambda (Serverless) |
| **Networking & Security** | AWS WAF v2, CloudFront, API Gateway |
| **AI/ML** | Scikit-learn (Isolation Forest), Federated Learning |
| **Compliance** | AWS Config (Rules 11개), GuardDuty, IAM Password Policy |
| **Infrastructure** | Terraform, GitHub Actions (OIDC), tfsec, KMS, CloudTrail |
| **Monitoring** | Grafana Cloud, CloudWatch, SNS |

---

## DevSecOps Pipeline Status: Active
