## [260519] AI 탐지 패널 추가 시도 — Prometheus 실패 → S3/Athena 전환

---

### 작업 내용

**Grafana Bar chart alias 한글화**
- `terminatingruleid` 컬럼을 SQL `CASE WHEN`으로 한글 변환
  - `AWS-AWSManagedRulesAmazonIpReputationList` → `IP 평판 차단`
  - `AWS-AWSManagedRulesSQLiRuleSet` → `SQL Injection 차단`
- Override "Fields with name"은 컬럼명 기준이라 값(행 데이터) 변환 불가 → SQL에서 처리해야 함

---

### 트러블슈팅 — Prometheus → Grafana Cloud 연결 불가

**시도**: monitor.py 실행(`:8000` exporter) → Prometheus 서버(`:9090`) → Grafana Cloud 데이터소스 연결

**문제**:
- Grafana Cloud(grafana.net)는 클라우드 서버에 있고, Prometheus 서버는 로컬 WSL에 있음
- Grafana Cloud에서 `http://localhost:9090` 입력 시 Access Denied — 인터넷에서 로컬 localhost에 접근 불가

**구조**:
```
monitor.py exporter :8000
        ↓ scrape
Prometheus server :9090   ← WSL 로컬
        ↓ (연결 불가 — 인터넷 격리)
Grafana Cloud (grafana.net)
```

**해결책 후보**:
- ngrok 터널: 임시 외부 URL 생성 가능하나 데모용으로 불안정
- Grafana Alloy: 로컬 메트릭을 Grafana Cloud로 push하는 공식 방법이나 설정 복잡

**결정**: Prometheus 방향 포기. monitor.py가 이미 S3에 결과 JSON을 적재하고 있으므로 **S3 → Athena** 방식으로 전환

**정리**:
- `prometheus-3.4.0.linux-amd64/` 바이너리 삭제
- `prometheus-3.4.0.linux-amd64.tar.gz` 삭제

---

### AI 대시보드 방향 재확정

**monitor.py 완전 폐기 결정**
- monitor.py는 데모 연출용 시뮬레이션 스크립트 — 실제 WAF 탐지 데이터 아님
- Prometheus 연결 불가 + 데이터 신뢰성 문제 두 가지 이유로 포기
- 대신 `eval_model_v2.py` 실제 평가 결과 기반으로 AI 대시보드 구성

**eval_model_v2.py 결과 확인** (`ai/results/performance_metrics_v2.json`)
- Precision: 57.97% / Recall: 50% / F1: 0.54 / FPR: 10.4%
- WAF 단독 탐지: 400건 → WAF+AI: 545건 (+36.3%)
- AI 추가 탐지 후보: 145건 (레이블 없는 ALLOW 트래픽 — "공격 확정" 아닌 "이상 징후 후보"로 표현)

**AI 대시보드 패널 구성 확정**
```
[1행] KPI Stat × 4
Precision | Recall | F1 Score | FPR

[2행] 탐지 범위 Stat × 3
WAF 단독 탐지(400건) | AI 추가 탐지 후보(145건) | WAF+AI 합계(545건 +36.3%)

[3행] Bar chart
WAF 단독 vs WAF+AI 비교

[4행] Pie chart
전체 1,800건 구성 — 정상(TN 1,255) / AI 추가 탐지 후보(FP 145) / 공통 탐지(TP 200) / 미탐지(FN 200)
```

**Federated Learning 대시보드 제외 결정**
- 현재 메시지("WAF + AI 이상탐지 보조")와 맞지 않아 메시지 분산
- README 및 Velog "향후 개선 방향"으로만 언급

---

### 초기 계획 대비 달라진 것 정리

| 항목 | 초기 계획 | 현재 |
|------|-----------|------|
| 인프라 | WAF → ALB → EC2 | WAF → API Gateway → Lambda |
| AI 엔진 위치 | EC2 실시간 탐지 | 로컬 평가만 수행 |
| 모니터링 | Prometheus → 로컬 Grafana | Grafana Cloud + Athena |
| AI 대시보드 | 실시간 위험도 시각화 | 정적 eval 결과 KPI |
| 표현 | "실시간 AI 탐지" | "준실시간 AI 보조 탐지" |

스코프는 줄었으나 실제 WAF 로그 기반 검증 수치 확보, AI 한계 정직하게 표현 — 포트폴리오 신뢰도는 오히려 향상.

---

### SOAR 파이프라인 복구 및 완성

**배경**: SecurityAnalyzer Lambda가 `aiops_results` Athena 테이블을 참조하는데 테이블이 없어서 파이프라인 전체가 끊겨 있었음. Athena 테이블 생성으로 복구.

**Athena `aiops_results` 테이블 생성**
- S3 경로: `s3://aws-waf-logs-minju-0417-project/results/year=.../month=.../day=.../aiops_*.json`
- JsonSerDe + 파티션(year/month/day) 구조로 생성
- `MSCK REPAIR TABLE` 후 데이터 확인 완료

---

### 트러블슈팅 — SOAR IP 차단 안 됨 (3연속)

**① WAF IP Set ID 불일치**

| 구분 | 값 |
|------|-----|
| 코드 하드코딩 ID | `266e5501-31b8-46ca-b3eb-3a58c28c51f7` (구버전) |
| 실제 AWS IP Set ID | `d061410e-3732-4d5e-8234-c9cc9e163b43` |

**원인**: WAF 모듈 destroy → apply 시 IP Set이 재생성되면서 ID 변경. Lambda 코드는 구 ID 그대로.
**수정**:
- `lambda_security_preventer.py`: 하드코딩 → `os.environ.get("IP_SET_ID")` 환경변수 방식으로 변경
- `lambda.tf`: `IP_SET_ID = module.security.ai_block_list_id` 환경변수 주입
- `modules/waf/outputs.tf`: `ai_block_list_id`, `ai_block_list_name`, `ai_block_list_arn` output 추가
- `main.tf`: `waf_ipset_arn = var.waf_ipset_arn` → `waf_ipset_arn = module.security.ai_block_list_arn` (직접 참조)
- `variables.tf` + `terraform.tfvars`: `waf_ipset_arn` 하드코딩 변수 제거

**② import os 누락**

`os.environ.get()` 사용하도록 코드 수정 시 `import os` 추가 안 해서 Lambda 콜드 스타트 시 `NameError` 발생.
```
[ERROR] NameError: name 'os' is not defined
```
→ `import os` 추가 후 재배포.

**③ IAM 권한 부족 (2개)**

| 권한 | 증상 |
|------|------|
| `wafv2:GetIPSet` | AccessDeniedException — IAM 정책에 구 IP Set ARN 하드코딩 |
| `cloudwatch:PutMetricData` | AccessDenied — 정책에 CloudWatch 권한 없음 |

**수정**:
- `terraform.tfvars`의 `waf_ipset_arn` → 신규 ARN으로 교체 후 `module.security` 직접 참조로 전환
- `modules/vpc/main.tf` IAM 정책에 `cloudwatch:PutMetricData` 추가

---

### 최종 결과 — SOAR 파이프라인 완성 ✅

```
monitor.py (AI 위험도 탐지)
    ↓ S3 업로드 (results/*.json)
S3 ObjectCreated 트리거
    ↓
SecurityAnalyzer Lambda (Athena aiops_results 쿼리)
    ↓ anomaly=1 IP 추출
SecurityPreventer Lambda
    ↓
WAF IP Set 차단 ✅ + CloudWatch AIOps/Security 메트릭 ✅
```

**검증**: WAF `devsecops-ai-block-list` IP Set에 실제 IP 추가 확인

---

### 내일 할 일

- [x] Grafana AI 대시보드 신규 생성 (CloudWatch `AIOps/Security` DefenseSignal + eval_model_v2 KPI)
- [ ] Time series 패널 레이아웃 조정 (기존 WAF 대시보드)
- [ ] Velog 4편 본문 작성

---

### Grafana AI 대시보드 완성

**패널 구성 완료**

| 행 | 패널 | 데이터 소스 | 값 |
|----|------|------------|-----|
| 1 | Precision | Athena `model_metrics` | 57.97% |
| 1 | Recall | Athena `model_metrics` | 50.0% |
| 1 | F1 Score | Athena `model_metrics` | 53.69% |
| 1 | FPR (오탐률) | Athena `model_metrics` | 10.36% |
| 2 | WAF 단독 탐지 | Athena `aiops_results` | 400건 |
| 2 | AI 추가 탐지 후보 | Athena `aiops_results` | 146건 |
| 2 | WAF+AI 탐지 합계 | Athena `model_metrics` | 545건 |
| 3 | WAF 단독 vs WAF+AI | Athena `model_metrics` | Bar chart |
| 4 | TP/FP/FN/TN 분포 | Athena `model_metrics` | Pie chart |
| - | AI 실시간 차단 이벤트 | CloudWatch AIOps/Security | Time series |

**Athena `model_metrics` 테이블 생성**
- S3 경로: `s3://aws-waf-logs-minju-0417-project/model-metrics/`
- 파일: `performance_metrics_v2_flat.json` (단일라인 JSON — JsonSerDe 파싱용)
- 기존 `performance_metrics_v2.json`은 pretty-printed 멀티라인이라 Athena 파싱 불가 → flat 버전 신규 생성

**트러블슈팅 — Athena `anomaly` 예약어 충돌**
```sql
-- 오류: mismatched input '='
WHERE anomaly = 1

-- 수정: 예약어는 큰따옴표로 감쌈
WHERE "anomaly" = 1
```

---

### SOAR 파이프라인 최종 확정

```
monitor.py (AI 위험도 탐지 + S3 업로드)
    ↓ results/year=.../month=.../day=.../aiops_*.json
S3 ObjectCreated 트리거 (prefix: results/, suffix: .json)
    ↓
SecurityAnalyzer Lambda
    ↓ Athena aiops_results 쿼리 (anomaly=1 IP 추출)
SecurityPreventer Lambda
    ↓
WAF IP Set 차단 ✅ + CloudWatch AIOps/Security 메트릭 기록 ✅
```

전체 파이프라인 end-to-end 검증 완료.
