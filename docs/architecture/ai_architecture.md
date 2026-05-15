 현재 데이터 흐름 요약

  monitor.py
    ├── Prometheus(:8000) → Grafana (실시간 메트릭)
    └── S3 results/*.json → Athena → Lambda Analyzer → Preventer → WAF

  S3에 저장 중인 필드: event_time, mode, ip, pred_risk, obs_risk, premit_on,
  mitigation_level, anomaly, raw_score

  Prometheus에 이미 있는 메트릭: predicted_risk, observed_risk, anomaly_status,
  block_total, pass_total

  ---
  단계별 수정 대상

  1단계 — AI score / anomaly status 시각화

  수정 파일: ai/inference/monitor.py

  현재 raw_score가 S3에만 저장되고 Prometheus에는 없음. 대시보드에서 실시간으로 볼 수  
  없는 상태.

  추가해야 하는 Prometheus 메트릭:
  # 현재 없는 것들
  RAW_SCORE = Gauge("aiops_raw_score", "Isolation Forest decision score")
  SCORE_HIST = Histogram("aiops_score_distribution", "Score distribution",
                          buckets=[-0.3, -0.2, -0.1, 0.0, 0.05, 0.1, 0.15, 0.2])       

  메인 루프에서 반영:
  RAW_SCORE.set(float(raw_score))
  SCORE_HIST.observe(float(raw_score))

  Grafana 패널 (코드 변경 없이 Prometheus 쿼리만):
  - Time series: aiops_predicted_risk, aiops_observed_risk 한 패널에 겹쳐서
  - Stat: aiops_anomaly_status (0=정상 초록 / 1=이상 빨강)
  - Histogram: aiops_score_distribution_bucket — 경계값 0.0 기준으로 정상/이상 구분선  
  표시

  ---
  2단계 — WAF 룰별 차단 수, 공격 유형 분포

  수정 파일: 없음 (코드 수정 불필요)

  WAF 로그가 S3에 쌓이고 있다면 Athena 테이블 DDL만 생성하면 됨.

  현재 lambda_security_analyzer.py가 쿼리하는 aiops_results 테이블은 AI 결과
  테이블이고, WAF 원본 로그 테이블은 별도.

  확인해야 할 것:
  - S3 버킷 aws-waf-logs-minju-0417-project에 WAF 로그가 실제로 있는지
  - 있다면 Athena DDL 작성 → Grafana Athena 데이터소스로 쿼리

  Grafana 패널:
  - Bar chart: terminatingRuleId 별 COUNT (룰별 차단 건수)
  - Pie chart: terminatingRuleId를 SQLi / XSS / Bot / GeoBlock / AI 로 그룹핑

  ---
  3단계 — 국가/IP 히트맵

  수정 파일: ai/inference/monitor.py

  현재 S3 로그에 country_code(숫자)는 있지만 실제 국가명이 없고, country_code가 S3     
  로그에 포함되어 있지 않음.

  log_entry에 추가:
  log_entry = {
      ...기존 필드...,
      "country_code": int(sample["country_code"].values[0]),
      "uri_entropy": float(sample["uri_entropy"].values[0]),
  }

  Grafana Geomap 패널은 IP 기반으로 동작하므로, Athena에서 IP별 집계 후 Grafana Geomap 
  패널 연결. country_code → 국가명 매핑 테이블은 Grafana transforms로 처리 가능.       

  ---
  4단계 — 오탐률(FPR), MTTD/MTTR

  수정 파일: ai/inference/monitor.py, lambda/preventer/lambda_security_preventer.py    

  MTTD (탐지까지 걸린 시간):
  - monitor.py에서 anomaly=1 최초 감지 시각을 기록
  - Preventer Lambda 호출 시 detection_time 타임스탬프 페이로드에 포함
  - Preventer에서 WAF 업데이트 완료 시각 - detection_time = MTTR

  # monitor.py에 추가
  MTTD_SECONDS = Gauge("aiops_mttd_seconds", "Mean time to detect anomaly")
  detection_start_time = None

  # anomaly 전환 시점
  if anomaly == 1 and detection_start_time is None:
      detection_start_time = time.time()
  elif anomaly == 0:
      detection_start_time = None

  오탐률(FPR):
  정답 라벨 없이 측정하는 현실적인 대안:
  - mode == "NORMAL" 구간에서 anomaly=1로 판정된 건수 → 오탐으로 간주
  - aiops_false_positive_total Counter 추가

  # NORMAL 구간에서 이상으로 잘못 판정된 경우
  if mode == "NORMAL" and raw_score < THRESHOLD:
      FALSE_POSITIVE.inc()

  ---
  전체 정리

  단계: 1
  수정 파일: monitor.py
  작업: Prometheus에 raw_score, score_histogram 추가
  ────────────────────────────────────────
  단계: 1
  수정 파일: Grafana
  작업: 3개 패널 구성
  ────────────────────────────────────────
  단계: 2
  수정 파일: 없음
  작업: Athena WAF 로그 테이블 DDL + Grafana 패널
  ────────────────────────────────────────
  단계: 3
  수정 파일: monitor.py
  작업: S3 로그에 country_code 추가
  ────────────────────────────────────────
  단계: 3
  수정 파일: Grafana
  작업: Geomap 패널 구성
  ────────────────────────────────────────
  단계: 4
  수정 파일: monitor.py
  작업: FP Counter, detection timestamp 추가
  ────────────────────────────────────────
  단계: 4
  수정 파일: lambda_security_preventer.py
  작업: response timestamp → CloudWatch