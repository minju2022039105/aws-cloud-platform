# 🛡️ Cloud-Native WAF AIOps Platform
> **Terraform 기반 IaC와 비지도 학습(Isolation Forest) AI 모델을 결합한 실시간 이상 징후 탐지 및 보안 자동화(SOAR) 플랫폼**

---

## 1. 프로젝트 개요 (Executive Summary)
본 프로젝트는 AWS WAF의 정적 규칙(Static Rule)이 가진 한계를 극복하기 위해 **비지도 학습 기반 AI 분석 엔진**을 결합한 지능형 보안 운영 체계입니다. 단순히 인프라 구축에 그치지 않고, **전체 인프라를 Terraform(IaC)으로 구현**하여 수동 설정 없이 즉시 재현 가능한 가용성을 확보하였습니다. 특히 보안 엔지니어링 관점에서 비용 최적화와 심층 방어 체계를 구축하는 데 집중했습니다.

---

## 2. 시스템 아키텍처 (Architecture)
보안 계층(Prevention, Detection, Response)을 명확히 분리하고 데이터 흐름을 최적화한 3-Tier 기반 아키텍처입니다.

<img width="2043" height="518" alt="AWS AIOps Security Architecture" src="https://github.com/user-attachments/assets/a5c144c7-ed15-40cc-9bcd-7c15b4d2de2e" />

### **계층별 핵심 역할**
* **Prevention Layer**: CloudFront와 ALB 전면에 **AWS WAF v2**를 배치하여 1차 방어선을 구축하고, 모든 트래픽 로그를 S3로 실시간 Export합니다.
* **Detection Layer**: **Amazon Athena**를 통해 S3의 대용량 로그를 쿼리하고, **EC2(Isolation Forest)** 엔진에서 비지도 학습을 통해 이상 징후(Zero-day 공격 등)를 탐지합니다.
* **Response Layer**: 위협 식별 시 **EventBridge → Lambda**가 트리거되어 WAF의 IP Set을 업데이트함으로써 공격지를 즉각 차단(Automated IP Block)하고 Slack으로 알림을 전송합니다.

---

## 3. 핵심 기술 역량 (Technical Highlights)

### ** 전략적 보안 룰셋 설계 (WAF Priority)**
비용 최적화와 탐지 정밀도를 위해 WAF 우선순위를 다음과 같이 체계적으로 설계했습니다.

| 우선순위 | 규칙명 | 역할 및 엔지니어링 근거 |
| :--- | :--- | :--- |
| **Priority 0** | **AI-RealTime-Block** | **가장 중요**: AI 엔진이 실시간으로 식별한 위협 IP를 즉각 차단하여 변칙적인 공격에 유연하게 대응합니다. |
| **Priority 1** | **Geo-Blocking (KR)** | **비용 최적화**: 한국 외 IP를 입구에서 차단하여 분석 엔진(Athena/EC2)의 로그 처리 부하 및 비용을 획기적으로 줄입니다. |
| **Priority 2-4** | **AWS Managed Rules** | **패턴 방어**: SQLi, XSS 등 알려진 패턴 공격을 AWS Managed 룰셋으로 정밀 방어합니다. |
| **Priority 5** | **IP Reputation List** | **보수적 방어**: 이미 평판이 나쁜 IP들을 차단하여 전체적인 보안 안정성을 높입니다. |

### ** Infrastructure as Code (Terraform)**
* **Full Automation**: VPC, EKS, WAF, Lambda 등 모든 리소스를 **Terraform 모듈**로 구성하여 인프라의 일관성을 유지합니다.
* **Security Shift-Left**: 배포 전 **tfsec**을 활용하여 코드 레벨에서 23개의 보안 취약점(Critical 4건 포함)을 선제적으로 식별하고 개선했습니다.

---

## 4. 실시간 AIOps 관제 (Observability)
AI 분석 결과에 따라 인프라 상태를 정의하고 이를 Grafana 대시보드에 시각화하여 운영 가시성을 확보했습니다.

<img width="1024" alt="Grafana Dashboard" src="https://github.com/user-attachments/assets/e2ba077a-a9ac-410c-b7ed-78760ecac001">

* **Normal (초록)**: 평상시 정상 모니터링 상태.
* **Preparing (주황)**: 위협 점수 상승에 따른 선제적 방어 준비.
* **Blocked (빨강)**: 실시간 위협 확정 및 WAF를 통한 즉각적인 **IP 차단** 실행.
* **Stabilize (파랑)**: 공격 종료 후 시스템 복구 및 잔류 위협 집중 감시.

---

## 5. 트러블슈팅 (Troubleshooting Deep Dive)

### **1) 클라우드 비용 거버넌스 및 KMS 최적화**
* **문제**: KMS 키 설정 오류로 인해 하루 만에 비용이 $30로 급증하는 이슈 발생.
* **해결**: 불필요한 키 리소스를 정리하고, 모든 인프라를 즉시 삭제/재구성할 수 있도록 **Terraform 코드 정비**를 완료하여 클라우드 비용 거버넌스를 강화했습니다.

### **2) 데이터 파이프라인 규격 이슈 (ASCII 제한)**
* **문제**: CloudWatch Metrics 지표명에 한글 사용 시 AWS API 에러 발생.
* **해결**: Python 코드 내 Rule Map을 영문 표준 명칭으로 변경하여 인프라 안정성을 확보했습니다.

### **3) 자원 제한 환경에서의 로컬 최적화**
* **문제**: 8GB RAM 환경에서 WSL 및 도커 구동 시 프리징 현상 발생.
* **해결**: `.wslconfig` 설정을 통해 자원 할당량을 제어하고 가상 디스크 압축을 통해 개발 환경을 최적화했습니다.

### **4) IaC 코드 스캔을 통한 보안 취약점 사전 제거**
* **문제**: 인프라 배포 후 수동 점검 시 S3 퍼블릭 액세스 설정이나 암호화 미비 등의 실수 가능성 존재.
* **해결**: CI/CD 파이프라인에 **tfsec**을 도입하여 71개의 블록을 검사, 23개의 잠재적 위협을 배포 전에 차단했습니다.

---

## 6. Tech Stack
* **Compute**: Amazon EKS, Amazon EC2, AWS Lambda
* **Networking & Security**: AWS WAF v2, CloudFront, ALB, VPC
* **Data & AI**: Amazon S3 (Partitioned), Amazon Athena, Scikit-learn (Isolation Forest)
* **Infrastructure**: Terraform, AWS CLI, tfsec

---
**[📺 프로젝트 실시간 시연 영상 보러가기](https://www.youtube.com/watch?v=rIG2oWAm2Bo)**
