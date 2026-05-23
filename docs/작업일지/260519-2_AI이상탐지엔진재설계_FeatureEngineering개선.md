## [260520] AI 이상 탐지 엔진 재설계 — WAF 로그 구조 분석 및 Feature Engineering 개선

---

### 작업 내용

기존 AI 이상 탐지 파이프라인을 재검증하는 과정에서 학습/추론 피처 불일치 문제를 발견했다.

초기 `analyze_anomalies.py`는:

- 모델 학습 피처와 다른 값을 사용
- scaler 미적용
- URI 텍스트 기반 임시 feature extraction 사용

상태였고, 결과적으로 Sentinel 재임계화가 전부 정상 판정(pass-through 실패)되는 문제가 발생했다.

---

### 트러블슈팅 — 학습/추론 피처 불일치

**문제**

모델 학습 시 사용한 피처:

```python
["country_code", "rule_code", "uri_len", "uri_entropy"]
```

반면 `analyze_anomalies.py`는 URI 길이, 특수문자 개수, 키워드 개수, entropy 등 임시 피처를 직접 생성하고 있었다. 또한 scaler를 로드하지 않아 학습 시와 추론 시 feature distribution이 완전히 달라진 상태였다.

**수정 사항**

- `final_preprocessed_waf_data.csv` 기준으로 파이프라인 통일
- scaler 로드 및 적용 추가
- contamination 기준 통일 (`0.25`)
- Sentinel pass-through 정상화

---

### 트러블슈팅 — uri_entropy가 실제 공격을 반영하지 못한 이유

재학습 후에도 이상한 결과가 발견됐다. SQL Injection 공격인데:

```text
request_uri = "/"
entropy("/") = 0.0
```

공격인데 entropy가 정상 수준이었다.

원인을 추적한 결과 AWS WAF 로그 구조 문제를 발견했다.

```json
{
  "httpRequest": {
    "uri": "/",
    "args": "id=1' UNION SELECT ..."
  }
}
```

AWS WAF는 path(`uri`)와 query string(`args`)을 분리 저장한다. 기존 전처리는 `args`를 버리고 `uri`만 저장하고 있어서 실제 SQLi payload가 feature engineering 단계에서 소실되고 있었다.

---

### Feature Engineering 재설계

기존 `uri_entropy` → `path_entropy` + `args_entropy` 분리

공격은 path보다 query string에 집중된다는 점을 반영했다.

| 구분 | path_entropy | args_entropy |
|------|-------------|-------------|
| 정상 요청 | 2.9 ~ 3.3 | 0.0 |
| SQL Injection | 0.0 | 4.66 |
| Encoded Payload Attack | 0.0 | 4.65 |

SQL 키워드, 특수문자, URL 인코딩 문자열이 혼합될수록 Shannon Entropy가 증가하는 구조를 확인했다.

---

### contamination 재튜닝

기존 `0.15` → 혼합 데이터셋(공격 400 + 정상 1400) 기준으로 `0.25`로 재조정

선정 기준:
- SQLi avg score 음수 유지
- flagged 비율 20~30% 진입
- 운영 탐지율 관점에서 지나치게 보수적이지 않은 구간

결과:
```
이상 탐지: 427건 / 1800건 (23.7%)
Score IQR: 0.0491
```

IQR이 0.05 기준선을 약간 하회했으나, 합성 데이터 기반 점수 분포 한계로 판단.

---

### 성능 평가 기준 재정의

초기 평가에서는 GeoBlock 차단 이벤트까지 AI 평가에 포함되어 있었다. GeoBlock은 `Allow-Only-Korea` WAF 룰 기반 정책 차단 이벤트이므로 AI가 새로 탐지해야 하는 공격과 성격이 다르다. 따라서 최종 평가는 SQLi + 정상 ALLOW 트래픽 기준으로 재산정했다.

---

### 최종 성능 결과

```
Recall    : 100.0%
Precision : 30.6%
F1-Score  : 0.4684
FPR       : 16.2%
FN        : 0
```

> **수치 급변 맥락**: 이전 eval_model_v2 평가(Precision 57.97%, Recall 50%)와 수치가 크게 달라진 것은 단순 모델 변경이 아니라 ① 평가 대상 재정의(GeoBlock 제외) ② feature engineering 재설계(args_entropy 추가) ③ contamination 재조정(0.15→0.25) 세 요인이 복합적으로 작용한 결과다.

**Before / After**

| 구분 | 탐지 건수 | 방식 |
|------|---------|------|
| Before | 100건 | WAF SQLi 정적 룰 |
| After | 327건 | WAF + AI 이상 탐지 |
| AI 추가 탐지 | 227건 | WAF 허용 → AI 이상 탐지 |

비지도 이상 탐지 특성상 FP는 증가했지만, 공격 미탐(FN=0)을 우선하는 보수적 탐지 구조로 정리했다.

---

### 현재 최종 파이프라인

```
monitor.py
  → results/*.json 업로드

S3 ObjectCreated
  → SecurityAnalyzer Lambda 실행

Analyzer Lambda
  → Athena anomaly=1 IP 집계
  → SecurityPreventer 호출

Preventer Lambda
  → WAF IP Set 업데이트
  → CloudWatch AIOps/Security 메트릭 기록
```

---

### 정리

이번 트러블슈팅에서 가장 크게 배운 점:

```
모델 성능 이전에,
로그 구조와 feature preservation이 먼저다.
```

WAF 로그 구조 이해 → args 보존 필요성 → feature engineering 재설계 → 평가 기준 재정의 → FP/FN trade-off 까지 다시 정리하면서, 단순 "AI 붙이기"가 아니라 운영형 탐지 파이프라인 관점으로 구조를 재설계하게 됐다.
