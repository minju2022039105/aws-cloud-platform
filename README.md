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
| 학습 데이터 | 공격 400건 (Nikto SQLi/XSS) + 정상 1,350건 = **1,750건** |
| contamination | **0.25** (공격 비율 22.9% + 오차 여유. 초기 0.15 → 정상 트래픽 혼합 후 상향) |
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

| Principal | Role / Policy | 범위 |
| :--- | :--- | :--- |
| GitHub Actions | `github-actions-oidc-role` | OIDC, main 브랜치 한정 |
| SecurityAnalyzer Lambda | 인라인 정책 | WAF Read, S3 GetObject, Lambda Invoke |
| SecurityPreventer Lambda | 인라인 정책 | WAF UpdateIPSet, SNS Publish |
| NormalTrafficGenerator | 인라인 정책 | API Gateway Invoke 한정 |
| Grafana Cloud | `grafana-cloudwatch-readonly` | CloudWatchReadOnlyAccess |

- 와일드카드(`*`) Resource 미사용
- 각 Lambda는 필요한 AWS 서비스만 최소 권한으로 접근
- OIDC로 장기 자격증명 제거

### CloudTrail 감사 로깅

- 모든 API 호출 기록 → S3 (`/cloudtrail` prefix) + KMS 암호화
- Config 전달 채널도 동일 버킷 재활용 (`/config` prefix 분리)
- 단일 버킷으로 감사 로그 통합 관리

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
│   ├── data/                 # 학습 데이터 (1,750건)
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
