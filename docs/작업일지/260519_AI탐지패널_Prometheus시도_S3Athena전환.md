## [260519] AI 탐지 패널 전환 — Prometheus 실시간 구조 실패 → S3/Athena 기반 준실시간 SOAR 완성

---

### 작업 내용

**Grafana Bar chart alias 한글화**
- `terminatingruleid` 컬럼을 SQL `CASE WHEN`으로 한글 변환
  - `AWS-AWSManagedRulesAmazonIpReputationList` → `IP 평판 차단`
  - `AWS-AWSManagedRulesSQLiRuleSet` → `SQL Injection 차단`
- Grafana Override의 "Fields with name"은 컬럼명 기준이라 행 데이터 값 변환 불가
- 따라서 값 변환은 Grafana 설정이 아니라 SQL 쿼리 단계에서 처리해야 함

---

## 배경 — monitor.py 기반 실시간 시각화 시도

260513~260518 동안 `monitor.py` 기반 Prometheus 시각화를 계속 시도했다.

초기 목표는 다음과 같았다.

```text
monitor.py
→ Prometheus exporter (:8000)
→ Prometheus server (:9090)
→ Grafana Cloud
→ AI 실시간 탐지 패널
```

`monitor.py`는 처음에는 AI 탐지 결과를 Prometheus 메트릭으로 노출하고, Grafana에서 실시간 위험도·이상 점수·탐지 상태를 보여주는 용도로 설계했다.

---

## 트러블슈팅 — Prometheus → Grafana Cloud 연결 불가

### 시도한 구조

```text
monitor.py exporter :8000
        ↓ scrape
Prometheus server :9090   ← WSL 로컬
        ↓
Grafana Cloud (grafana.net)
```

### 문제

- Grafana Cloud는 외부 클라우드 서비스
- Prometheus 서버는 로컬 WSL 내부 `localhost:9090`
- Grafana Cloud에서 `http://localhost:9090`으로 접근하면, 그 localhost는 내 WSL이 아니라 Grafana Cloud 자기 자신을 의미함
- 따라서 Grafana Cloud가 로컬 WSL Prometheus 서버에 직접 접근할 수 없음

### 검토한 대안

| 대안 | 판단 |
|---|---|
| ngrok 터널 | 임시 외부 URL 생성은 가능하지만 데모 안정성 낮음 |
| Grafana Alloy | 로컬 메트릭을 Grafana Cloud로 push 가능하지만 설정 복잡도 높음 |
| EC2 Prometheus 별도 구축 | 서버리스 전환 방향과 충돌 |

---

## 결정 — 실시간 AI 패널은 포기, 준실시간 구조로 전환

Prometheus 기반 실시간 AI 패널은 포기했다.

다만 `monitor.py` 자체를 폐기한 것은 아니다.

정확히는 역할이 바뀌었다.

```text
변경 전:
monitor.py = Prometheus exporter 기반 실시간 시각화 도구

변경 후:
monitor.py = S3 업로드 기반 준실시간 SOAR 파이프라인 입력 생성기
```

즉, 실시간 탐지 시각화는 포기했지만 `monitor.py`는 AI 탐지 결과를 S3에 업로드하는 역할로 계속 사용했다.

---

## AI 대시보드 방향 재확정

실시간 위험도 그래프 대신, 실제 평가 결과와 SOAR 실행 결과를 기반으로 대시보드를 구성하기로 했다.

### 대시보드 데이터 소스

| 데이터 소스 | 용도 |
|---|---|
| Athena `model_metrics` | Precision, Recall, F1, FPR 등 모델 평가 KPI |
| Athena `aiops_results` | AI 이상 탐지 후보 수, anomaly=1 IP 집계 |
| CloudWatch `AIOps/Security` | SecurityPreventer Lambda가 기록한 차단 이벤트 |

---

## eval_model_v2.py 결과 확인

결과 파일:

```text
ai/results/performance_metrics_v2.json
```

### 모델 평가 결과

| 지표 | 값 |
|---|---:|
| Precision | 57.97% |
| Recall | 50.0% |
| F1 Score | 53.69% |
| FPR | 10.36% |

### 탐지 범위

| 항목 | 건수 |
|---|---:|
| WAF 단독 탐지 | 400건 |
| AI 추가 탐지 후보 | 145건 |
| WAF + AI 탐지 합계 | 545건 (+36.3%) |

`AI 추가 탐지 후보`는 WAF가 허용한 트래픽 중 AI가 이상 패턴으로 분류한 요청이다.

WAF 레이블을 기준으로 평가했기 때문에, 이 값을 바로 “추가 공격 탐지”라고 표현하지 않고 “이상 징후 후보”로 표현했다.

---

## AI 대시보드 패널 구성 확정

```text
[1행] KPI Stat × 4
Precision | Recall | F1 Score | FPR

[2행] 탐지 범위 Stat × 3
WAF 단독 탐지(400건)
AI 추가 탐지 후보(145건)
WAF+AI 합계(545건)

[3행] Bar chart
WAF 단독 vs WAF+AI 비교

[4행] Pie chart
전체 1,800건 구성
정상(TN 1,255)
AI 추가 탐지 후보(FP 145)
공통 탐지(TP 200)
미탐지(FN 200)

[5행] Time series
CloudWatch AIOps/Security DefenseSignal
```

---

## Federated Learning 대시보드 제외

Federated Learning 시각화도 검토했지만 제외했다.

이유:
- 현재 프로젝트 핵심 메시지는 `WAF + AI 기반 보조 탐지`
- Federated Learning까지 넣으면 메시지가 분산됨
- README 및 Velog에서는 향후 개선 방향으로만 언급하는 것이 더 적절함

---

## 초기 계획 대비 달라진 점

| 항목 | 초기 계획 | 현재 |
|---|---|---|
| 인프라 | WAF → ALB → EC2 | WAF → API Gateway → Lambda |
| AI 엔진 위치 | EC2 실시간 탐지 | 로컬 monitor.py 기반 준실시간 검증 |
| 모니터링 | Prometheus → Grafana | Grafana Cloud + Athena/CloudWatch |
| AI 대시보드 | 실시간 위험도 시각화 | 평가 KPI + 차단 이벤트 시각화 |
| monitor.py 역할 | Prometheus exporter | SOAR 입력 생성기 |
| 표현 | 실시간 AI 탐지 | 준실시간 AI 보조 탐지 |

정리하면:

```text
실시간 AI 시각화 도구
→ 준실시간 SOAR 입력 생성기
```

로 역할이 전환된 것이다.

---

# SOAR 파이프라인 복구 및 완성

## 문제 — Athena aiops_results 테이블 누락

`SecurityAnalyzer` Lambda가 Athena `aiops_results` 테이블을 조회하도록 되어 있었지만, 실제 테이블이 생성되어 있지 않았다.

그래서 S3에 결과 JSON이 업로드되어도 Lambda가 Athena 조회 단계에서 실패하고 있었다.

```text
S3 results/*.json 업로드
→ S3 ObjectCreated
→ SecurityAnalyzer Lambda
→ Athena aiops_results 조회 실패
```

### 해결

Athena `aiops_results` 테이블 생성.

- S3 경로:
  `s3://aws-waf-logs-minju-0417-project/results/year=.../month=.../day=.../`
- JsonSerDe 적용
- `year`, `month`, `day` 파티션 구조 적용
- `MSCK REPAIR TABLE` 실행 후 데이터 확인

---

## 트러블슈팅 — SOAR IP 차단 실패

Athena 테이블 문제를 해결한 뒤에도 WAF 차단이 바로 성공하지 않았다.

### ① WAF IP Set ID 불일치

Terraform으로 WAF 모듈이 재생성되면서 IP Set ID가 변경되었는데, Lambda 코드에는 이전 ID가 하드코딩되어 있었다.

### 해결

Lambda 코드의 하드코딩 제거.

```python
IP_SET_ID = os.environ.get("IP_SET_ID")
IP_SET_NAME = os.environ.get("IP_SET_NAME")
```

Terraform에서 WAF 모듈 output을 Lambda 환경변수로 주입하도록 변경.

```hcl
IP_SET_ID   = module.security.ai_block_list_id
IP_SET_NAME = module.security.ai_block_list_name
```

---

### ② import os 누락

환경변수 방식으로 수정한 뒤 `os.environ.get()`을 사용했지만, `import os`가 누락되어 Lambda 콜드 스타트 시 실패했다.

```text
NameError: name 'os' is not defined
```

### 해결

```python
import os
```

추가 후 재배포.

---

### ③ IAM 권한 부족

SecurityPreventer Lambda 실행 중 다음 권한이 부족했다.

| 권한 | 증상 |
|---|---|
| `wafv2:GetIPSet` | WAF IP Set 조회 실패 |
| `wafv2:UpdateIPSet` | IP Set 업데이트 실패 |
| `cloudwatch:PutMetricData` | AIOps/Security 메트릭 기록 실패 |

### 해결

Terraform IAM 정책 수정.

- WAF IP Set ARN을 하드코딩하지 않고 `module.security.ai_block_list_arn` 직접 참조
- Lambda role에 `cloudwatch:PutMetricData` 추가

---

# 최종 결과 — 준실시간 SOAR 파이프라인 연결 완료

최종 흐름:

```text
monitor.py
  ↓ AI 탐지 결과 aiops_*.json 생성
  ↓ S3 results/ 업로드

S3 ObjectCreated Trigger
  ↓

SecurityAnalyzer Lambda
  ↓ Athena aiops_results 쿼리
  ↓ anomaly=1 IP 추출

SecurityPreventer Lambda
  ↓ WAF IP Set 업데이트
  ↓ CloudWatch AIOps/Security 메트릭 기록

Grafana Cloud
  ↓ Athena + CloudWatch 기반 시각화
```

### 검증 결과

- `monitor.py` 실행 후 S3 `results/` 경로에 JSON 업로드 확인
- S3 ObjectCreated 트리거로 `SecurityAnalyzer` Lambda 자동 실행 확인
- Athena `aiops_results`에서 `anomaly=1` IP 조회 확인
- `SecurityPreventer` Lambda 호출 확인
- WAF `devsecops-ai-block-list` IP Set에 IP 추가 확인
- CloudWatch `AIOps/Security` Namespace에 `DefenseSignal` 메트릭 기록 확인

---

## 오늘의 결론

초기에는 `monitor.py`를 실시간 AI 시각화 도구로 사용하려 했다.

하지만 Grafana Cloud와 로컬 Prometheus 연결 문제로 실시간 패널 방식은 포기했다.

대신 `monitor.py`를 S3 업로드 기반 SOAR 입력 생성기로 전환했고, 최종적으로 다음 흐름을 완성했다.

```text
monitor.py
→ S3
→ Athena
→ Lambda
→ WAF 차단
→ CloudWatch/Grafana 시각화
```

즉 오늘의 핵심은 `monitor.py 폐기`가 아니라 `monitor.py 역할 전환`이다.

---

## 내일 할 일

- [x] Grafana AI 대시보드 신규 생성
- [ ] Time series 패널 레이아웃 조정
- [ ] Velog 4편 본문 작성