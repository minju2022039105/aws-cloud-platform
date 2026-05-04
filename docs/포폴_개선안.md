# 김민주님 포트폴리오 개선안

> 프로젝트: Cloud-Native WAF AIOps Platform
GitHub: [https://github.com/minju2022039105/aws-devsecops-platform](https://github.com/minju2022039105/aws-devsecops-platform)
분석 기준: 클라우드 인프라 포트폴리오 7대 점검 기준
희망 직무: 클라우드 보안 (인프라도 고려 중)
분석 일자: 2026-04-13
> 

---

## 현업 실무자 조언 요약 (SK쉴더스 클라우드 보안팀)

미팅 전 반드시 인지해야 할 내용:

1. 클라우드 보안은 크게 AWS Native 보안과 3rd party 보안 솔루션으로 나뉨
    - Native: AWS WAF, NFW(IPS), Shield, GuardDuty 등
    - 3rd party: TrendMicro, Paloalto, PentaSecurity, CrowdStrike 등
2. 학습 우선순위: 네트워크/인프라 흐름 → 보안 서비스 개념 → 보안 모델(SIEM, SOAR, CSPM 등) → Linux 기본
3. 프로젝트 권장 구성:
    - 웹 보안: AWS WAF (ALB 리소스)
    - 네트워크 보안: AWS NFW (IPS) ← 현재 프로젝트에 없음
    - 인프라 위협 진단: GuardDuty ← 현재 프로젝트에 없음
    - 부가: Lambda로 위협 IP 자동 차단 + S3 로그 로깅
4. 자격증보다 프로젝트와 보안 기초가 더 중요
5. 서드파티 솔루션은 라이선스 문제로 프로젝트에 넣기 어려움 → 개념 이해만 있으면 됨

→ 현재 프로젝트는 WAF + AI 탐지 + Lambda 자동 차단까지는 잘 되어 있으나,
현업이 권장하는 NFW(네트워크 보안)와 GuardDuty(인프라 위협 진단)가 빠져 있음.
이 두 가지를 추가하면 "AWS Native 보안을 폭넓게 다룬 프로젝트"로 레벨업 가능.

---

## [프로젝트 정보]

- 프로젝트명: Cloud-Native WAF AIOps Platform
- 프로젝트 목적/배경: AWS WAF 정적 규칙의 한계를 비지도 학습(Isolation Forest) AI로 극복하는 보안 자동화(SOAR) 플랫폼
- 사용 기술 스택: AWS EKS, EC2, Lambda, WAF v2, CloudFront, ALB, S3, Athena, EventBridge, Terraform, tfsec, Grafana, Scikit-learn
- 아키텍처: Prevention(WAF) → Detection(Athena+AI) → Response(Lambda+WAF IP Set) 3계층
- 본인 역할: 전체 설계 및 구현 (1인 프로젝트)

---

## 1. 프로젝트 문제 정의

### 현재 상태

- 잘된 점: "AWS WAF 정적 규칙의 한계를 AI로 극복"이라는 방향 자체는 명확함
- 부족한 점: "정적 규칙의 한계"가 추상적임. 어떤 공격을 못 막는지 구체적 시나리오가 없음. 정량적 Before/After 목표 없음

### 개선 액션

1. 구체적 공격 시나리오 2~3개로 "정적 규칙의 한계"를 설명할 것
    - 예: "Rate-based Rule은 분당 요청 수 기준이라 Low-and-Slow 공격(분당 50건 미만, 수 시간 지속)을 탐지 못함"
    - 예: "Managed Rule은 시그니처 기반이라 인코딩 변형 SQLi(`%27%20OR%201%3D1`)를 놓칠 수 있음"
2. 보안 KPI 정의: 탐지율(Detection Rate), 오탐률(FPR), MTTD(탐지 소요 시간), MTTR(차단 소요 시간)
3. Before/After 비교 데이터 추가: "WAF만 사용 시 탐지율 X% → AI 결합 후 Y%"

---

## 2. 아키텍처 설계

### 현재 상태

- 잘된 점: Prevention/Detection/Response 3계층 분리가 명확함. CloudFront → WAF → ALB 흐름이 보임. 1차 피드백 이후 인프라 전체 구성 + 보안 요소가 함께 보이도록 재구성됨
- 누락된 요소:
    - VPC 내부 네트워크 보안 상세 (SG 규칙, NACL, Subnet 배치 근거) 없음
    - EKS가 이 아키텍처에서 어떤 워크로드를 실행하는지 불명확
    - S3 → Athena → EC2(AI) → Lambda 파이프라인의 실제 소요 시간 미측정
    - AI 엔진(EC2) 단일 장애 지점(SPOF)
    - "실시간"이라는 표현이 S3+Athena 기반 구조와 맞지 않음
    
    ![](https://velog.velcdn.com/images/soowooj/post/e2cfa5b9-c5cd-42ec-808d-af3033298c97/image.png)
    
    ![](https://velog.velcdn.com/images/soowooj/post/e9708454-4934-43aa-9099-9d01d1abb57f/image.png)
    

### 개선 액션

1. 아키텍처 설명에 네트워크 보안 상세 추가 (SG 인바운드/아웃바운드 규칙 표, Private/Public Subnet 배치 근거)
    - 보안 직무라면 "어떤 포트를 왜 열었고, 왜 나머지는 닫았는지"를 설명할 수 있어야 함
2. 파이프라인 전체 소요 시간 측정 → "준실시간(Near Real-Time, 약 X분)" 형태로 수정
3. EKS 역할 명확화 (어떤 애플리케이션이 돌아가는지)
4. AI 엔진 SPOF 인지 + 개선 계획 (Auto Scaling, 헬스체크 등)

---

## 3. 기술 선택 타당성

### 잘 정리된 기술

- WAF 룰셋 우선순위: Priority 0(AI 차단) → 1(Geo) → 2~4(Managed Rules) → 5(IP Reputation) 순서와 각 룰의 역할/근거가 체계적
- tfsec: Shift-Left 보안 스캔으로 71개 블록 검사, 23개 취약점(Critical 4건) 사전 식별

### 근거가 부족한 기술

| 기술 | 현재 상태 | 필요한 보완 |
| --- | --- | --- |
| Isolation Forest | "비지도 학습으로 이상 탐지"만 기술 | 학습 데이터(건수, 피처), 하이퍼파라미터(contamination, n_estimators), 평가(Precision/Recall), 대안 비교(Autoencoder, One-Class SVM) |
| Athena | 사용 사실만 기술 | 왜 Athena인가? OpenSearch, CloudWatch Logs Insights 대비 장점 (서버리스, 비용, S3 직접 쿼리) |
| EventBridge + Lambda | 사용 사실만 기술 | Step Functions 대비 선택 근거 |
| Grafana | 사용 사실만 기술 | CloudWatch Dashboard 대비 선택 근거 |
| tfsec | 사용 사실만 기술 | Checkov, Terrascan 대비 선택 근거 |

### 개선 액션

1. **[최우선]** Isolation Forest 모델 상세 섹션 추가
    - 학습 데이터: 정상 트래픽 기준선을 어떻게 잡았는지 (몇 건, 어떤 피처)
    - 하이퍼파라미터: contamination, n_estimators 값과 설정 근거
    - 평가: 테스트 공격 데이터로 Precision/Recall 측정 결과
    - 한계: 어떤 공격은 잡고, 어떤 공격은 못 잡는지
2. 나머지 기술 각각 선택 근거 추가 (아래 기술별 개선 방향 참조)
3. WAF 룰 개선 과정을 "의사결정 과정" 형태로 서술 (기존 문제 → 분석 → 개선)

### 기술별 구체적 개선 방향

**Isolation Forest (가장 급함)**

현재 README: "비지도 학습(Isolation Forest) AI 모델을 결합한 실시간 이상 징후 탐지"
→ 이것만으로는 "scikit-learn import해서 fit() 호출한 것"으로 보일 수 있음

README에 추가해야 할 내용:

| 항목 | 추가할 내용 |
| --- | --- |
| 왜 Isolation Forest인가? | Autoencoder(학습 데이터 대량 필요, 튜닝 어려움), One-Class SVM(대규모 데이터에서 느림) 대비 → WAF 로그는 레이블 없는 비정형 데이터이므로 비지도 학습 적합, 그 중 학습 속도 빠르고 실시간 스코어링에 유리한 IF 선택 |
| 학습 데이터 | 정상 트래픽 X건 (Y일간 수집), 피처: 요청 빈도/URI 엔트로피/User-Agent 다양성/응답 코드 분포/페이로드 길이 등 N개 |
| 하이퍼파라미터 | n_estimators=100, contamination=0.05 (정상 대비 5% 이상치 가정), max_samples='auto' + 각 값의 설정 근거 |
| 평가 결과 | 테스트 공격 데이터(SQLi/XSS/Bot) Y건으로 Precision/Recall/F1 측정 |
| 한계 인정 | 어떤 공격은 잡고, 어떤 공격은 못 잡는지 정직하게 기술 |

**Athena**

| 대안 | 비교 | Athena 선택 이유 |
| --- | --- | --- |
| OpenSearch | 실시간 검색/분석에 강함 | 클러스터 운영 비용 높음 (최소 3노드). 배치 분석에는 과도함 |
| CloudWatch Logs Insights | 설정 간편 | 복잡한 JOIN/집계 쿼리 제한. WAF 로그 다차원 분석에 부적합 |
| Athena | S3 직접 쿼리, 서버리스, 스캔량 기반 과금 | ✅ WAF 로그가 이미 S3에 저장되므로 추가 데이터 이동 불필요. 비용 최적화 |

→ 다만 실시간 분석이 아닌 배치 분석이라는 한계는 인지하고 "준실시간"으로 표현 수정 필요

**EventBridge + Lambda**

| 대안 | 비교 | 선택 이유 |
| --- | --- | --- |
| Step Functions | 복잡한 워크플로우 오케스트레이션 | "이벤트 → 단일 액션(IP 차단)" 구조라 오케스트레이션 불필요 |
| SNS + Lambda | 단순 팬아웃 | EventBridge가 이벤트 필터링/라우팅에 더 유연 |
| EventBridge + Lambda | 이벤트 기반 트리거, 서버리스, 필터링 유연 | ✅ AI 탐지 결과를 이벤트로 받아 즉시 WAF IP Set 업데이트 |

→ Lambda 콜드 스타트(~1초)를 감안해도 차단 지연이 허용 범위 내

**Grafana**

| 대안 | 비교 | 선택 이유 |
| --- | --- | --- |
| CloudWatch Dashboard | AWS 네이티브, 설정 간편 | 커스텀 시각화 제한. 보안 관제용 복합 대시보드 구성 어려움 |
| Kibana (OpenSearch) | 로그 분석에 특화 | OpenSearch 클러스터 필요 → 비용/운영 부담 |
| Grafana | 다양한 데이터소스 연동, 커스텀 패널, 알람 유연 | ✅ CloudWatch + Athena + 커스텀 메트릭을 하나의 대시보드에 통합 가능 |

→ 보안 관제 대시보드는 WAF 메트릭 + AI 분석 결과 + 로그 분석을 한 화면에 보여줘야 하므로, 다중 데이터소스 지원이 핵심

**tfsec**

| 대안 | 비교 | 선택 이유 |
| --- | --- | --- |
| Checkov | 다중 프레임워크 지원 (Terraform, CloudFormation, K8s) | 범용적이지만 Terraform 특화 룰이 tfsec보다 적음 |
| Terrascan | OPA 기반 정책 엔진 | 커스텀 정책 작성에 강하지만 초기 설정 복잡 |
| tfsec | Terraform 전용, 빠른 스캔, AWS 특화 룰 풍부 | ✅ Terraform + AWS 단일 스택이므로 가장 적합 |

→ 향후 K8s 매니페스트 스캔이 필요하면 Checkov 추가 도입 고려

**Terraform**

현재: "Full Automation: 모든 리소스를 Terraform 모듈로 구성"이라고만 기술
→ 인프라 직무 지원 시 이 부분이 핵심 질문 대상

추가해야 할 내용:

- 모듈 구조: VPC / EKS / WAF / Lambda / Monitoring 등 기능별 분리 여부
- State 관리: S3 백엔드 + DynamoDB Lock 사용 여부 (로컬이면 개선 필요)
- 변수 설계: 환경별(dev/staging/prod) 분리 가능한 구조인지
- 버전 관리: provider/module 버전 고정 여부

**EKS**

현재: Tech Stack에 "Amazon EKS"가 있지만, 아키텍처에서 EKS의 역할이 불명확
→ 면접에서 "EKS를 왜 썼나요? 없어도 되는 거 아닌가요?"라는 질문이 나올 수 있음

추가해야 할 내용:

- EKS에서 어떤 워크로드가 실행되는지 (웹 애플리케이션? AI 엔진? 모니터링?)
- 노드 그룹 구성 (인스턴스 타입, 노드 수, Spot/On-Demand)
- Pod 보안 (IRSA, NetworkPolicy, SecurityContext)
- EKS가 실제로 필요한 이유를 명확히 하거나, 필요 없다면 Tech Stack에서 제거하는 게 나음

---

---

## 4. 보안

### 적용된 보안 항목

- [x]  WAF v2: 5단계 우선순위 룰셋 설계
- [x]  암호화(저장 시): KMS 암호화 적용
- [x]  IaC 보안 스캔: tfsec으로 23개 취약점 사전 식별
- [x]  비용 거버넌스: Budget 설정

### 미적용/미흡 항목

- [ ]  IAM 최소 권한: Lambda, EC2, Athena 각각의 IAM Role/Policy 설계 문서 없음
- [ ]  네트워크 보안: SG 규칙, NACL, VPC Flow Logs 문서화 없음
- [ ]  Secret 관리: AWS 자격증명, API 키 관리 방식 미기술
- [ ]  암호화(전송 중): TLS/HTTPS 적용 여부 미기술
- [ ]  감사 로깅: CloudTrail, S3 액세스 로깅 활성화 여부 미기술
- [ ]  K8s RBAC: EKS 내 RBAC 설정 미기술
- [ ]  IRSA/Pod Identity: Pod 레벨 IAM 미기술
- [ ]  컴플라이언스: ISMS-P 매핑 커밋은 있으나 README 미반영
- [ ]  인시던트 대응: Playbook, 포렌식 절차 없음
- [ ]  런타임 보안: GuardDuty, Inspector 미적용

### 개선 액션

**[멘토 의견] 보안 직무 지원 포트폴리오에서 IAM, 네트워크 보안, 감사 로깅은 최소한 있어야 합니다. 인프라 직무로 전환하더라도 이 3가지는 기본으로 물어보는 영역이니 반드시 정리하시는 게 좋을 것 같습니다. 이미 구성한 것을 "왜 이렇게 설계했는지" 문서화하는 수준이라 난이도가 낮습니다.**

보안 엔지니어 채용에서 보는 6대 영역:

| # | 영역 | 현재 상태 |
| --- | --- | --- |
| 1 | 접근 제어 (IAM, RBAC) | ❌ 없음 |
| 2 | 네트워크 보안 (SG, NACL, VPC 설계) | ❌ 없음 |
| 3 | 데이터 보호 (암호화, Secret 관리) | △ KMS만 |
| 4 | 탐지/대응 (WAF, IDS/IPS, SOAR) | ✅ 이것만 있음 |
| 5 | 감사/컴플라이언스 (CloudTrail, ISMS-P) | ❌ 없음 |
| 6 | 취약점 관리 (코드 스캔, 런타임 스캔) | △ tfsec만 |

→ 6개 중 4번만 있고 나머지가 비어 있는 상태. 1, 2, 5번을 추가하는 게 가장 임팩트가 큼.

1. **[최우선]** IAM 설계 문서화: Lambda/EC2/Athena 각각의 IAM Role과 Policy 정리, 최소 권한 적용 과정
2. **[최우선]** 네트워크 보안 문서화: SG 인바운드/아웃바운드 규칙 표, Subnet 배치 근거
3. **[최우선]** 감사 로깅: CloudTrail 활성화 여부, VPC Flow Logs, S3 액세스 로깅
4. ISMS-P 매핑 README 반영 (커밋에 이미 있으니 정리만)
5. 인시던트 대응 Playbook 최소 1개 작성

---

## 5. 자동화 (IaC & CI/CD)

### 현재 자동화 수준

- Terraform으로 VPC, EKS, WAF, Lambda 등 전체 인프라 코드화 (Full Automation)
- tfsec으로 배포 전 보안 스캔 (71개 블록 검사, 23개 취약점 식별)

### 부족한 부분

- CI/CD 보안 게이트가 tfsec 하나뿐 (DevSecOps 타이틀에 비해 부족)
- `lambda_functions.zip`이 레포에 직접 올라가 있음 (빌드 산출물이 소스 관리에 포함)
- Terraform 모듈 구조/변수 설계 문서화 없음
- Terraform state 관리 방식(S3 + DynamoDB 백엔드 여부) 미기술
- WAF 룰 변경 시 롤백 절차 미정의
- 배포 전략(Rolling/Blue-Green/Canary) 미기술

### 개선 액션

1. CI/CD에 보안 게이트 1개 이상 추가 (Trivy 컨테이너 스캔, Bandit Python SAST 등)
2. `lambda_functions.zip` 레포에서 제거 → CI 빌드 단계에서 생성하도록 변경
3. Terraform 모듈 구조 + state 관리 방식 문서화
4. WAF 룰 변경 시 롤백 절차 정의

---

## 6. 운영 관점 (모니터링/로깅)

### 구성된 항목

- Grafana 대시보드: AI 분석 결과 기반 인프라 상태 시각화 (Normal/Preparing/Blocked/Stabilize 4단계)
- WAF 로그 → S3 → Athena 분석 파이프라인
- Slack 알림 (위협 탐지 시)
- 시연 영상 존재

### 미구성 항목

- 인프라 메트릭 (CPU, Memory, Disk, Network) 수집/시각화 여부 불명확
- K8s 메트릭 (Pod 상태, Node 상태, HPA) 미기술
- 보안 관제 메트릭 상세 부족 (아래 참조)
- 알람 심각도 분류 (Critical/Warning/Info) 없음
- 로그 보관 정책 (S3 Lifecycle) 없음
- 장애 대응 체계 (Runbook, 에스컬레이션) 없음

### 개선 액션

**[멘토 의견] 아래 중 최소 4~5개는 있으면 좋을 것 같습니다.**

추가해야 할 보안 관제 메트릭:

1. WAF 룰별 차단 건수 (시간대별 추이)
2. 공격 유형 분포 (SQLi / XSS / Bot / Geo 등 비율)
3. AI anomaly score 분포 (정상/이상 경계값 시각화)
4. 오탐률(False Positive Rate) 추이
5. 국가별/IP 대역별 트래픽 히트맵
6. 탐지 → 차단까지 소요 시간(MTTD/MTTR)

추가 액션:

- 알람을 Critical/Warning/Info로 분류
- S3 로그 Lifecycle 정책 정의 (예: 30일 Standard → 90일 IA → 365일 Glacier)

---

## 7. 트러블슈팅 경험

### 현재 사례 평가

| # | 사례 | 평가 | 보안 관련성 |
| --- | --- | --- | --- |
| 1 | KMS 비용 급증 ($30/일) | △ 디버깅 과정 보강하면 살릴 수 있음 | ✅ |
| 2 | CloudWatch 한글 지표명 ASCII 에러 | ✖ 단순 코딩 이슈, 보안/인프라와 무관 | ❌ |
| 3 | WSL 8GB RAM 프리징 | ✖ 로컬 환경 이슈, 보안/인프라와 무관 | ❌ |
| 4 | tfsec 보안 취약점 23개 식별 | △ 트러블슈팅보다는 프로세스 도입 사례 | ✅ |

### 개선 액션

**[멘토 의견] KMS 사례는 디버깅 과정을 보강하면 좋은 사례가 될 수 있습니다. 2, 3번은 보안/인프라 직무와 관련이 낮으니 교체를 권장합니다.**

1. KMS 사례 보강:
    - 현재: "KMS 키 설정 오류 → 불필요한 키 정리"
    - 보강: "Cost Explorer에서 KMS 비용 급증 확인 → CloudTrail에서 KMS API 과도 호출 서비스 추적 → 원인: Terraform에서 리소스마다 개별 KMS 키 생성 → 공유 키 구조로 변경 → $30/일 → $X/일 절감 → 재발 방지: KMS 키 생성 정책 표준화"
2. 교체 권장 사례:
    - WAF 오탐: 정상 트래픽이 Managed Rule에 걸린 경우 → WAF 로그에서 terminatingRuleId 확인 → 정상 패턴 검증 → Scope-down Statement으로 예외 처리
    - IAM 권한 이슈: Lambda가 WAF IP Set 업데이트 실패 → CloudWatch Logs에서 AccessDenied 확인 → IAM Policy 최소 권한 재설계
3. 모든 사례에 실제 사용한 명령어/도구 명시 (aws ce get-cost-and-usage, CloudTrail 로그 쿼리, WAF 로그 Athena 쿼리 등)
4. 모든 사례에 "재발 방지 조치" 추가

## 우선순위 TOP 3 개선 항목

---

| 순위 | 항목 | 이유 | 난이도 |
| --- | --- | --- | --- |
| 1 | IAM + 네트워크 보안 + 감사 로깅 문서화 | 보안/인프라 양쪽 직무 모두 기본으로 물어보는 영역. 이미 구성한 것을 문서화하는 수준 | 낮음 |
| 2 | AI 모델 평가 (학습 데이터, 파라미터, Precision/Recall) | 프로젝트 차별점인 AI의 신뢰성 증명. 없으면 "라이브러리 갖다 쓴 것"으로 보임 | 중간 |
| 3 | 트러블슈팅 사례 교체 (WSL/ASCII → WAF 오탐/IAM 이슈) | 면접에서 가장 많이 물어보는 영역. 보안 관련 사례가 없으면 경험이 안 드러남 | 중간 |

---

## 면접 예상 질문 5개

**Q1. "Isolation Forest의 contamination 파라미터는 어떻게 설정했고, 오탐률은 얼마인가요?"**
→ 모범 답변 방향: 학습 데이터 X건 기준, contamination=0.05로 설정. 테스트 공격 데이터 Y건으로 평가한 결과 Precision X%, Recall Y%. 오탐 사례는 주로 ~한 패턴이었고, 피처 추가로 개선 중.

**Q2. "S3 + Athena 기반인데 실시간 탐지라고 할 수 있나요? 실제 소요 시간은?"**
→ 모범 답변 방향: 정확히는 준실시간(Near Real-Time). S3 적재 → Athena 쿼리 → AI 분석 → Lambda 차단까지 약 X분 소요. Kinesis Data Firehose를 사용하면 더 줄일 수 있지만, 비용 대비 현재 수준이 적절하다고 판단.

**Q3. "이 프로젝트에서 IAM 정책은 어떻게 설계했나요? 최소 권한 원칙을 어떻게 적용했나요?"**
→ 모범 답변 방향: Lambda는 WAF IP Set 업데이트 + S3 읽기 + CloudWatch 로그 쓰기만 허용. EC2(AI 엔진)는 S3 읽기 + CloudWatch Metrics 쓰기만 허용. 와일드카드(*) 대신 리소스 ARN을 특정하여 범위 제한.

**Q4. "WAF Managed Rule이 정상 트래픽을 차단한 적이 있나요? 어떻게 대응했나요?"**
→ 모범 답변 방향: SQLi 룰이 특정 검색 쿼리를 오탐한 사례 있음. WAF 로그에서 terminatingRuleId 확인 → 정상 패턴 검증 → Scope-down Statement 적용 → 오탐 해소.

**Q5. "인프라 직무로 전환한다면, 이 프로젝트에서 어떤 부분을 강조하시겠어요?"**
→ 모범 답변 방향: Terraform IaC로 전체 인프라 코드화, VPC/Subnet/SG 네트워크 설계, EKS 클러스터 구성, S3+Athena 데이터 파이프라인. 보안 자동화는 "인프라 위에 올린 부가가치"로 포지셔닝.

---

## 멘토 총평

**[멘토 의견]**

WAF 룰셋 우선순위 설계와 Prevention/Detection/Response 3계층 아키텍처는 이 포트폴리오에서 가장 잘 정리된 부분인 것 같습니다. Terraform IaC로 전체 인프라를 코드화한 것도 좋고, tfsec으로 Shift-Left 보안을 적용한 점도 방향이 맞습니다.

현 시점에서 가장 부족한 부분은 **보안의 폭**입니다. 현재는 "WAF + AI 탐지"라는 한 축만 다루고 있는데, 보안 엔지니어는 IAM 설계, 네트워크 격리, 감사 로깅, 암호화 정책, 컴플라이언스, 인시던트 대응까지 전체를 다뤄야 합니다. IAM + 네트워크 보안 + 감사 로깅 3가지만 추가해도 포트폴리오의 보안 깊이가 확 달라질 것 같습니다. 이 3가지는 이미 구성한 것을 "왜 이렇게 설계했는지" 문서화하는 수준이라 난이도가 낮습니다.

AI 부분은 Isolation Forest를 사용했다는 것까지는 좋은데, 모델 평가(Precision/Recall), 하이퍼파라미터 튜닝, 학습 데이터 구성이 없으면 "라이브러리를 갖다 쓴 것"으로 보일 수 있습니다. 보안 AI를 차별점으로 내세우려면 이 부분이 반드시 있어야 할 것 같습니다.

"실시간"이라는 표현은 재검토가 필요합니다. S3 + Athena 기반 파이프라인은 구조적으로 실시간이 아니기 때문에, "준실시간(Near Real-Time)" 또는 실제 측정한 지연 시간을 명시하는 게 기술 이해도를 보여주는 데 더 좋을 것 같습니다.

트러블슈팅 사례 중 WSL 프리징, ASCII 에러는 보안/인프라 직무와 관련이 낮으니, WAF 오탐 튜닝이나 IAM 권한 이슈 같은 실제 보안 관련 사례로 교체하면 훨씬 좋을 것 같습니다.

인프라 직무도 고려 중이시라면, 같은 프로젝트를 두 가지 관점으로 설명할 수 있도록 준비하시는 게 좋을 것 같습니다:

- 보안 직무: WAF 룰셋, AI 탐지, SOAR, IAM/감사/컴플라이언스 강조
- 인프라 직무: Terraform IaC, VPC/EKS 구축, 데이터 파이프라인, 모니터링 강조

어느 쪽이든 IAM + 네트워크 보안 + 감사 로깅 문서화는 공통으로 필요하니, 이걸 먼저 정리하시면 양쪽 직무 모두에 대응할 수 있을 것 같습니다.