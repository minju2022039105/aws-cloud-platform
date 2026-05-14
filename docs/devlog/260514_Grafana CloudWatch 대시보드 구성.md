## 8. [260514] Grafana CloudWatch 대시보드 구성

### 아키텍처 재결정

Grafana Cloud + Athena 연결 시도 중 문제 확인: Athena 데이터소스는 IAM Access Key가 필요한데, 현재 프로젝트는 GitHub Actions OIDC 기반으로 장기 자격증명을 제거한 구조다. Athena 때문에 Access Key를 추가하면 포트폴리오 메시지가 흐려진다고 판단, 운영 메트릭을 CloudWatch 중심으로 전환했다.

**최종 Observability 3계층 구조**:

```
[로컬 / 데모 계층]   monitor.py → Prometheus metrics (:8000)
[운영 계층]          WAF / Lambda / API Gateway → CloudWatch Metrics & Logs
[시각화 계층]         Grafana Cloud (devsecai.grafana.net) → CloudWatch datasource
```

**Prometheus 유지 결정**: monitor.py의 Prometheus 메트릭은 삭제하지 않았다. "Prometheus를 구현해봤지만 서버리스 환경에서는 pull 방식이 맞지 않아 CloudWatch로 전환했다"는 설명이 판단력을 보여준다.

**IAM user 예외**: `grafana-cloudwatch-readonly` (CloudWatchReadOnlyAccess) 생성. Terraform 관리 제외 — state 파일 보안 리스크 때문.

### 완료된 패널

| 패널 | Namespace | Metric | Visualization |
|---|---|---|---|
| Real-time WAF Attack Blocking Trend | `AWS/WAFV2` | `BlockedRequests` (Rule=ALL) | Time series |
| WAF Blocked Requests by Rule | `AWS/WAFV2` | `BlockedRequests` (룰 4개 분리) | Bar chart |

룰별 쿼리 분리: `awsCommonRules`, `awsReputationRules`, `awsSQLiRules`, `geoBlockNonKR`  
`geoBlockNonKR` 31건 차단 확인.

### 남은 작업

- [ ] Query alias/display name 정리
- [ ] Athena 기반 패널(공격 유형 분포, 국가별 차단, 공격 IP Top10) — Athena 데이터소스가 IAM Access Key 필요로 현재 보류. CloudWatch 기반 패널 우선 완성 후 재검토.
- [x] README 아키텍처 설명 업데이트 (260514 완료)

---

## 9. [260514] 디렉터리 구조 정리

### 배경

서버리스 전환 과정에서 `ai/`, `ai-security/`, `monitoring` 역할이 섞여 있었다.
Prometheus 실험 코드와 CloudWatch 운영 코드가 구분되지 않아 포트폴리오 가독성이 낮았다.

### 변경 내용

| 이동 전 | 이동 후 | 이유 |
|---|---|---|
| `ai/inference/monitor.py` | `monitoring/prometheus-demo/monitor.py` | 로컬 데모임을 구조에서 명확히 표현 |
| `ai-security/models/*.pkl` | `ai/models/` | ai/, ai-security/ 이원화 해소 |
| `ai-security/results/*` | `ai/results/` | 동일 이유 |
| `docs/etc/athena_waf_ddl.sql` | `monitoring/cloudwatch/` | 운영 observability 자산으로 분류 |
| 루트 `edge_security.zip` | 삭제 | lambda/edge_security/ 산출물과 중복 |

### 경로 수정 파일

- `monitoring/prometheus-demo/monitor.py` — CSV, MODEL, SCALER 경로 3개 수정
- `ai/training/train_model.py`, `benchmark.py` — 상대경로 `ai-security` → `ai`
- `ai/inference/eval_model.py`, `eval_visual.py`, `analyze_anomalies.py`, `export_model.py`, `check_model.py` — 절대경로 수정
- `.github/workflows/deploy.yml` — Bandit 스캔 경로에 `./monitoring` 추가

### 검증

- `terraform validate` 통과
- `ai-security/` 참조 잔존 없음 확인 후 디렉터리 삭제

### README 수정 (동시 진행)

- `[검토 중]` ALB+EC2 주석 제거 (서버리스 전환 완료)
- 학습 데이터 건수 1,800 → 1,750 수정
- Tech Stack EC2, ALB 제거
- 9절 프로젝트 구조 섹션 신규 추가

---

## 10. [260514] tfsec CI 제거

`tfsec-action@v1.0.0` 바이너리 설치 버그(`Is a directory`)로 Security Gates 단계 실패.  
파라미터 수정(`tfsec_args` → `additional_args`)으로도 해결 불가한 action 자체 결함.

tfsec은 aquasecurity 공식 deprecated → Trivy 통합 완료.  
이미 Trivy IaC Scan이 동일 커버리지를 제공하고 있어 tfsec 스텝 제거.  
tfsec 검증 자체는 260512에서 로컬 수동 실행으로 완료(Critical 0, High 0) 상태.

**Security Gates:** Trivy IaC + tfsec + Bandit → **Trivy IaC + Bandit**

Velog 3편 tfsec 섹션도 동일하게 수정 완료: "CI/CD 파이프라인 보안 게이트로 실행" → "로컬 수동 실행으로 검증, CI는 Trivy로 통합".

---

## 11. [260514] End-to-End 검증 완료

### 배경

인프라 구축, CI/CD, 모니터링 작업이 계속 확장되면서 정작 실제 트래픽을 흘려보는 검증이 뒤로 밀려 있었다. API Gateway, Lambda, WAF, CloudWatch, Grafana까지 모두 배포된 상태였지만 실제 요청을 보내본 적이 없었다.

### 문제 발견 및 수정

**NormalTrafficGenerator 엔드포인트 오류**  
`handler.py`의 `ALB_ENDPOINT`가 서버리스 전환 후에도 ALB 주소로 하드코딩되어 있었다.  
→ `TARGET_URL = "https://minju-devsec.store"` 로 교체, `traffic_generator.tf` 환경변수도 동일하게 수정.

**WAF GeoBlock 차단 문제**  
Lambda가 AWS us-east-1에서 실행되므로 미국 IP로 요청이 나가고, GeoBlock-Non-KR에 전량 차단됨.  
API Gateway 로그에서 모든 요청이 `status: 403`, `responseLength: 23`(`{"message":"Forbidden"}`)으로 확인.  
→ GeoBlock을 임시 COUNT 모드로 전환 후 테스트, 완료 후 BLOCK 모드 복귀.

### 검증 결과

```
NormalTrafficGenerator 실행: success 180, failed 0, total 180
실행 시간: 64초 (저녁 시간대 가중치 0.6 적용)
Grafana WAF AllowedRequests (Sum): 18 확인
  ※ CloudWatch WAF 메트릭은 1분 단위 집계. 64초 실행 구간이
     1분 버킷에 분산되어 Grafana 패널 표시 기준에 따라 18로 집계됨.
```

요청 → API Gateway → WAF → CloudWatch → Grafana 전체 흐름 정상 동작 확인.

### 현재 상태

- GeoBlock: BLOCK 모드 복귀 완료
- NormalTrafficGenerator: EventBridge 6시간 스케줄로 자동 실행 중
- Grafana: WAF 메트릭 실데이터 수신 확인

---

## 12. [260514] 트러블슈팅 모음

| # | 문제 | 원인 | 해결 |
|---|---|---|---|
| 1 | tfsec CI 단계 실패 — `Unexpected input 'tfsec_args'` | `tfsec-action@v1.0.0`에 존재하지 않는 파라미터 사용 | `tfsec_args` → `additional_args` 로 수정 |
| 2 | tfsec CI 단계 실패 — `tfsec: Is a directory` | `tfsec-action@v1.0.0` 바이너리 설치 버그. action 자체 결함으로 파라미터 수정으로 해결 불가 | tfsec deprecated 확인 후 스텝 제거, Trivy로 통합 |
| 3 | NormalTrafficGenerator 전송 실패 | 서버리스 전환 후에도 `ALB_ENDPOINT`가 삭제된 ALB 주소로 하드코딩되어 있었음 | `TARGET_URL = "https://minju-devsec.store"` 로 교체 |
| 4 | API Gateway 전체 요청 403 차단 | Lambda가 AWS us-east-1 IP로 요청 발송 → WAF GeoBlock-Non-KR에 전량 차단 | GeoBlock 임시 COUNT 모드 전환 → 테스트 완료 후 BLOCK 복귀 |
