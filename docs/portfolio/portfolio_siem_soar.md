# AWS DevSecOps Platform — 보안 데이터 분석 / SIEM·SOAR

> 상세 내용 및 전체 코드: [GitHub README](https://github.com/minju2022039105/aws-devsecops-platform) · [Velog 시리즈](https://velog.io/@yapp/series/WAF%EA%B0%80-%EB%AA%BB-%EC%9E%A1%EB%8A%94-%EA%B3%B5%EA%B2%A9-AI%EB%A1%9C-%EC%9E%A1%EA%B8%B0)

> WAF 보안 로그 수집 → AI 이상 탐지 → 자동 차단까지 연결한 클라우드 기반 AI Driven SOC 플랫폼

---

## 1. Project Overview

| 역할 | 구성 |
| :--- | :--- |
| **로그 수집** | AWS WAF → Kinesis Firehose → S3 적재 |
| **로그 분석** | Athena SQL 분석 + Grafana 시각화 |
| **이상 탐지** | Isolation Forest 비지도 학습 (AI Driven SOC) |
| **자동 대응** | Lambda SOAR (WAF IP Set 자동 차단 + SNS 알림) |
| **CI/CD 보안** | GitHub Actions → Trivy + Bandit → Terraform 배포 |

---

## 2. Design Decisions

### 왜 이 프로젝트를 시작했는가

WAF 정적 룰은 알려진 공격에 강하지만, 변칙적 패턴에는 사각지대가 존재합니다.
보안 로그를 단순 저장하는 데 그치지 않고 분석 → 탐지 → 차단까지 자동화된 파이프라인을 직접 설계했습니다.

### 핵심 설계 결정

**Why Athena?**
CloudWatch는 집계 메트릭 중심이라 원본 로그(IP, URI, 국가, User-Agent)에 접근이 불가능합니다. Athena로 S3의 WAF 원본 로그를 SQL로 직접 분석해 공격 IP Top10, 국가별 분포, URI 패턴 등 심층 분석을 구현했습니다.

**Why Isolation Forest?**
레이블이 없는 운영 환경에서 지도 학습 적용이 불가능했습니다. 비지도 학습으로 라벨링 비용을 제거하고 WAF 정적 룰의 2차 탐지 계층(AI Driven SOC)으로 설계했습니다.

**Why Serverless SOAR?**
탐지 결과가 나오는 즉시 운영자 개입 없이 차단까지 자동화하기 위해. S3 이벤트 트리거 → Lambda → WAF IP Set 업데이트 구조로 대응 지연을 제거했습니다.

---

## 3. Key Achievements

- 위협 탐지부터 차단까지 완전 자동화 — S3 트리거 → WAF IP Set 무인 대응
- SQLi 탐지 재현율 100%, 미탐 0건 달성
- WAF 원본 로그 기반 Athena + Grafana 보안 관제 대시보드 구축
- 배포 전 보안 이슈 전량 제거 — Critical 1건, High 10건 → 0
- KMS 호출 폭증 원인 추적 후 일일 $30 비용 정상화

---

## 4. Architecture

![전체 아키텍처](../architecture/최종아키텍처.png)

---

## 5. 보안 로그 수집 파이프라인

```
AWS WAF
  │  차단/허용 로그 실시간 생성
  ▼
Kinesis Data Firehose
  │  버퍼링 후 S3 적재 (5~15분)
  ▼
S3 (waf-logs/)
  │
  ├── Athena → SQL 분석 (IP, URI, 국가, User-Agent)
  └── Grafana Cloud → 시각화 (공격 유형 분포, Top IP, Geomap)
```

**CloudWatch vs Athena 역할 분리**:

| 항목 | CloudWatch | Athena |
| :--- | :--- | :--- |
| 반영 속도 | ~1분 | ~5~15분 |
| 분석 대상 | 집계 메트릭 (차단 건수, 룰별 통계) | 원본 로그 (IP, URI, 국가) |
| 용도 | 긴급 대응·이상 징후 탐지 | 원인 분석·보안 인텔리전스 |

긴급 대응은 CloudWatch(1분), 심층 분석은 Athena — 속도와 분석 깊이를 역할에 따라 분리했습니다.

![WAF 보안 관제 대시보드](../architecture/스크린샷/waf_dashboard.png)

---

## 6. SOAR 자동 대응 파이프라인

탐지 결과가 S3에 적재되는 즉시 Lambda가 트리거되어 WAF IP Set을 자동 업데이트합니다.

```
AI 탐지 결과 → S3 results/*.json
      ↓ ObjectCreated 트리거
Lambda: SecurityAnalyzer
      │  Athena 쿼리 → anomaly=1 IP 추출
      ↓
Lambda: SecurityPreventer
      ├── WAF IP Set 자동 등록 (devsecops-ai-block-list)
      └── CloudWatch AIOps/Security 메트릭 기록
```

- SecurityPreventer 역할은 WAF IP Set 업데이트만 허용 — WebACL 생성·삭제 권한 없음 (최소 권한 원칙)
- S3 → Lambda → WAF IP Set 자동 차단 파이프라인 end-to-end 검증 완료

![CloudWatch AI 탐지 메트릭](../architecture/스크린샷/cloudwatch_ai_metric.png)
*Lambda SOAR가 WAF IP Set을 자동 업데이트할 때 기록되는 DefenseSignal 메트릭 — 탐지와 차단이 연결되어 있음을 보여줍니다.*

---

## 7. AI Driven SOC — Isolation Forest 이상 탐지

WAF 정적 룰이 허용한 트래픽 중 변칙 패턴을 비지도 학습으로 추가 탐지합니다.

| 항목 | 값 |
| :--- | :--- |
| 알고리즘 | Isolation Forest (비지도 학습) |
| 학습 데이터 | 공격 400건 + 정상 1,400건 = **1,800건** |
| 이상치 비율 (contamination) | **0.25** |
| 트리 수 (n_estimators) | **200** |

**피처 설계**: WAF 로그의 `uri`와 `args`를 분리해 각각 Shannon Entropy 측정 — SQLi 페이로드는 query string에 집중되므로 단일 URI 엔트로피보다 탐지력이 높습니다.

| 피처 | 설명 |
| :--- | :--- |
| `args_entropy` | query string 엔트로피 — SQLi 탐지 핵심 |
| `path_entropy` | URI path 엔트로피 |
| `uri_len` | 비정상적으로 긴 URI = 페이로드 삽입 징후 |
| `country_code` | 한국 외 IP 이상치 분류 |
| `rule_code` | 동일 룰 반복 = 스캔 공격 징후 |

**탐지 성능** (SQLi 100건 + 정상 1,350건 = 1,500건 기준):

| 지표 | 값 | 설명 |
| :--- | :---: | :--- |
| 재현율 (Recall) | **100%** | 공격 미탐 0건 |
| 정밀도 (Precision) | **30.6%** | 비지도 이상 탐지 특성상 오탐 발생 |
| 오탐률 (FPR) | **16.2%** | 정상 1,350건 중 227건 이상 후보 분류 |
| 처리 속도 | **0.016ms/건** | 실시간 처리 가능한 수준 |

재현율 100% / 미탐 0건: 공격 미탐 방지를 우선하는 보수적 탐지 전략. 오탐 227건은 운영자 검토 대상으로 WAF 정적 룰의 2차 탐지 레이어 역할을 합니다.

![AI 보안 대시보드](../architecture/스크린샷/ai_dashboard.png)

---

## 8. ISMS 컴플라이언스 자동화

AWS Config Rules 11개로 ISMS 통제항목을 자동 점검합니다.
NON_COMPLIANT 감지 → EventBridge → SNS 알림 자동화.

| ISMS 항목 | 내용 | 상태 |
| :--- | :--- | :---: |
| 인증·권한관리 | Root 액세스 키 미사용, IAM 패스워드 정책 | ✅ |
| 접근통제 | S3 퍼블릭 차단, VPC 기본 SG 비활성화 | ✅ |
| 로그관리 | CloudTrail 활성화 + 무결성 검증 | ✅ |
| 사고 대응 | GuardDuty 활성화 | ✅ |

![ISMS Config Rules](../architecture/스크린샷/isms_config_rules_2.png)

---

## 9. DevSecOps CI/CD — 배포 전 보안 검증

| 도구 | 검사 대상 | 결과 |
| :--- | :--- | :--- |
| **Trivy IaC** | Terraform 코드 | HIGH / CRITICAL 차단 |
| **Bandit** | Python Lambda 코드 | 보안 취약점 정적 분석 |
| **tfsec** (수동) | Terraform 수동 감사 | Critical 1건, High 10건 → 0 |

![CI/CD 파이프라인](../architecture/스크린샷/cd_pipeline.png)

---

## 10. 주요 트러블슈팅

**KMS 비용 $30/일 급증 — CloudTrail 역추적**
리소스별 개별 KMS 키 생성으로 614만 건/일 API 호출 발생. Cost Explorer → CloudTrail 역추적으로 출처 특정 → 공유 KMS 키 + S3 Bucket Key 전환으로 정상화.

**OIDC Condition 보안 취약**
`StringLike` Condition으로 모든 브랜치 Assume 가능 → `StringEquals`로 main 브랜치 배포만 허용.

---

## 11. Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| **로그 수집·분석** | AWS WAF, Kinesis Firehose, S3, Athena |
| **SOAR / 자동화** | AWS Lambda (Python), SNS, CloudWatch |
| **AI/ML** | Isolation Forest (Scikit-learn) |
| **시각화** | Grafana Cloud, CloudWatch Dashboard |
| **컴플라이언스** | AWS Config, GuardDuty, CloudTrail, KMS |
| **Infrastructure / CI/CD** | Terraform, GitHub Actions (OIDC), Trivy, Bandit |

---

**DevSecOps 인프라 파이프라인**: 완료 (2026.05.28)  
**AI 탐지 고도화**: 진행 예정 (WAF 로그 직접 연동 / contamination 재튜닝)
