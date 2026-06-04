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
- [ ] Athena 기반 패널: 공격 유형 분포(Pie), 국가별 차단(Geomap), 공격 IP Top10(Table)
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

