# SOAR 파이프라인 + AI 대시보드 아키텍처

> 작성일: 2026-05-19  
> 상태: **완성 (end-to-end 검증 완료)**

---

## 전체 파이프라인

```
┌─────────────────────────────────────────────────────────────┐
│                        로컬 (WSL)                            │
│                                                              │
│  monitor.py                                                  │
│  ├── Isolation Forest 모델 로드 (ai/models/*.pkl)            │
│  ├── WAF 로그 CSV 샘플링 → 이상 점수 계산                    │
│  ├── 시나리오 모드: NORMAL / PREDICT / PREMITIGATE /         │
│  │                  ATTACK_ATTEMPT / STABILIZE               │
│  └── S3 업로드: results/year=Y/month=M/day=D/aiops_*.json   │
└──────────────────────────┬──────────────────────────────────┘
                           │ S3 ObjectCreated 이벤트
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    AWS (us-east-1)                           │
│                                                              │
│  S3: aws-waf-logs-minju-0417-project                        │
│  └── results/year=.../month=.../day=.../aiops_*.json        │
│       ↓ ObjectCreated 트리거 (prefix: results/, suffix: .json)│
│                                                              │
│  Lambda: SecurityAnalyzer                                    │
│  ├── Athena 쿼리: aiops_results 테이블에서 anomaly=1 IP 추출 │
│  └── SecurityPreventer Lambda 호출 (IP, risk, level 전달)   │
│       ↓                                                      │
│  Lambda: SecurityPreventer                                   │
│  ├── WAF IP Set (devsecops-ai-block-list) 업데이트           │
│  └── CloudWatch 메트릭 기록                                  │
│       Namespace: AIOps/Security                              │
│       Metric: DefenseSignal                                  │
│       Dimension: AttackIP={ip}                               │
│       ↓                                                      │
│  WAF: devsecops-waf                                          │
│  └── Priority 1 — AI IP Set 룰로 해당 IP 차단               │
└─────────────────────────────────────────────────────────────┘
```

---

## 데이터 소스별 Athena 테이블

| 테이블 | S3 경로 | 용도 |
|--------|---------|------|
| `default.aiops_results` | `results/year=.../month=.../day=.../` | SOAR — anomaly=1 IP 추출 |
| `default.model_metrics` | `model-metrics/` | AI 대시보드 — 모델 성능 지표 |
| `default.waf_logs` | `AWSLogs/.../WAFLogs/` | WAF 대시보드 — 공격 현황 |

---

## Grafana AI 대시보드 구성

### 데이터 소스
- **Athena**: `default.model_metrics`, `default.aiops_results`
- **CloudWatch**: Namespace `AIOps/Security`, Metric `DefenseSignal`

### 패널 레이아웃

```
┌──────────┬──────────┬──────────┬──────────┐
│Precision │  Recall  │ F1 Score │   FPR    │
│  30.6%   │  100.0%  │  46.84%  │  16.2%   │
├──────────┴──────────┼──────────┴──────────┤
│  WAF 단독 탐지       │ AI 추가 탐지 후보   │
│     100건           │      227건          │
├─────────────────────┴─────────────────────┤
│          WAF+AI 탐지 합계 327건 (+227%)    │
├───────────────────────────────────────────┤
│     WAF 단독 vs WAF+AI 비교 (Bar chart)   │
├───────────────────────────────────────────┤
│       TP/FP/FN/TN 분포 (Pie chart)        │
├───────────────────────────────────────────┤
│    AI 실시간 차단 이벤트 (CloudWatch TS)   │
└───────────────────────────────────────────┘
```

### 핵심 쿼리

**AI 추가 탐지 후보 (eval_model_v2.py 평가 기준 FP)**
```sql
SELECT fp AS value FROM default.model_metrics
```

**SOAR 파이프라인 처리 IP 수 (준실시간 모니터링)**
```sql
SELECT COUNT(DISTINCT ip) AS value
FROM default.aiops_results
WHERE "anomaly" = 1
```

**모델 성능 지표**
```sql
SELECT precision * 100 AS value FROM default.model_metrics;
SELECT recall * 100 AS value FROM default.model_metrics;
SELECT f1_score * 100 AS value FROM default.model_metrics;
SELECT fpr * 100 AS value FROM default.model_metrics;
```

---

## IAM 권한 구성

| 역할 | 권한 | 용도 |
|------|------|------|
| `devsecops-lambda-blocker-role` | `wafv2:GetIPSet`, `wafv2:UpdateIPSet` | IP Set 차단 |
| `devsecops-lambda-blocker-role` | `cloudwatch:PutMetricData` | 메트릭 기록 |
| `devsecops-lambda-blocker-role` | `s3:GetObject` (results/*) | AI 결과 읽기 |

---

## Terraform 모듈 참조 구조

```hcl
# IP Set ID를 하드코딩 없이 모듈 출력으로 참조
resource "aws_lambda_function" "preventer" {
  environment {
    variables = {
      IP_SET_ID   = module.security.ai_block_list_id
      IP_SET_NAME = module.security.ai_block_list_name
    }
  }
}

# IAM 정책의 WAF ARN도 모듈 직접 참조
waf_ipset_arn = module.security.ai_block_list_arn
```

WAF 모듈 재생성 시 IP Set ID가 바뀌어도 환경변수가 자동 갱신됨.

---

## 한계 및 향후 개선 방향

- `monitor.py`는 실시간 탐지가 아닌 시뮬레이션 스크립트 — 실제 스트리밍 탐지는 Kinesis/Firehose 연동 필요
- AI 모델 평가 지표(Precision 30.6%, Recall 100%, FP 227건)는 WAF 룰 기반 레이블을 정답으로 사용 — 실제 공격 레이블과 다를 수 있음
- CloudWatch 패널: AttackIP 차원별 다중 라인 이슈 → 집계 방식 개선 필요
