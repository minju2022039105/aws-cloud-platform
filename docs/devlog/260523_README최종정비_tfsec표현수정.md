# [260523] README 최종 정비 + tfsec 표현 수정 + AI 성능 표현 완화

---

## 1. tfsec 표현 정리 (README + Velog 3편)

### 배경

README와 Velog 3편에서 tfsec이 CI 자동 Security Gate에 포함된 것처럼 표현되어 있었음.
실제로는 CI 파이프라인 포함을 시도했으나 워크플로우 안정성 문제로 제외, 로컬 수동 점검 용도로만 사용했음.

### README 수정

- 상단 subtitle: `tfsec Security Gate` → `Security Gates (Trivy + Bandit)`
- Project Overview CI/CD 흐름: `→ tfsec →` → `→ Trivy + Bandit →`
- 파이프라인 다이어그램: Security Gates에서 `tfsec Terraform 정적 분석` 라인 제거
- Section 3 재구성:
  - `## 3. Security Gates (tfsec)` → `## 3. Security Gates`
  - `### Automated Security Gates (CI)`: Trivy IaC + Bandit Python 표로 정리
  - `### Manual IaC Security Audit: tfsec`: 별도 소제목으로 분리, 수동 점검 도구임을 명시
  - 기존 `tfsec-action@v1.0.0` YAML 스니펫 삭제 (실제 워크플로우에 없음)
  - Medium/Low 건수: `CI 제외 (--minimum-severity HIGH)` → `설계 의도 확인 후 수용`

### Velog 3편 수정

- 파일명: `03_Terraform-WAF-인프라-설계와-tfsec-보안-게이트.md` → `03_Terraform-WAF-인프라-설계와-tfsec-보안-점검.md`
- 섹션 제목: `tfsec — 배포 전에 Terraform 코드를 스캔한다` → `tfsec — Terraform 보안 취약점 수동 점검`
- 본문 도입부: `CI/CD 파이프라인에서 동일한 커버리지를 제공합니다` 삭제
  → CI 제외 이유(워크플로우 안정성)와 최종 자동화 기준(Trivy + Bandit)을 명시
- 이미지 캡션: `Security Gates(Trivy IaC + Bandit) / Terraform / Deploy Lambda` 로 수정

---

## 2. README 아키텍처 이미지 경로 수정

- 참조 경로: `devsecops-페이지-3.png` (존재하지 않는 파일)
- 실제 파일명: `최종아키텍처.png`
- 수정: `docs/architecture/최종아키텍처.png` 로 경로 교체

---

## 3. 블로그 시리즈 테이블 전면 정비

모든 편의 제목과 URL을 실제 Velog 발행 기준으로 교체.

| 편 | 수정 내용 |
|:---:|:---|
| 1~3편 | 링크 없음 → 실제 Velog URL 추가 |
| 2편 | 제목 교체 (`완벽한 WAF를...` → `보안은 배포 전에 시작된다: AWS DevSecOps CI/CD 설계기`) |
| 3, 4편 | URL 404 오류 → 실제 슬러그로 교체 |
| 5편 | KMS 기사로 잘못 연결되어 있었음 → SOAR 편으로 교체 |
| 6편 | SOAR 편으로 잘못 연결 → KMS 편으로 교체 (5↔6편 순서 반영) |

---

## 4. ChatGPT/Gemini 피드백 반영

| 항목 | 수정 전 | 수정 후 |
|:---|:---|:---|
| Observability | `Grafana Cloud + CloudWatch` | `+ Athena` 추가 |
| Prevention | `룰 4종` | `GeoBlock + Managed Rules + AI 기반 IP Set` |
| OIDC (IAM 섹션) | `StringLike + *` | `StringEquals + ref:refs/heads/main` |
| Before/After 표 | `탐지 범위 확대 +227%` | 표 구조 변경 — WAF 차단 / AI 이상 후보 / 총 검토 대상으로 분리 |
| Tech Stack | `Infrastructure` | `Infrastructure / CI/CD` + Trivy, Bandit 추가, tfsec (수동 점검) 명시 |
| Monitoring | `Grafana Cloud, CloudWatch, SNS` | `Athena` 추가 |

---

## 5. AI 성능 표현 추가 완화 (면접 대비)

| 위치 | 수정 전 | 수정 후 |
|:---|:---|:---|
| 모델 구성 표 | `이상 327건` | `이상 후보 327건` |
| 성능 평가 표 FPR | `227건 추가 탐지` | `227건을 이상 후보로 분류` |
| 성능 평가 표 처리 속도 | `실시간 처리 가능` | `모델 추론 연산 기준 — 실시간 처리 가능한 수준` |
| Tech Stack AI/ML | `Federated Learning` | `Weighted Federated Averaging (설계·실험)` |

---

## 6. Limitations / Future Work 섹션 추가 (Section 13)

면접 공격 예상 지점 5개를 선제적으로 명시:

- `monitor.py`: CSV 기반 시뮬레이션 입력 생성기 (실시간 WAF 로그 스트리밍 아님)
- Precision 30.6%: FP 후보는 운영자 검토 전제 (보수적 탐지 전략)
- Federated Learning: 단일 환경 설계·실험 단계
- Athena 기반 준실시간: Firehose 5~15분 버퍼 지연 (CloudWatch 1분 경로로 보완)
- 평가 데이터: SQLi 중심 제한적 시나리오 — 다양한 공격 유형 일반화 검증 필요

---

## 내일 할 일

- [ ] 기말 발표 PPT 작성 (6/10 발표, 주제: WAF 로그 기반 Isolation Forest 이상 탐지)
