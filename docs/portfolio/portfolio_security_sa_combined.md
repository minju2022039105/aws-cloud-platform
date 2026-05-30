# Security Engineer Portfolio

**GitHub (DevSecOps)**: https://github.com/minju2022039105/aws-devsecops-platform  
**GitHub (AIOps)**: https://github.com/minju2022039105/Security-AIOps-IsolationForest  
**Velog**: https://velog.io/@yapp

---

## 핵심 역량

AWS WAF · Isolation Forest · Lambda SOAR · Terraform IaC · ISMS 컴플라이언스  
실 환경 공격 차단 검증 / 60초 선행 탐지 / CI/CD Security Gate / ISMS 자동 점검

---

## Project 1. AWS 3-Layer Security AIOps Platform

> 6인 팀 | 보안 파트 단독 담당 | 클라우드웨이브 7기 | 2026.02 (3주)  
> GitHub: https://github.com/minju2022039105/Security-AIOps-IsolationForest

### 왜 이 구조를 설계했는가

이커머스 플랫폼 보안 파트를 맡으면서 두 가지 제약이 설계 기준을 결정했다.

| 제약 | 내용 | 설계 결정 |
| :--- | :--- | :--- |
| **예산** | $1,200 크레딧으로 3주간 EKS 운영 | 악성 트래픽을 Edge에서 먼저 제거 → EKS 오토스케일링 방지 |
| **레이블 부재** | 실운영 보안 로그는 대부분 미분류 | 비지도 학습(Isolation Forest)으로 정상 패턴 이탈 탐지 |

세 가지 원칙으로 수렴했다: **앞단 차단 → 비지도 탐지 → 완전 자동화**.

---

### 전체 아키텍처

```
[Layer 1: Edge Defense]
Route53 → CloudFront → WAF v2 → ALB → EKS

[Layer 2: Predictive AIOps]
WAF 로그 → Isolation Forest → pred_risk → S3 → Athena → Grafana

[Layer 3: SOAR Pipeline]
GuardDuty → EventBridge → SNS → Analyzer Lambda → Preventer Lambda → WAF IPSet
```

<!-- 📷 이미지: Security-AIOps-IsolationForest/assets/architecture.png
     위치: 텍스트 아키텍처 다이어그램 아래
     설명: Route53 → CloudFront → WAF → ALB → EKS 흐름과 3개 Layer가 S3로 연결되는 전체 구조 -->

각 계층은 독립적으로 작동하고 S3 데이터 레이크로 연결된다.  
차단된 공격 패턴이 ML 피드백으로 재투입되는 폐루프 구조.

---

### Layer 1: Edge Defense

**왜 CloudFront + WAF 이중 방어인가?**  
CloudFront Origin Cloaking으로 EKS 실제 IP를 외부에 노출하지 않는다. ALB 직접 접근 경로를 Security Group으로 차단해 CloudFront 우회를 원천 봉쇄했다.

| Priority | 규칙 | 근거 |
| :---: | :--- | :--- |
| 0 | Allow-Only-Korea | 해외 트래픽 입구 차단 → 이후 룰 검사 비용 절감 |
| 1 | AWSManagedRulesCommonRuleSet | OWASP Top 10 |
| 2 | AWSManagedRulesSQLiRuleSet | SQL Injection 특화 |
| 3 | AWSManagedRulesKnownBadInputsRuleSet | Log4j / JNDI |
| 4 | IP Reputation List (동적) | Lambda가 실시간 갱신하는 AI 블랙리스트 |

<!-- 📷 이미지: Security-AIOps-IsolationForest/assets/waf-rules.png
     위치: WAF Priority 표 아래
     설명: AWS 콘솔에서 캡처한 WAF 규칙 5단계 목록 — 설계한 Priority 순서가 실제로 적용된 것을 증명 -->

---

### Layer 2: Predictive AIOps — Isolation Forest

**왜 비지도 학습인가?**  
실운영 보안 로그는 레이블이 없고 정상 데이터가 99% 이상이다. 지도 학습 모델 구축에 필요한 공격 샘플을 충분히 확보하기 어렵기 때문에 정상 패턴을 학습하고 이탈을 탐지하는 비지도 방식을 선택했다.

**60초 선행 탐지**  
공격자는 치명적 공격 전에 반드시 스캐닝 → 취약점 탐색 → 반복 요청의 사전 정찰을 수행한다. 이 사전 정찰에서 발생하는 미세한 이상 패턴을 감지해 실제 공격 도달 약 60초 전에 대응 시간을 확보한다.

**Dynamic Threshold**  
고정 임계값은 트래픽 패턴 변화 시 오탐이 증가한다. 전체 위험 점수 분포의 하위 5%를 임계값으로 설정해 실시간 트래픽 흐름에 따라 자동 조정된다.

**Pre-Mitigation**  
예측 위험도(`pred_risk > 70`) 초과 시 실제 공격 확인 전에 방어 레벨을 선제적으로 올린다.

<!-- 📷 이미지: Security-AIOps-IsolationForest/assets/grafana-table.png
     위치: Pre-Mitigation 설명 아래
     설명: Grafana 테이블 패널 — obs_risk / pred_risk 수치와 Pre-Mitigation 활성화 상태가 찍힌 화면.
           pred_risk 75.0이 임계값(70)을 초과해 premit_on=True로 전환된 순간을 보여줌 -->

---

### Layer 3: SOAR Pipeline

```
GuardDuty → EventBridge → SNS (Slack·Email·Lambda 동시 전달)
    ↓
Analyzer Lambda → Athena 조회 → 공격 IP / 위험도 종합 판단
    ↓
Preventer Lambda → WAF IPSet 업데이트
```

**탐지~차단 46ms 달성**  
WAF IPSet 업데이트 시 동시 요청 충돌을 막기 위해 Lock Token을 획득 후 갱신하는 구조로 구현.

<!-- 📷 이미지: Security-AIOps-IsolationForest/assets/analyzer-query.png
     위치: "탐지~차단 46ms 달성" 아래
     설명: Analyzer Lambda가 Athena에 공격 IP 조회 쿼리를 실행하는 화면 — SOAR 파이프라인의 분석 단계 실증 -->

**왜 LGP Stack인가 (OpenSearch 미채택)**  
OpenSearch는 전용 클러스터 운영 비용이 높다. Grafana 하나로 CloudWatch 메트릭 + Athena 로그 + ML 스코어를 단일 화면에 통합해 운영 비용을 80% 이상 절감했다.

---

### 검증 결과

| 시나리오 | 결과 |
| :--- | :---: |
| SQL Injection 페이로드 | **403 Forbidden** |
| Log4j / JNDI Injection | **403 Forbidden** |
| 해외 IP 접근 (네덜란드·미국) | **403 Forbidden** |
| GuardDuty 탐지 → Lambda 자동 차단 | **WAF IPSet 자동 갱신** |

Athena 로그 분석으로 **유효 차단 로그 8건** 확보. `pred_risk 75.0` 측정 시 Pre-Mitigation 모드 정상 활성화 확인.

<!-- 📷 이미지 (3개 나란히 또는 순서대로 배치 권장):

  1. Security-AIOps-IsolationForest/assets/403-block.png
     설명: SQLi 페이로드 전송 시 반환된 403 Forbidden 응답 화면 — WAF 차단 실증

  2. Security-AIOps-IsolationForest/assets/aiops-dashboard.png
     설명: AIOps 전체 관제 대시보드 — obs_risk / pred_risk 추이, 차단 이벤트 타임라인

  3. Security-AIOps-IsolationForest/assets/grafana-gauge.png
     설명: pred_risk 게이지 패널 — 위험도 수치가 임계값을 넘어 경보 상태로 전환된 화면 -->

---

### 핵심 트러블슈팅

**WAF 차단 미작동 — 근본 원인 3가지 규명**  
트래픽 흐름·우회 경로·룰 우선순위 차원에서 분석해 구조적 원인 3가지를 각각 규명. ALB Security Group을 CloudFront Prefix List 전용으로 제한해 WAF 우회 경로 원천 차단.

**WAF IPSet 생성 실패 (ValidationException)**  
`Description` 필드에 한글 포함 시 AWS API가 거부. 영문으로 변경해 해결.

---

### Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| 보안 아키텍처 | AWS WAF v2, CloudFront, GuardDuty, Security Group |
| SOAR / 자동화 | EventBridge, Lambda (Python), SNS |
| AI/ML | Isolation Forest (Scikit-learn) |
| 모니터링 | S3, Athena, Grafana Cloud, CloudWatch |
| 컨테이너 | EKS, ALB |

---
---

## Project 2. AWS DevSecOps CI/CD Platform

> 개인 프로젝트 | 진행 중  
> GitHub: https://github.com/minju2022039105/aws-devsecops-platform

<!-- 📷 이미지: docs/architecture/최종아키텍처.png
     위치: 프로젝트 헤더 바로 아래
     설명: DevSecOps 플랫폼 전체 아키텍처 — CloudFront → API Gateway → Lambda → WAF → S3/Athena/Grafana 흐름.
           Project 1(EKS 환경)과 달리 서버리스 단독 구조임을 한눈에 보여주는 이미지 -->

**이 프로젝트의 핵심**: Project 1에서 부재했던 CI/CD Security Gate, IaC 전체 코드화, ISMS 컴플라이언스 자동화를 서버리스 단독 환경에서 구현했다.

WAF + Isolation Forest + Lambda SOAR + Grafana는 Project 1과 동일한 패턴을 서버리스 환경에 적용한 것이며, 아래에서는 이 프로젝트에서만 볼 수 있는 요소에 집중한다.

---

### 1. CI/CD Security Gate — 코드가 AWS에 닿기 전에

```
[Push to main]
      │
      ▼
┌──────────────────────┐
│  Job 1: Security     │  Trivy IaC scan (HIGH/CRITICAL → 배포 차단)
│        Gates         │  Bandit Python 코드 분석
└──────────┬───────────┘
           │ 통과 시
           ▼
┌──────────────────────┐
│  Job 2: Terraform    │  terraform init → plan → apply
│   Plan / Apply       │  PR에 Plan 결과 자동 코멘트
└──────────┬───────────┘
           │ main push 시
           ▼
┌──────────────────────┐
│  Job 3: Lambda       │  SecurityAnalyzer / SecurityPreventer 배포
│        Deploy        │
└──────────────────────┘
```

배포 단계마다 보안 검증이 내장된 구조. Security Gates를 통과하지 못하면 Terraform apply 자체가 실행되지 않는다.

<!-- 📷 이미지 (2개 순서대로 배치):

  1. docs/architecture/스크린샷/cd_pipeline.png
     설명: GitHub Actions 워크플로우 실행 화면 — Job 1(Security Gates) → Job 2(Terraform) → Job 3(Lambda Deploy)
           3단계가 순서대로 통과되는 실제 파이프라인 실행 결과

  2. docs/작업일지/image/PR에 Terraform Plan 코멘트 달린 화면.png
     설명: PR에 Terraform Plan 결과가 자동 코멘트로 달린 화면 — "배포 전에 변경 사항을 검토한다"는 설계 의도의 실증 -->

---

### 2. GitHub Actions OIDC — 장기 자격증명 없는 배포

장기 자격증명(Access Key) 없이 GitHub Actions → AWS 배포를 구현했다.

```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:sub" =
      "repo:minju2022039105/aws-devsecops-platform:ref:refs/heads/main"
  }
}
```

`StringLike` → `StringEquals` 수정 경위: 초기 설계에서 `StringLike` 사용 시 모든 브랜치에서 Assume이 가능한 구조였음을 직접 확인하고 재설계.

GitHub Secrets가 유출되어도 이 Condition이 없는 외부 환경에서는 AWS 접근이 불가능하다.

---

### 3. IaC 보안 감사 — tfsec

전체 AWS 리소스를 Terraform으로 코드화한 뒤 tfsec으로 수동 보안 감사를 수행했다.

| 심각도 | 초기 | 조치 후 |
| :---: | :---: | :---: |
| Critical | 1 | **0** |
| High | 10 | **0** |

주요 조치: Cognito 패스워드 재사용 방지 3회 → 24회, 누락된 S3 SSL 전용 접근 정책 추가.  
설계상 감수 항목은 `tfsec:ignore` 주석에 사유 명시.

<!-- 📷 이미지 (Before / After 나란히 배치 권장):

  1. docs/architecture/스크린샷/tfsec_before.png
     설명: tfsec 최초 실행 결과 — Critical 1건 / High 10건이 검출된 화면

  2. docs/architecture/스크린샷/tfsec_after.png
     설명: 조치 완료 후 재실행 결과 — Critical 0 / High 0으로 클린된 화면
           "탐지 후 조치까지 완료했다"는 증거 -->

---

### 4. ISMS 컴플라이언스 자동 점검

AWS Config Rules 11개로 ISMS 통제항목을 자동 점검한다.

| ISMS 항목 | Config Rule |
| :--- | :--- |
| 2.5 인증·권한관리 | Root 액세스 키 미사용, IAM 패스워드 정책 (14자, 90일 만료) |
| 2.6 접근통제 | S3 퍼블릭 읽기/쓰기 차단, VPC 기본 보안그룹 비활성화 |
| 2.9 로그관리 | CloudTrail 활성화 + 무결성 검증 |
| 2.10 시스템 보안 | S3 HTTPS 전용 접근 |
| 2.11 사고 대응 | GuardDuty 활성화 |

NON_COMPLIANT 감지 → EventBridge → SNS 알림 자동화.

<!-- 📷 이미지: docs/architecture/스크린샷/isms_config_rules_2.png
     위치: ISMS 표 아래
     설명: AWS Config 콘솔에서 Rules 11개가 COMPLIANT 상태로 표시된 화면 — 설계한 규칙이 실제로 동작 중임을 증명 -->

---

### 5. AI 이상 탐지 — 피처 설계 심화

Project 1의 Isolation Forest(피처 3개)에서 진화한 구조.

**핵심 설계 결정**: AWS WAF 로그는 URI path와 query string을 분리 저장한다. SQL Injection 페이로드는 query string에 집중되므로 단일 `uri_entropy`로는 탐지력이 낮았다. path와 args를 분리해 Shannon Entropy를 각각 측정하는 방식으로 해결했다.

| 피처 | 역할 |
| :--- | :--- |
| `country_code` | GeoIP 기반 이상치 |
| `rule_code` | 동일 룰 반복 = 스캔 공격 징후 |
| `uri_len` | SQLi 페이로드의 비정상 길이 |
| `path_entropy` | URI path Shannon Entropy |
| `args_entropy` | query string Entropy — **SQLi/XSS 핵심 탐지 피처** |

**모델 성능** (SQLi 100건 + 정상 1,350건 = 1,500건 평가):

| 지표 | 값 |
| :--- | :---: |
| Recall | **100%** (FN=0, 공격 미탐 0건) |
| FPR | 16.2% (FP는 운영자 검토 대상) |
| 처리 속도 | 0.016ms/건 |

Recall 100% / FN=0: 공격 미탐 방지를 우선하는 보수적 탐지 전략.

<!-- 📷 이미지 (2개 순서대로 배치):

  1. docs/architecture/스크린샷/cloudwatch_ai_metric.png
     설명: CloudWatch 대시보드 — AIOps/Security 네임스페이스의 DefenseSignal 메트릭.
           S3 → Lambda → WAF IP Set 자동 차단 파이프라인이 실제로 메트릭을 기록하는 화면

  2. docs/architecture/스크린샷/ai_dashboard.png
     설명: Grafana AI 보안 대시보드 — anomaly 탐지 결과, 위험도 분포, 차단된 IP 목록.
           Project 1과 동일한 관제 구조를 서버리스 환경에서 재현한 것을 보여줌 -->

---

### 6. Kubernetes Extension

서버리스 구조와 별개로 동일 AI 추론 엔진을 컨테이너로 배포.

| 단계 | 내용 |
| :--- | :--- |
| Phase 1 (로컬) | FastAPI AI 추론 서버 컨테이너화 → kind 클러스터 배포 → `/predict` 호출 검증 |
| Phase 2 (EKS) | ECR 이미지 push → EKS 클러스터 생성 → 실배포 후 엔드포인트 검증 |

Helm 차트, Rolling Update / Rollback, Trivy 이미지 스캔 (CRITICAL 0건) 포함.

<!-- 📷 이미지 (2개 순서대로 배치):

  1. docs/architecture/스크린샷/trivy_image_scan.png
     설명: Trivy 컨테이너 이미지 스캔 결과 — CRITICAL 0건.
           "배포 전 이미지 보안 검증까지 자동화했다"는 증거

  2. docs/architecture/스크린샷/kub_predict_api.png
     설명: EKS 배포 후 /predict 엔드포인트 호출 화면 — 피처 5개 입력 → anomaly / score 반환.
           Phase 2 실배포 완료 증명 -->

---

### 핵심 트러블슈팅

**KMS 비용 $30/일 급증**  
리소스별 개별 KMS 키 생성이 원인. Cost Explorer → CloudTrail 역추적으로 호출 출처를 특정하고, 공유 KMS 키 + S3 Bucket Key 전환으로 해결. 단순 비용 절감이 아닌 CloudTrail을 역추적 도구로 활용한 사례.

**OIDC Condition 보안 취약 (StringLike → StringEquals)**  
`StringLike`로 전체 브랜치에서 Assume 가능한 구조였음을 직접 확인 후 `StringEquals`로 재설계. GitHub Secrets 유출 시나리오까지 고려한 수정.

**WAF WebACL 고정비 누수 ($5.33/월)**  
`cleanup.sh`가 WAF WebACL 의존성 순서를 무시하고 삭제 실패 → 의존성 순서 파악 후 삭제 로직 재구성.

---

### Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| Infrastructure / CI/CD | Terraform, GitHub Actions (OIDC), Trivy, Bandit, tfsec, KMS, CloudTrail |
| 보안 / 네트워킹 | AWS WAF v2, CloudFront, API Gateway |
| SOAR / 자동화 | Lambda (Python), S3, SNS |
| AI/ML | Scikit-learn (Isolation Forest) |
| 컴플라이언스 | AWS Config (Rules 11개), GuardDuty, IAM Password Policy |
| 모니터링 | Grafana Cloud, CloudWatch, Athena |
| 컨테이너 | Docker, Kubernetes (kind / EKS), Helm, ECR |

<!-- 📷 이미지: docs/architecture/스크린샷/waf_dashboard.png
     위치: Tech Stack 표 아래 (또는 섹션 5 AI 탐지 파트 이후로 이동 가능)
     설명: Grafana WAF 보안 관제 대시보드 — CloudWatch(차단 추이) + Athena(공격 유형 분포, 국가별, Top IP) 패널.
           멀티 데이터소스 통합 관제 구조를 한 화면에 보여주는 이미지 -->

---
---

## 기술 역량 요약

| 영역 | 기술 / 도구 | 경험 수준 |
| :--- | :--- | :--- |
| **클라우드 보안** | AWS WAF v2, GuardDuty, CloudFront, Security Group | 실 환경 설계·검증 |
| **자동화 (SOAR)** | Lambda, EventBridge, SNS | 46ms 탐지~차단 구현 |
| **AI 이상 탐지** | Isolation Forest, Shannon Entropy, 피처 엔지니어링 | 두 프로젝트 독립 구현 |
| **IaC / CI/CD** | Terraform, GitHub Actions OIDC, Trivy, Bandit, tfsec | 전체 인프라 코드화 |
| **컴플라이언스** | AWS Config, ISMS 자동 점검 | Rules 11개 직접 설계 |
| **관제** | Grafana Cloud, CloudWatch, Athena | 멀티 데이터소스 통합 |
| **컨테이너** | Docker, Kubernetes (kind/EKS), Helm, ECR | Phase 1~2 실 배포 |
