# 260430-1) 기존 데이터셋 고도화 & AWS WAF 로깅 및 데이터 수집 검증

## 1. 개요 (오늘 할 일 / 목표)
*   **AWS WAF 탐지 로그의 S3 적재**: WAF에서 발생하는 보안 이벤트를 분석하기 위해 S3 버킷으로의 로깅 파이프라인 구축
*   **KMS CMK 암호화 적용**: 데이터 보안 및 컴플라이언스 준수를 위해 KMS 고객 관리형 키를 이용한 로그 암호화 구현
*   **위협 데이터셋 확보**: Nikto 모의 공격 도구를 활용하여 설정된 보안 규칙의 작동 여부를 검증하고 AI 모델 학습용 데이터 수집

## 2. 환경 정보
*   **OS**: Windows 11 + Ubuntu (WSL)
*   **IaC Tool**: Terraform (v1.x)
*   **Cloud**: AWS (Region: **us-east-1**, N. Virginia)
*   **Architecture**: WAF v2, S3 (Logging Bucket), KMS (CMK), ALB, Nikto (Scanner)

## 3. 작업 절차 (Step by Step)
1.  **WAF 로깅 전용 S3 및 KMS 생성**: 로그 보관을 위한 버킷 생성 및 전용 암호화 키 정의
2.  **보안 계층(Web ACL) 설계**: Geo-Blocking(KR), Managed Rule Set(SQLi, Common), IP Reputation 등 4단계 필터링 적용
3.  **로깅 필터 최적화**: 불필요한 정상 로그를 제외하고 `BLOCK` 처리된 위협 데이터 위주로 수집하도록 필터링 설정
4.  **서비스 간 권한 교정**: WAF 서비스 주체가 KMS 열쇠와 S3 창고에 접근할 수 있도록 IAM 및 Resource Policy 수정
5.  **공격 재현 및 데이터 검증**: Nikto를 통한 취약점 스캔을 실시하여 S3 내 실제 로그 파일 적재 확인

## 4. 문제/오류 & 해결 기록

| 구분 | 증상 | 원인 | 조치 |
| :--- | :--- | :--- | :--- |
| **KMS** | WAF 로깅 활성화 상태이나 S3에 로그 미생성 | KMS Key Policy에 WAF 로깅 서비스 권한 누락 | `image_e45e13.png`와 같이 `delivery.logs.amazonaws.com` 서비스 주체 허용 구문 추가 |
| **S3** | `AWSLogs/` 상위 폴더 자체가 생성되지 않음 | S3 버킷 정책에서 WAF의 `PutObject` 권한 거부 | `bucket-owner-full-control` 조건을 포함한 S3 Bucket Policy 적용 |
| **WAF** | 공격 시도에도 S3 로그 파일이 생성되지 않음 | 로깅 필터의 액션 조건(`COUNT`)과 실제 차단 액션(`BLOCK`) 불일치 | `image_e46161.png`와 같이 조건을 `BLOCK`으로 수정하여 데이터 정합성 확보 |
| **Time** | 설정 완료 직후 로그 확인 불가 | AWS WAF 로그의 S3 배달 지연 (최대 5~15분) | UTC 시간대별 폴더(`14/`, `15/`) 모니터링 및 대기 시간 확보 |

## 5. 테스트 방법 및 증적 (Verification)

### ① S3 객체 생성 확인 (로깅 성공)
*   **검증 내용**: `aws-waf-logs-minju-0417-project` 버킷 내 실시간 로그 적재 여부 확인
*   **결과**: UTC 기준 `15/` 폴더 내에 `.log.gz` 형식의 위협 데이터 파일 생성 확인
*   **참조 파일**: <img width="685" height="591" alt="스크린샷 2026-05-01 002406" src="https://github.com/user-attachments/assets/c72e99a4-7cc0-4dbb-b278-14d442bbb22c" />

### ② Nikto 공격 패턴 탐지
*   **검증 내용**: ALB DNS를 대상으로 취약점 스캔 실행 및 WAF 탐지 여부 확인
*   **결과**: `/administrator`, `config.php`, `.mdb` 등 비정상적인 경로 접근 시도가 성공적으로 차단 및 기록됨
*   **참조 파일**: 
<img width="1659" height="609" alt="스크린샷 2026-04-30 234410" src="https://github.com/user-attachments/assets/5beac725-f566-4e4c-ab0f-21aae56a638d" />
<img width="644" height="369" alt="스크린샷 2026-04-30 235255" src="https://github.com/user-attachments/assets/109e587e-695f-4f92-948a-56ff74b73d4e" />

## 6. Technical Insight: 실시간 위협 데이터셋 고도화
기존 `monitor.py`에서 사용하던 정적 샘플 데이터를 버리고, AWS WAF 실시간 로그를 수집하도록 인프라를 개선한 기술적 이유는 다음과 같습니다.

*   **데이터의 정합성 확보**: 내 인프라(Virginia Region)의 정책과 지리적 특성(Geo-Blocking)이 반영된 실데이터를 통해 모델의 환경 적합성을 향상시킵니다.
*   **모델 평가 지표의 신뢰성**: 직접 유발한 공격(Ground Truth)을 학습시킴으로써, Isolation Forest 모델의 Precision(정밀도)과 Recall(재현율)을 실제 운영 환경에 맞춰 산출할 수 있습니다.
*   **SOAR 파이프라인 검증**: 실제 WAF 로그 형식을 활용해야만 "탐지 → Lambda 트리거 → IP Set 차단"으로 이어지는 자동 대응 성능(MTTR) 측정의 실효성이 확보됩니다.

## 7. 향후 추진 계획: 4단계 고도화 로드맵

### **1단계: 모델 평가 체계 구축 (신뢰성 확보)**
*   수집된 정상/공격 로그를 활용한 정답지(Ground Truth) 생성 및 오탐(False Positive) 분석
*   scikit-learn 기반 Precision/Recall 산출 및 하이브리드 탐지(AI + WAF Rule) 필요성 증명

### **2단계: 엔진 환경 표준화 (Docker 이식)**
*   Library(numpy, pandas) 의존성 문제 해결을 위한 Docker 컨테이너화
*   WSL 및 AWS 환경 어디서든 동일하게 작동하도록 인프라 격리 및 IaC(Terraform) 반영

### **3단계: 자동 탐지 및 대응(SOAR) 파이프라인 완성**
*   AI 엔진 탐지 시 Lambda를 트리거하여 WAF v2 IP Set 즉시 업데이트(Block) 로직 고도화
*   위협 심각도 분류 및 공격 발생부터 차단까지의 소요 시간(MTTR) 측정

### **4단계: 실데이터 관제 대시보드 연동 (가시성 확보)**
*   React-DynamoDB 연동을 통한 보안 메트릭 시각화 (차단 IP 히트맵, 시간대별 공격 분포 등)
*   API 호출 오류 방지를 위한 IAM 정책 및 CORS 설정 최적화 검토

---

## 8. 작업 완료 항목
*   [x] KMS CMK 기반 WAF 로깅 암호화 구성 완료
*   [x] S3 버킷 정책 및 서비스 주체(Service Principal) 권한 교정 완료
*   [x] 4계층 WAF 보안 규칙(Geo-Blocking 등) 배포 및 검증 완료
*   [x] Nikto 활용 위협 데이터셋 확보 및 S3 적재 성공
