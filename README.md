# 🛡️ Cloud-Native WAF AIOps Platform
**Terraform 기반 IaC와 Isolation Forest AI 모델을 결합한 실시간 이상 징후 탐지 및 보안 자동화 플랫폼**

## 1. 프로젝트 문제 정의 (Problem Definition)
* **기존 방식의 한계**: AWS WAF의 정적 규칙(Static Rule)만으로는 고도화된 지능형 위협 및 변칙적인 이상 트래픽을 식별하는 데 한계가 있음.
* **해결 방안**: 비지도 학습 모델인 **Isolation Forest**를 도입하여 실시간으로 이상 점수를 산출하고, 위협에 유연하게 대응하는 지능형 보안 운영(AIOps) 체계 구축.
* **기술적 목표**: 인프라의 코드화(IaC), 배포 자동화(CI/CD), 그리고 데이터 기반의 보안 분석(AIOps)을 통합적으로 구현.

---

## 2. 아키텍처 설계 (Architecture & Data Flow)
인프라와 애플리케이션 계층을 분리한 **Modular Monorepo** 구조
<img width="1645" height="434" alt="스크린샷 2026-03-23 230920" src="https://github.com/user-attachments/assets/c649dfcf-fc63-4919-a1de-d57db4e2e953" />

* **네트워크 설계**: Public/Private Subnet 분리 및 us-east-1a, 1b 멀티 가용 영역(AZ) 구성을 통해 고가용성 확보.
* **Traffic Flow**: WAF 로그 수집 → EC2 내 AI 분석 엔진 구동 → 이상 점수 산출 → S3 로그 적재 및 메트릭 전송.
* **Storage**: Athena 쿼리 최적화를 위해 연/월/일 기반의 **S3 파티셔닝 적재 구조** 채택.
* **Response**: S3에 분석 결과 업로드 시 `SecurityAnalyzer` Lambda가 즉시 탐지하여 대응 신호를 발생시킴.

---

## 3. 기술 선택 타당성 (Tech Stack)
| 분류 | 기술 | 선택 근거 및 대안 비교 |
| :--- | :--- | :--- |
| **IaC** | **Terraform** | 수동 설정의 휴먼 에러를 방지하고, 모듈화를 통해 리소스 재사용성 및 정합성 확보. |
| **AI Model** | **Isolation Forest** | 라벨링되지 않은 보안 로그에서 이상 징후를 탐지하기 위한 최적의 비지도 학습 알고리즘. |
| **Analysis** | **Athena & Lambda** | S3의 대용량 로그에서 필요한 이상 데이터만 초고속으로 쿼리하여 서버리스 환경에서 분석 수행. |
| **Cost** | **S3 Gateway Endpoint** | NAT Gateway 사용 시 발생하는 월 약 $32의 고정 비용을 $0로 절감. |

---

## 4. 보안 (Security Hardening)
본 프로젝트는 **'보안 시프트 레프트(Shift-Left)'** 원칙에 따라 배포 전 단계에서 laC 취약점을 선제적으로 점검합니다.

<img width="444" height="574" alt="스크린샷 2026-03-23 233017" src="https://github.com/user-attachments/assets/2f44b736-61f0-428c-a757-58729664c0b1" />

* **최소 권한 원칙 (PoLP)**: IAM 전용 Role 구성 및 특정 람다 함수 호출 권한을 명시적으로 제한하여 보안성 강화.
* **보안 그룹(SG) 정밀 설계**: SSH(22번) 및 Grafana(3000번) 포트 허용 범위를 **관리자 전용 공인 IP(49.143.64.148/32)**로 엄격히 제한.
* **보안 스캐닝 (Shift-Left)**: 배포 전 **tfsec**을 활용해 코드 레벨의 취약점(IAM 와일드카드, EBS 암호화 미비 등)을 선제적으로 식별.
* **Secret 관리**: `.gitignore` 설정을 통해 `.pem`, `tfstate` 등 민감 데이터의 저장소 노출을 원천 차단.
* **기본 리소스 통제**: VPC 생성 시 자동 생성되는 `default` 보안 그룹을 테라폼 리소스로 관리하여 모든 규칙을 제거(Deny All) 처리함.

---

## 5. 자동화 (IaC & CI/CD)
<img width="865" height="622" alt="스크린샷 2026-03-23 231014" src="https://github.com/user-attachments/assets/e70a3d5a-c602-48f7-8d4f-4d6b602f8cee" />


* **Modular IaC**: `vpc/`, `waf/`, `alb/`, `iam/`, `ec2/` 각 리소스별 독립 모듈화를 통해 관리 편의성 증대.
* **Idempotent Pipeline**: 배포 스크립트 내 예외 처리(`|| true`)를 도입하여 멱등성 있는 안정적인 CI/CD 파이프라인 완성.
* **CD 정합성**: `source_code_hash` 속성을 사용하여 코드 수정 시 즉시 AWS 반영이 이루어지는 자동 배포 체계 구축.

---

## 6. 운영 관점 (Monitoring & Logging)
<img width="1894" height="905" alt="스크린샷 2026-03-23 233337" src="https://github.com/user-attachments/assets/6974779f-78aa-4cdc-ae7d-5d01d5e75d49" />
* **실시간 가시성**: `SecurityAnalyzer` Lambda의 인바운드 로그 이벤트를 시각화하여 시스템 가동 상태 증명.
* **Custom Metrics**: CloudWatch에 `AIOps/Security` 전용 공간을 생성하여 공격 유형별 지표를 기록.
* **Athena Insight**: 비지도 학습 모델의 이상 탐지 결과(`anomaly=1`)를 Athena로 조회하여 실시간 위협 가시화.
    * ![Athena Results](./images/스크린샷 2026-03-23 002934.png)

---

## 7. 트러블슈팅 경험 (Troubleshooting Deep Dive)
### 1) Terraform State 충돌 및 리소스 정합성 문제
* **문제**: 이전 배포 실패로 남은 '유령 리소스'와 로컬 State 파일 간의 장부 불일치로 리소스 생성 충돌 발생.
* **해결**: AWS CLI를 통한 수동 강제 삭제와 함께, 하위 모듈에서 개별 실행하던 환경을 **루트(terraform/) 폴더로 강제 통합**하여 해결.
* **교훈**: 테라폼 모듈 환경에서는 반드시 단일 루트에서 실행해야 하며, 수동 조작 시 State 파일과의 동기화가 필수적임을 인지함.

### 2) AWS API 규격(non-ASCII) 제한 이슈
* **문제**: CloudWatch Metrics 지표명에 한글을 사용하여 AWS API가 거부하는 `InvalidParameterValue` 발생.
* **해결**: Python 코드 내 리소스 맵을 표준 ASCII 기반 영문 명칭(SQLI, BruteForce 등)으로 변경하여 인프라 안정화.

### 3) CI/CD 프로세스 영속성 및 멱등성 확보
* **문제**: GitHub Actions SSH 세션 종료 시 분석 프로세스가 중단되거나, 기존 프로세스 종료 단계에서 대상이 없을 경우 파이프라인이 실패하는 현상.
* **해결**: `setsid`를 통한 프로세스 분리 및 배포 스크립트 내 예외 처리 도입으로 해결.

---
