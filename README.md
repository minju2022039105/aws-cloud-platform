# 🛡️ Cloud-Native WAF AIOps Platform
> **Terraform 기반 IaC와 비지도 학습(Isolation Forest) + 연합 학습(Federated Learning)을 결합한 준실시간 이상 징후 탐지 및 보안 자동화(SOAR) 플랫폼**

---

## 1. 프로젝트 개요 (Executive Summary)

AWS WAF의 정적 규칙(Static Rule)이 탐지하지 못하는 변칙적 공격 패턴을 **비지도 학습 AI 엔진**으로 보완하는 지능형 보안 운영 체계입니다.

인프라 전체를 Terraform으로 코드화하여 재현 가능성을 확보하였으며, 분산 환경에서 원본 로그를 노출하지 않고 다수 노드의 위협 지식을 통합하는 **Privacy-Preserving Federated Learning** 구조를 적용했습니다.

---

## 2. 시스템 아키텍처 (Architecture)

<img width="2043" height="518" alt="AWS AIOps Security Architecture" src="https://github.com/user-attachments/assets/a5c144c7-ed15-40cc-9bcd-7c15b4d2de2e" />

### 계층별 핵심 역할

| 계층 | 구성 | 역할 |
| :--- | :--- | :--- |
| **Prevention** | AWS WAF v2 | 1차 방어 + 전체 요청 로그 S3 Export |
| **Detection** | Amazon Athena + Isolation Forest | S3 로그 쿼리 → AI 이상 탐지 (준실시간, 약 5~10분) |
| **Response** | EventBridge → Lambda | 위협 확정 시 WAF IP Set 자동 업데이트 + SNS 알림 |

### WAF 우선순위 설계 근거

| Priority | 규칙 | 엔지니어링 근거 |
| :---: | :--- | :--- |
| 0 | GeoBlock-Non-KR | 한국 외 트래픽을 입구에서 차단 → 이후 모든 룰 검사 비용 절감 |
| 1 | AI-RealTime-Block | AI가 식별한 위협 IP 즉각 차단 — 정적 규칙의 사각지대 보완 |
| 2–4 | AWS Managed Rules | SQLi, XSS 등 알려진 패턴 방어 |
| 5 | IP Reputation List | 평판 불량 IP 보수적 차단 |

> **[검토 중]** 비용 최적화를 위해 현재 ALB+EC2 구조를 API Gateway+Lambda 서버리스로 전환하는 방안을 검토 중입니다.

---

## 3. AI 엔진 (AIOps Core)

### Isolation Forest 기반 이상 탐지

> Lambda 함수(Analyzer, Preventer) 및 기본 탐지 파이프라인 구조는 팀 프로젝트 [Security-AIOps-IsolationForest](https://github.com/minju2022039105/Security-AIOps-IsolationForest)에서 담당한 파트를 가져왔습니다. `train_model.py`, `federated_learning.py`, Shannon Entropy 피처 설계, Weighted FedAvg, ContaminationSentinel은 이 프로젝트에서 독자적으로 설계 및 구현했습니다.

졸업작품 당시 가공된 데이터셋(정확도 91%) 대신, **실제 Nikto 공격 로그 + 합성 정상 트래픽 혼합 1,800건**을 기반으로 실무형 탐지 모델을 구성했습니다.

| 항목 | 내용 |
| :--- | :--- |
| 알고리즘 | Isolation Forest (비지도 학습) |
| 학습 데이터 | 공격 로그 400건 (Nikto SQLi/XSS) + 합성 정상 트래픽 1,350건 = **1,800건** |
| contamination | **0.25** (공격 400/1,800 ≈ 22.2% → 오차 여유 포함. 초기 0.15에서 정상 트래픽 혼합 후 상향) |
| n_estimators | **200** (과적합 방지를 위한 충분한 트리 수 — 소량 데이터일수록 트리 수↑로 분산 평균화) |
| 탐지 결과 | 이상 탐지 345건 / 19.2%, Score IQR=0.0611 (과적합 기준 0.05 초과 → 정상 판정) |

**알고리즘 선택 근거**: Autoencoder(리소스 과다), One-Class SVM(대규모 느림) 대비 비지도 + 준실시간 스코어링에 최적화.

### 피처 설계 (4개)

| 피처 | 설명 |
| :--- | :--- |
| `country_code` | GeoIP 기반 — 한국 외 IP는 GeoBlock 이전에도 이상치로 분류 |
| `rule_code` | 매칭된 WAF 규칙 코드 — 동일 rule 반복 = 스캔 공격 징후 |
| `uri_len` | URI 길이 — SQL Injection 페이로드는 비정상적으로 길어지는 경향 |
| `uri_entropy` | **Shannon Entropy** — 인코딩된 페이로드 탐지 핵심 피처 |

**Shannon Entropy 도입 이유**: 통계적 피처(평균/표준편차)는 소량 데이터에서 추정값이 불안정하지만, 엔트로피는 단일 문자열의 내재적 정보 구조를 측정하므로 샘플 수에 덜 의존적입니다.

```
정상 URI (/api/users/profile):        entropy ≈ 2.5 ~ 3.5
SQL Injection (?id=1' UNION SELECT):  entropy ≈ 3.8 ~ 4.2
Base64/URL 인코딩된 페이로드:          entropy ≈ 4.5 ~ 5.5
```

### Weighted Federated Averaging (연합 학습)

분산된 보안 노드(본사/지사) 환경에서 **원본 WAF 로그를 전송하지 않고** 모델 파라미터(Tree 구조, Offset)만 집계합니다.

```python
# 데이터 볼륨 기반 가중치 산출
weights = [n_samples / total_samples for n_samples in node_samples]
# 결과: IDC 60.0% / 지사 24.9% / 소규모 지점 15.1%
```

- **Privacy-Preserving**: 개인정보보호법(PIPA) 준수 — 원본 로그 미전송
- **불균형 보정**: 데이터가 적은 소규모 지점이 글로벌 모델을 왜곡하지 않도록 가중치 적용
- **검증**: 3노드 시뮬레이션, 이상 탐지 비율 55.6% 확보

### 모델 한계

| 한계 | 내용 |
| :--- | :--- |
| Low-and-Slow 공격 | 장시간에 걸쳐 소량 요청을 보내는 패턴은 단기 윈도우 기반 탐지로 식별 어려움 |
| 탐지 지연 | S3 → Athena → AI → Lambda 파이프라인으로 약 5~10분 준실시간 처리 (실시간 아님) |
| 학습 데이터 편향 | Nikto SQLi 위주 — XSS, 경로 순회 등 다양한 공격 유형 데이터 추가 예정 |
| Sentinel 값 왜곡 | 국가코드 99 등 더미 데이터가 Recall 지표를 왜곡 — ContaminationSentinel로 보정 중 |

---

## 4. Infrastructure as Code (Terraform)

- **전체 리소스 코드화**: VPC, WAF, Lambda, API Gateway, KMS, CloudTrail 등 Terraform 모듈로 구성
- **보안 시프트 레프트**: tfsec으로 배포 전 23개 취약점(Critical 4건) 선제 식별 및 수정
- **최소 권한 IAM**: Lambda/EC2/GitHub Actions 각 Role ARN 특정, 와일드카드(*) 미사용, OIDC main 브랜치 한정
- **비용 거버넌스**: AWS Budgets + 자동 알림으로 일일 지출 임계값 관리

---

## 5. ISMS 컴플라이언스 자동화 (AWS Config)

클라우드 보안 아키텍트 포지션 JD의 ISMS/ISO27001 컴플라이언스 경험 요건을 충족하기 위해, 기존 인프라(WAF, GuardDuty, CloudTrail)와 겹치는 ISMS 통제항목을 **AWS Config Rules로 자동 점검하는 파이프라인**을 구축했습니다.

### 파이프라인 구조

```
AWS Config Recorder (전체 리소스 유형 기록)
    ↓
Config Rules 11개 (ISMS 통제항목 1:1 매핑)
    ↓
NON_COMPLIANT 감지 → EventBridge Rule
    ↓
기존 devsecops-security-alerts SNS 토픽 (알림 채널 통합)
    ↓
기존 CloudTrail S3 버킷 (/config prefix 분리 저장)
```

### ISMS 통제항목 ↔ Config Rule 매핑

| ISMS 항목 | Config Rule | 준수 상태 |
| :--- | :--- | :---: |
| 2.5 인증 및 권한관리 | Root 액세스 키 미사용 | ✅ 준수 |
| 2.5 인증 및 권한관리 | IAM 패스워드 정책 (14자, 대소문자+숫자+특수, 90일 만료) | ✅ 준수 |
| 2.5 인증 및 권한관리 | 콘솔 접근 MFA 활성화 | — 평가 없음 (IAM 콘솔 사용자 없음) |
| 2.6 접근통제 | S3 퍼블릭 읽기 차단 | ✅ 준수 |
| 2.6 접근통제 | S3 퍼블릭 쓰기 차단 | ✅ 준수 |
| 2.6 접근통제 | VPC 기본 보안그룹 비활성화 | ✅ 준수 |
| 2.9 로그 관리 | CloudTrail 활성화 | ✅ 준수 |
| 2.9 로그 관리 | CloudTrail 로그 무결성 검증 | ✅ 준수 |
| 2.10 시스템 보안관리 | S3 HTTPS 전용 접근 (SSL) | ✅ 준수 |
| 2.10 시스템 보안관리 | EBS 볼륨 암호화 | — 평가 없음 (EC2 없음) |
| 2.11 사고 예방 및 대응 | GuardDuty 활성화 | ✅ 준수 |

### 설계 포인트

- **기존 인프라 재사용**: Config 전달 채널에 CloudTrail 전용 S3 버킷(`/config` prefix 분리) 재활용 → 버킷 추가 비용 없음
- **알림 채널 통합**: NON_COMPLIANT 이벤트를 기존 `devsecops-security-alerts` SNS 토픽으로 라우팅 → 단일 알림 채널 유지
- **추적 가능한 Rule 명명**: `isms-{항목번호}-{내용}` 형식으로 ISMS 매핑 관계를 코드에서 직접 확인 가능

### 미준수 → 수정 이력

| 발견 항목 | 원인 | 해결 |
| :--- | :--- | :--- |
| Root 액세스 키 존재 | 초기 설정 시 생성한 키 잔존 (마지막 사용 51일 전) | AWS 콘솔에서 수동 삭제 |
| IAM 패스워드 정책 미설정 | 정책 리소스 미생성 | `aws_iam_account_password_policy` 추가 → terraform apply |
| VPC 기본 보안그룹 규칙 존재 | Terraform 관리 외 기본 VPC의 default SG에 self-referencing 규칙 잔존 | Terraform VPC: `aws_default_security_group` ingress/egress 빈 배열 명시 + 기본 VPC: CLI로 규칙 직접 제거 |
| S3 버킷 5개 SSL 정책 누락 | 버킷 생성 시 bucket policy 미적용 | Terraform 관리 버킷 3개: `aws_s3_bucket_policy` 추가 / Terraform 외부 버킷 2개: `aws s3api put-bucket-policy` CLI로 직접 적용 |
| GuardDuty 미활성화 | 리소스 미생성 | `aws_guardduty_detector` 추가 → terraform apply |

---

## 6. 트러블슈팅 (Troubleshooting Deep Dive)

### 1) IAM AccessDenied → 최소 권한 재설계
- **문제**: GitHub Actions OIDC Role이 `StringLike` Condition으로 모든 브랜치에서 Assume 가능
- **해결**: `StringEquals`로 변경하여 main 브랜치 배포만 허용. Policy Before/After 비교로 최소 권한 원칙 재설계

### 2) KMS 비용 급증 ($30/일)
- **문제**: 리소스별 개별 KMS 키 생성으로 API 호출 비용 급증
- **해결**: Cost Explorer → CloudTrail 역추적으로 원인 파악. 공유 KMS 키 구조로 변경하여 비용 정상화

### 3) WAF WebACL 고정비 누수 ($5.33/월)
- **문제**: `cleanup.sh`가 WAF WebACL을 삭제하지 않아 미사용 상태에서 월 $5 고정 과금 발생
- **해결**: WAF WebACL 의존성 순서 파악 후 cleanup.sh에 삭제 로직 추가

### 4) sklearn 1.8.0 Private 속성 접근 오류
- **문제**: `AttributeError: '_decision_path_lengths'` — 버전 업데이트로 내부 속성이 Private으로 변경
- **해결**: 버전 다운그레이드 대신 `getattr` 기반 안전한 속성 추출 로직으로 재구성. sklearn 내부 동작 원리 심층 파악

---

## 7. 실시간 관제 대시보드 (Observability)

<img width="1024" alt="Grafana Dashboard" src="https://github.com/user-attachments/assets/e2ba077a-a9ac-410c-b7ed-78760ecac001">

**[ 프로젝트 시연 영상](https://www.youtube.com/watch?v=rIG2oWAm2Bo)**

| 상태 | 색상 | 의미 |
| :--- | :---: | :--- |
| Normal | 🟢 | 정상 모니터링 |
| Preparing | 🟠 | 위협 점수 상승, 선제적 방어 준비 |
| Blocked | 🔴 | 위협 확정, WAF IP 자동 차단 실행 |
| Stabilize | 🔵 | 공격 종료 후 잔류 위협 집중 감시 |

---

## 8. Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| **Compute** | AWS Lambda, Amazon EC2 |
| **Networking & Security** | AWS WAF v2, CloudFront, ALB, API Gateway, VPC |
| **Data & AI** | Amazon S3, Amazon Athena, Scikit-learn (Isolation Forest), Federated Learning |
| **Compliance** | AWS Config (Rules 11개), Amazon GuardDuty, AWS IAM Password Policy |
| **Infrastructure** | Terraform, GitHub Actions (OIDC), tfsec, AWS KMS, CloudTrail |
| **Monitoring** | Grafana, Amazon CloudWatch, AWS SNS |
## DevSecOps Pipeline Status: Active
