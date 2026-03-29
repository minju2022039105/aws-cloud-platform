# 🛡️ Cloud-Native WAF AIOps Platform
> **Terraform 기반 IaC와 Isolation Forest AI 모델을 결합한 실시간 이상 징후 탐지 및 보안 자동화(SOAR) 플랫폼**
---

## 1. 프로젝트 문제 정의 (Problem Definition)
* **기존 방식의 한계**: AWS WAF의 정적 규칙(Static Rule)만으로는 고도화된 지능형 위협 및 변칙적인 이상 트래픽(Zero-day 공격 등)을 식별하는 데 한계가 있음.
* **기술 과제로의 전환**: 비지도 학습 모델인 **Isolation Forest**를 도입하여 라벨링되지 않은 로그에서 실시간 이상 점수를 산출하고, 위협 수준에 따라 인프라 모드를 동적으로 전환하는 **지능형 보안 운영(AIOps)** 체계를 구축함.

---

## 2. 실시간 AIOps 관제 (Real-time Observability)
본 프로젝트의 핵심은 AI 분석 결과가 **인프라의 상태(Mode) 변화**로 직결되고, 이를 운영자가 즉각 파악할 수 있는 실시간 대시보드를 구축한 점입니다.

### 🎥 프로젝트 실시간 시연 영상 (YouTube)
[![AIOps 프로젝트 시연 영상](http://img.youtube.com/vi/rIG2oWAm2Bo/0.jpg)](https://www.youtube.com/watch?v=rIG2oWAm2Bo)
 
 *이미지를 클릭하면 유튜브 시연 영상으로 연결됩니다.*

### **분석 모드별 동적 대응 매커니즘**
* **정상 모니터링 (Normal)**: AI 분석 결과 이상 징후가 없는 평시 상태 (초록색).
* **안정화 단계 (Stabilize)**: 공격 종료 후 시스템 복구 및 잔류 위협 집중 모니터링 (파란색).
* **공격 차단 중 (Blocked)**: 실시간 위협 확정 및 WAF를 통한 즉각적인 IP 차단 실행 (빨간색).
* **방어 준비 (Preparing)**: 위협 점수 상승에 따른 선제적 방어 준비 단계 (주황색).

---

## 3. 아키텍처 설계 (Architecture & Data Flow)
인프라와 애플리케이션 계층을 분리한 **Modular Monorepo** 구조를 지향하며, 데이터의 흐름은 다음과 같습니다.
<img width="1024" height="559" alt="image" src="https://github.com/user-attachments/assets/e4f77d34-7b90-4bb0-bdaa-07c877af41b3" />



* **Traffic Flow**: WAF Logs → S3 (Partitioned) → **Amazon Athena** → **AI Engine (EC2)** → **AWS Lambda (Response)**.
* **Storage Strategy**: Athena 쿼리 성능 최적화를 위해 연/월/일 기반의 **S3 파티셔닝 적재 구조** 채택.
* **High Availability**: `us-east-1` 리전 내 Multi-AZ 구성을 통해 단일 장애점(SPOF) 제거 및 가용성 확보.

---

## 4. 기술 선택 타당성 (Tech Stack Choice)
| 분류 | 기술 | 선택 근거 및 대안 비교 |
| :--- | :--- | :--- |
| **IaC** | **Terraform** | 수동 설정의 휴먼 에러를 방지하고, 모듈화를 통해 리소스 재사용성 및 정합성 확보. |
| **AI Model** | **Isolation Forest** | 8GB RAM 환경에서 대규모 라벨 데이터 없이도 이상치를 효율적으로 탐지하는 비지도 학습 알고리즘. |
| **Analysis** | **Athena & Lambda** | S3의 대용량 로그에서 필요한 데이터만 서버리스 환경에서 초고속으로 분석 수행 (Cost-Effective). |
| **Cost Opt** | **S3 Gateway EP** | NAT Gateway($32/월) 대비 **$0** 비용으로 프라이빗 서브넷 내 S3 보안 통신 구현. |

---

## 5. 보안 (Security Hardening)
* **최소 권한 원칙 (PoLP)**: IAM 전용 Role 구성 및 람다 간 호출 권한(`lambda:InvokeFunction`)을 명시적으로 제한.
* **보안 그룹(SG) 정밀 설계**: SSH(22번) 및 관제 포트 허용 범위를 **관리자 전용 공인 IP(/32)**로 엄격히 제한.
* **보안 시프트 레프트(Shift-Left)**: 배포 전 **tfsec**을 활용해 코드 레벨 취약점(S3 퍼블릭 액세스, 암호화 미비 등)을 선제적 식별.
* **Secret 관리**: `.gitignore` 설정을 통해 `.pem`, `tfstate` 등 민감 데이터의 저장소 노출 원천 차단.

---

## 6. 자동화 및 운영 (Automation & Operations)
* **Modular IaC**: `vpc/`, `waf/`, `ec2/` 등 각 리소스별 독립 모듈화를 통해 관리 편의성 증대.
* **Idempotent Pipeline**: 배포 스크립트 내 예외 처리(`|| true`)를 도입하여 안정적인 CI/CD 파이프라인 완성.
* **Local Optimization**: 8GB RAM 환경 프리징 방지를 위해 `.wslconfig`로 WSL 메모리를 2GB로 제어 및 가상 디스크 압축.

---

## 7. 트러블슈팅 경험 (Troubleshooting Deep Dive)

### **1) Terraform State 충돌 및 Ghost Resource 해결**
* **문제**: 이전 배포 실패로 남은 리소스와 로컬 State 파일 간 불일치로 리소스 중복 생성 에러 발생.
* **해결**: AWS CLI를 통한 잔여 리소스 수동 강제 삭제 후, 실행 환경을 **루트(terraform/) 폴더로 단일화**하여 해결.
* **교훈**: 테라폼 모듈 환경에서는 단일 루트 실행 원칙과 State 파일 동기화의 중요성을 인지함.

### **2) AWS API 규격(non-ASCII) 제한 이슈**
* **문제**: CloudWatch Metrics 지표명에 한글 사용 시 `InvalidParameterValue` 에러 발생.
* **원인**: AWS API가 한글 등 non-ASCII 문자를 거부하는 데이터 표준 규격을 따르고 있었음.
* **해결**: Python 코드 내 RULE MAP을 영문 표준 명칭(SQLI, BruteForce 등)으로 변경하여 인프라 안정화.

### **3) Grafana Stat 패널의 비수치(String) 데이터 시각화**
* **문제**: `STABILIZE` 등 텍스트 기반 상태값이 `No data`로 출력되는 현상.
* **해결**: 쿼리 필드 타입을 강제 지정하고, Grafana의 `Fields` 설정을 `All Fields`로 변경하여 **한/영 병기 텍스트 매핑** 구현.

---
