# AWS DevSecOps CI/CD Platform

> 상세 내용 및 전체 코드: [GitHub README](https://github.com/minju2022039105/aws-devsecops-platform) · [Velog 시리즈](https://velog.io/@yapp/series/WAF%EA%B0%80-%EB%AA%BB-%EC%9E%A1%EB%8A%94-%EA%B3%B5%EA%B2%A9-AI%EB%A1%9C-%EC%9E%A1%EA%B8%B0)

> Terraform IaC + GitHub Actions OIDC + Security Gates (Trivy + Bandit) + Serverless 보안 자동화  
> CI/CD 파이프라인이 인프라를 배포하고, 배포된 인프라가 실제로 보안 자동화를 수행하는 플랫폼

---

## 1. Project Overview

| 역할 | 구성 |
| :--- | :--- |
| **CI/CD 파이프라인** | GitHub Actions → Trivy + Bandit → Terraform → Lambda 배포 |
| **사전 차단** | AWS WAF v2 (GeoBlock + Managed Rules + AI 기반 IP Set 자동 업데이트) |
| **이상 탐지** | Isolation Forest 이상 탐지 + Athena WAF 로그 분석 |
| **자동 대응** | Lambda SOAR (WAF IP Set 자동 차단 + SNS 알림) |
| **운영 관제** | Grafana Cloud + CloudWatch + Athena |

---

## 2. Design Decisions

### 왜 이 프로젝트를 시작했는가

AWS WAF는 알려진 공격 패턴에 강하지만 변칙적 공격에는 사각지대가 존재합니다.
룰 기반 탐지의 한계를 보완하고, 탐지 이후 차단까지 자동화된 구조를 목표로 설계했습니다.

### 핵심 설계 결정

**Why OIDC?**
GitHub Secrets 기반 Access Key를 제거하고 장기 자격증명 유출 위험을 차단하기 위해. `StringEquals` 조건으로 main 브랜치에서만 배포 가능한 구조를 구현했습니다.

**Why Isolation Forest?**
레이블이 없는 운영 환경에서 지도 학습 적용이 불가능했습니다. 비지도 학습으로 라벨링 비용을 제거하고, WAF 정적 룰의 2차 탐지 계층으로 설계했습니다.

**Why Athena?**
CloudWatch는 집계 메트릭 중심이라 원본 WAF 로그(IP, URI, 국가)에 접근이 불가능합니다. Athena로 S3의 원본 로그를 SQL로 직접 분석하는 구조를 선택했습니다.

**Why Serverless?**
운영 부담 없이 이벤트 기반 자동 대응 구조를 구현하기 위해. S3 트리거 → Lambda → WAF IP Set 업데이트로 탐지부터 차단까지 운영자 개입 없이 자동화했습니다.

---

## 3. Key Achievements

- 장기 Access Key 완전 제거 — OIDC 기반 조건부 배포 구조 구현
- 배포 전 보안 이슈 전량 제거 — Critical 1건, High 10건 → 0
- 위협 탐지부터 차단까지 완전 자동화 — S3 트리거 → WAF IP Set 무인 대응
- SQLi 탐지 Recall 100%, FN 0건 달성
- KMS 호출 폭증 원인 추적 후 일일 $30 비용 정상화

---

## 4. Architecture

![전체 아키텍처](../architecture/최종아키텍처.png)

---

## 5. DevSecOps CI/CD Pipeline

```
[Push to main]
      │
      ▼
┌─────────────────────┐
│   Job 1: Security   │  Trivy IaC scan (HIGH/CRITICAL 차단)
│       Gates         │  Bandit Python 코드 분석
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

- 코드가 AWS에 닿기 전에 보안 검증 완료 (Trivy + Bandit)
- PR 단계에서 Terraform Plan 결과를 자동 코멘트로 확인
- main 브랜치 push 시에만 실제 배포 실행 (OIDC 조건 제한)

![CI/CD 파이프라인](../architecture/스크린샷/cd_pipeline.png)

---

## 6. Security Gates

| 도구 | 검사 대상 | 기준 |
| :--- | :--- | :--- |
| **Trivy IaC** | Terraform 코드 정적 분석 | HIGH / CRITICAL 차단 |
| **Bandit** | Python Lambda 코드 분석 | 보안 취약점 정적 분석 |
| **tfsec** (수동) | Terraform 코드 수동 감사 | Critical 1 → 0, High 10 → 0 조치 |

주요 조치: Cognito 패스워드 재사용 방지 3회 → 24회, S3 SSL 전용 접근 버킷 정책 추가

| Before | After |
|:---:|:---:|
| ![tfsec Before](../architecture/스크린샷/tfsec_before.png) | ![tfsec After](../architecture/스크린샷/tfsec_after.png) |

---

## 7. OIDC Authentication

장기 자격증명(Access Key) 없이 GitHub Actions → AWS 배포 구현.

```hcl
# main 브랜치 push만 역할 Assume 허용
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:sub" =
      "repo:minju2022039105/aws-devsecops-platform:ref:refs/heads/main"
  }
}
```

GitHub Secrets 유출 시에도 이 Condition이 없는 외부 환경에서는 AWS 접근 불가.

---

## 8. WAF Rule Architecture

| Priority | 규칙 | 근거 |
| :---: | :--- | :--- |
| 0 | GeoBlock-Non-KR | 한국 외 입구 차단 → 이후 모든 룰 검사 비용 절감 |
| 1 | AI-RealTime-Block | AI가 식별한 위협 IP 즉각 차단 |
| 2–4 | AWS Managed Rules | SQLi, XSS 등 알려진 패턴 방어 |
| 5 | IP Reputation List | 평판 불량 IP 차단 |

---

## 9. Serverless SOAR Pipeline

```
monitor.py (AI 추론 결과 생성)
      │  S3 업로드: results/*.json
      ▼
S3 ObjectCreated 트리거
      ▼
Lambda: SecurityAnalyzer
      │  Athena aiops_results 쿼리 → anomaly=1 IP 추출
      ▼
Lambda: SecurityPreventer
      ├── WAF IP Set (devsecops-ai-block-list) 자동 업데이트
      └── CloudWatch Namespace: AIOps/Security 메트릭 기록
```

> S3 → Lambda → WAF IP Set 자동 차단까지 end-to-end 파이프라인 검증 완료.  
> monitor.py는 현재 CSV 기반 시뮬레이션 입력 생성기 — 실제 WAF 로그 직접 연동은 향후 개선 방향.

![CloudWatch AI 탐지 메트릭](../architecture/스크린샷/cloudwatch_ai_metric.png)
*AI 이상 탐지 결과를 기반으로 Lambda SOAR가 WAF IP Set을 자동 업데이트할 때 기록되는 DefenseSignal 메트릭 — 탐지와 차단이 연결되어 있음을 보여줍니다.*

---

## 10. AI 이상 탐지 (Isolation Forest)

AWS WAF 정적 룰의 사각지대를 비지도 학습으로 보완.

| 항목 | 값 |
| :--- | :--- |
| 알고리즘 | Isolation Forest (비지도 학습) |
| 학습 데이터 | 공격 400건 + 정상 1,400건 = **1,800건** |
| 이상치 비율 (contamination) | **0.25** |
| 트리 수 (n_estimators) | **200** |

**피처 5개**: `country_code`, `rule_code`, `uri_len`, `path_entropy`, `args_entropy`

SQLi 페이로드는 query string에 집중 → `path`와 `args` 엔트로피를 분리 측정한 것이 핵심 설계 결정.

**모델 성능** (SQLi 100건 + 정상 1,350건 = 1,500건 기준):

| 지표 | 값 | 설명 |
| :--- | :---: | :--- |
| 재현율 (Recall) | **100%** | 공격 미탐 0건 |
| 정밀도 (Precision) | **30.6%** | 비지도 이상 탐지 특성상 오탐 발생 |
| 오탐률 (FPR) | **16.2%** | 정상 1,350건 중 227건을 이상 후보로 분류 |
| 처리 속도 | **0.016ms/건** | 실시간 처리 가능한 수준 |

> Recall 100% / FN=0: 공격 미탐 방지를 우선하는 보수적 탐지 전략.  
> FP 227건은 운영자 검토 대상. WAF 정적 룰의 사각지대를 보완하는 2차 레이어.

![AI 보안 대시보드](../architecture/스크린샷/ai_dashboard.png)

---

## 11. Monitoring & Observability

**CloudWatch vs Athena 역할 분리**:

| 항목 | CloudWatch | Athena |
| :--- | :--- | :--- |
| 반영 속도 | ~1분 | ~5~15분 |
| 분석 대상 | 집계 메트릭 (차단 건수, 룰별 통계) | 원본 로그 (IP, URI, 국가) |
| 용도 | 긴급 대응·이상 징후 탐지 | 원인 분석·보안 인텔리전스 |

Grafana Cloud에서 두 데이터소스를 단일 대시보드로 통합 — WAF 메트릭 + AI 모델 성능 + 원본 로그 분석을 한 화면에.

![WAF 보안 관제 대시보드](../architecture/스크린샷/waf_dashboard.png)

**ISMS 컴플라이언스**: AWS Config Rules 11개로 ISMS 통제항목 자동 점검.  
NON_COMPLIANT 감지 → EventBridge → SNS 알림 자동화.

![ISMS Config Rules](../architecture/스크린샷/isms_config_rules_2.png)

---

## 12. IAM & Network Security

- **Lambda 최소 권한**: WAF IP Set 업데이트만 허용, S3는 `results/` 경로만 — WebACL 생성·삭제 권한 없음.
- **지역 차단 이중화**: CloudFront `geo_restriction` + WAF GeoBlock Priority 0 — CF 경로와 API Gateway 직접 접근 양쪽 차단.
- **전송 중 암호화**: 전 구간 HTTPS 강제, S3 `DenyNonSSL` 정책 적용.
- **감사 로깅**: CloudTrail(멀티리전 + 무결성 검증) + VPC Flow Logs(CloudWatch + S3 이중 저장).

---

## 13. 주요 트러블슈팅

**KMS 비용 $30/일 급증**  
리소스별 개별 KMS 키 생성 → Cost Explorer + CloudTrail 역추적으로 호출 출처 특정 → 공유 KMS 키 + S3 Bucket Key 전환으로 해결.

**OIDC Condition 보안 취약**  
`StringLike` Condition으로 모든 브랜치에서 Assume 가능 → `StringEquals`로 main 브랜치 배포만 허용.

**WAF WebACL 고정비 누수 ($5.33/월)**  
`cleanup.sh`가 WAF WebACL 의존성 순서를 무시하고 삭제 실패 → 의존성 순서 파악 후 삭제 로직 재구성.

---

## 14. Extension: Kubernetes 기반 AI 추론 서버 배포

메인 프로젝트(Lambda 서버리스)의 AI 추론 엔진을 컨테이너 환경에서도 동일하게 운용할 수 있는지 검증한 확장 실험.

- FastAPI 추론 서버 컨테이너화 → kind(로컬) 및 EKS(클라우드) 배포 검증
- Helm 차트 단일 명령 배포, Rolling Update / Rollback 검증
- Trivy 이미지 스캔 CRITICAL 0건

![Trivy 이미지 스캔](../architecture/스크린샷/trivy_image_scan.png)

![Kubernetes /predict API 호출](../architecture/스크린샷/kub_predict_api.png)

---

## 15. Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| **Infrastructure / CI/CD** | Terraform, GitHub Actions (OIDC), Trivy, Bandit, tfsec |
| **Security** | AWS WAF v2, CloudFront, API Gateway, KMS, CloudTrail, AWS Config |
| **Serverless** | AWS Lambda |
| **AI/ML** | Isolation Forest (Scikit-learn) |
| **Monitoring** | Grafana Cloud, CloudWatch, Athena |
| **Container** | Docker, Kubernetes (kind / EKS), Helm, ECR |

---

*DevSecOps Pipeline Status: 진행중*
