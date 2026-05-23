
> 이 글은 AWS DevSecOps 플랫폼 구축기 시리즈의 5편입니다.  
> 4편: [WAF가 놓친 것을 AI가 잡는 법](https://velog.io/@yapp/WAF%EA%B0%80-%EB%86%93%EC%B9%9C-%EA%B2%83%EC%9D%84-AI%EA%B0%80-%EC%9E%A1%EB%8A%94-%EB%B2%95-Isolation-Forest-Shannon-Entropy-%EA%B7%B8%EB%A6%AC%EA%B3%A0-%EC%A0%95%EC%A7%81%ED%95%9C-%ED%95%9C%EA%B3%84)

---

4편에서 Isolation Forest 엔진을 만들고, IP Set에 차단 IP를 추가하는 흐름을 설계했습니다.

그런데 당시 파이프라인에 구멍이 있었습니다.

`SecurityAnalyzer` Lambda가 Athena 테이블(`aiops_results`)을 참조하는데, 그 테이블이 없었습니다. Lambda는 실행될 때마다 에러를 내고 있었고, 파이프라인 전체가 조용히 끊겨 있었습니다.

이 글은 그 구멍을 메우고, AI 평가 결과와 SOAR 차단 이벤트를 Grafana에서 확인할 수 있는 대시보드까지 완성한 과정입니다.

---

## 파이프라인이 끊겨 있었다

`monitor.py`가 S3에 결과를 올리면 Lambda가 트리거돼야 합니다. Lambda 로그를 확인했습니다.

```
[ERROR] ResourceNotFoundException: Table aiops_results not found in database default
```

`SecurityAnalyzer`가 Athena에 쿼리를 날리는데, 테이블 자체가 없었습니다. 처음 인프라를 설계할 때 Athena 테이블 생성을 빠뜨린 겁니다.

**Athena `aiops_results` 테이블 생성:**

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS default.aiops_results (
  event_time        STRING,
  mode              STRING,
  ip                STRING,
  pred_risk         DOUBLE,
  obs_risk          DOUBLE,
  premit_on         INT,
  mitigation_level  INT,
  anomaly           INT,
  raw_score         DOUBLE
)
PARTITIONED BY (year STRING, month STRING, day STRING)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
LOCATION 's3://aws-waf-logs-minju-0417-project/results/'
TBLPROPERTIES ('has_encrypted_data' = 'false');

MSCK REPAIR TABLE default.aiops_results;
```

테이블을 만들고 나서야 파이프라인이 움직이기 시작했습니다.

---

## WAF IP Set ID가 바뀌어 있었다

테이블 문제를 해결하니 이번엔 WAF 차단이 안 됐습니다. Lambda 로그를 다시 확인했습니다.

```
[ERROR] AccessDeniedException: User is not authorized to perform: wafv2:GetIPSet
on resource: arn:aws:wafv2:us-east-1:...:regional/ipset/.../266e5501-31b8-46ca-b3eb-...
```

코드에 하드코딩된 IP Set ID가 `266e5501-...`인데, 실제 AWS 콘솔의 IP Set ID는 `d061410e-...`였습니다.

원인은 Terraform이었습니다. WAF 모듈을 `destroy → apply`하면서 IP Set이 재생성됐고, ID가 바뀐 겁니다. Lambda 코드는 구버전 ID를 그대로 들고 있었습니다.

**하드코딩을 제거하고 Terraform 모듈 참조로 전환했습니다:**

```python
# 이전 — 하드코딩
IP_SET_ID = "266e5501-31b8-46ca-b3eb-3a58c28c51f7"

# 이후 — 환경변수
IP_SET_ID = os.environ.get("IP_SET_ID")
```

```hcl
# lambda.tf
resource "aws_lambda_function" "preventer" {
  environment {
    variables = {
      IP_SET_ID   = module.security.ai_block_list_id
      IP_SET_NAME = module.security.ai_block_list_name
    }
  }
}
```

이제 WAF 모듈이 재생성되어 ID가 바뀌어도 Terraform apply 한 번으로 Lambda 환경변수가 자동으로 갱신됩니다.

---

## IAM 권한이 두 곳에서 막혔다

IP Set 문제를 해결하니 또 에러가 났습니다.

```
[ERROR] AccessDenied: cloudwatch:PutMetricData
```

Lambda가 CloudWatch에 메트릭을 기록하는 권한이 없었습니다. IAM 정책에서 `cloudwatch:PutMetricData`가 빠져 있었던 겁니다.

Terraform으로 정책을 추가했습니다:

```hcl
{
  Sid    = "PutAIOpsMetrics"
  Effect = "Allow"
  Action = ["cloudwatch:PutMetricData"]
  Resource = "*"
}
```

정리하면 파이프라인을 완성하기까지 막힌 지점이 세 곳이었습니다.

| 순서 | 문제 | 원인 | 해결 |
|:---:|:---|:---|:---|
| 1 | Athena 테이블 없음 | 초기 설계 누락 | CREATE EXTERNAL TABLE |
| 2 | WAF IP Set ID 불일치 | 모듈 재생성으로 ID 변경 | 환경변수 + Terraform 모듈 참조 |
| 3 | CloudWatch 권한 없음 | IAM 정책 누락 | PutMetricData 추가 |

---

## 완성된 SOAR 파이프라인

```
monitor.py (AI 위험도 탐지)
    ↓ S3 업로드: results/year=Y/month=M/day=D/aiops_*.json

S3 ObjectCreated 트리거
    ↓ (prefix: results/, suffix: .json)

SecurityAnalyzer Lambda
    ↓ Athena aiops_results 쿼리 → anomaly=1 IP 추출
    ↓ SecurityPreventer Lambda 호출

SecurityPreventer Lambda
    ↓ WAF IP Set (devsecops-ai-block-list) 업데이트
    ↓ CloudWatch Namespace: AIOps/Security, Metric: DefenseSignal
```

콘솔에서 WAF `devsecops-ai-block-list` IP Set에 IP가 실제로 추가되는 것을 확인했습니다.

<!-- 사진: WAF IP Set 콘솔 — IP 추가 확인 -->
![](https://velog.velcdn.com/images/yapp/post/6c9ee737-3c65-4514-b24c-6a864c9a3690/image.png)

---

## AI 대시보드 설계 원칙 — 검증 가능한 데이터만 표시한다

파이프라인이 완성된 다음 단계는 대시보드였습니다.

초기에는 `monitor.py`의 Prometheus exporter(`:8000`)를 Grafana에 연결하려 했습니다. 문제가 있었습니다.

```
monitor.py exporter :8000
    ↓ scrape
Prometheus server :9090   ← WSL 로컬
    ↓ (연결 불가)
Grafana Cloud (grafana.net)
```

Grafana Cloud는 인터넷에 있고, Prometheus 서버는 로컬 WSL에 있습니다. `localhost:9090`은 인터넷에서 접근할 수 없습니다. ngrok 터널을 쓰면 가능하지만 데모용으로 불안정합니다.

더 큰 문제는 `monitor.py` 자체였습니다. 이 스크립트는 실제 WAF 탐지 데이터가 아닌 시뮬레이션 데이터를 생성합니다. 대시보드에서 "AI가 실시간으로 위험도를 계산하고 있다"고 보여줄 수는 있지만, 그 숫자들은 실제 로그에서 온 게 아닙니다.

포트폴리오에서 과장된 수치를 보여주는 것보다, 실제 데이터 기반으로 정직하게 구성하는 게 낫다고 판단했습니다.

**결정: Prometheus 방향 포기. S3 → Athena 기반으로 전환.**

다만 `monitor.py` 자체를 폐기하지는 않았습니다. 역할을 바꿔 계속 사용했습니다.

| 시점 | monitor.py 역할 |
|:---|:---|
| 변경 전 | Prometheus exporter — AI 탐지 결과를 `:8000`으로 노출, Grafana 실시간 시각화 |
| 변경 후 | SOAR 입력 생성기 — AI 탐지 결과를 S3 JSON으로 업로드, Athena `aiops_results` 적재 |

Prometheus exporter 코드(`:8000`)는 코드베이스에 남아 있지만, scrape하는 주체가 없어 실질적으로 비활성 상태입니다.

---

## 대시보드 데이터 소스 구성

AI 대시보드에 사용한 데이터 소스는 두 가지입니다.

**1) Athena `aiops_results`** — SOAR 파이프라인 실행 결과 (준실시간 모니터링)
```sql
-- SOAR 파이프라인이 실제로 처리한 anomaly=1 IP 수 (monitor.py 시뮬레이션 실행 기록)
SELECT COUNT(DISTINCT ip) AS value
FROM default.aiops_results
WHERE "anomaly" = 1
```

> `anomaly`는 Athena 예약어입니다. 큰따옴표 없이 쓰면 파싱 오류가 납니다.

**2) Athena `model_metrics`** — eval_model_v2.py 평가 결과

평가 지표(Precision/Recall/F1/FPR)는 모델을 재학습하기 전까지 고정값입니다. 이 값을 `performance_metrics_v2_flat.json`으로 S3에 올리고 Athena 테이블로 만들었습니다.

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS default.model_metrics (
  n_total       INT,
  n_attacks_waf INT,
  tp INT, fp INT, fn INT, tn INT,
  precision     DOUBLE,
  recall        DOUBLE,
  f1_score      DOUBLE,
  fpr           DOUBLE,
  ...
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://aws-waf-logs-minju-0417-project/model-metrics/'
```

대시보드의 "AI 추가 탐지 후보" 건수는 이 테이블의 `fp` 컬럼에서 가져옵니다.

```sql
-- AI 추가 탐지 후보: WAF ALLOW 트래픽 중 AI가 이상으로 분류한 건수 (eval_model_v2.py 평가 기준)
SELECT fp AS value FROM default.model_metrics
```

한 가지 주의: Athena의 JsonSerDe는 **파일을 한 줄씩 읽습니다.** pretty-printed JSON(들여쓰기 있는 멀티라인)은 파싱이 안 됩니다. 단일 라인으로 변환한 파일을 올려야 합니다.

---

## AI 대시보드 최종 구성

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
│    AI 기반 차단 이벤트 (CloudWatch TS)     │
└───────────────────────────────────────────┘
```

<!-- 사진: Grafana AI 대시보드 전체 스크린샷 -->
![](https://velog.velcdn.com/images/yapp/post/ad438e48-af90-4697-9cc3-eb2a6d543bbc/image.png)![](https://velog.velcdn.com/images/yapp/post/f8b86601-bace-4e44-8632-33d359e7b4da/image.png)


**수치 해석:**

- WAF SQLi 단독(100건) → WAF+AI(327건): 탐지 범위 **+227%**
- AI 추가 탐지 후보 227건: WAF가 ALLOW한 트래픽 중 AI가 이상 패턴으로 분류한 것
- Recall 100% / FN=0: SQLi 100건 전부 탐지, 미탐 없음
- Precision 30.6%: 비지도 이상 탐지 특성상 FP가 발생하는 구조 — FP 227건은 실제 공격 여부를 사람이 검토해야 함
- FPR 16.2%: 정상 트래픽 중 일부를 이상으로 잘못 분류한 비율

여기서 "AI 추가 탐지 후보"를 "AI가 탐지한 추가 공격"이라고 부르지 않은 데 이유가 있습니다.

WAF 레이블(`action=ALLOW`)을 정답으로 삼아 평가했기 때문에, WAF가 허용한 트래픽을 AI가 이상으로 분류했다는 것이 곧 "공격"이라는 뜻은 아닙니다. 오탐일 수도 있고, WAF 룰이 놓친 실제 공격일 수도 있습니다. 어느 쪽인지 사람이 검토해야 합니다.

---

## 마치며

이 프로젝트를 시작할 때 설계한 흐름은 이랬습니다.

```
EC2 실시간 탐지 → Prometheus → Grafana → WAF 차단
```

실제로 완성된 흐름은 이렇습니다.

```
monitor.py (시뮬레이션) → S3 → Lambda(Athena 조회) → WAF 차단
eval_model_v2.py 평가 결과 → S3 → Athena → Grafana (정적 KPI)
```

실시간 탐지는 준실시간이 됐고, Prometheus는 Athena로 바뀌었습니다. 스코프는 줄었습니다.

그렇지만 실제 WAF 로그 기반으로 수치를 검증했고, 파이프라인을 실제로 end-to-end로 동작시켰으며, 한계를 숨기지 않았습니다.

향후에는 `monitor.py` 대신 실제 WAF 로그를 Lambda 추론 입력으로 연결하고, 더 큰 운영 환경에서는 Kinesis Firehose나 SageMaker 엔드포인트로 확장할 수 있습니다.

---

