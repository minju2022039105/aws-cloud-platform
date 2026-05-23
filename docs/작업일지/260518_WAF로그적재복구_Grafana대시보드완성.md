## [260518] WAF 로그 적재 복구 + Grafana 대시보드 완성

---

### 트러블슈팅 1 — WAF S3 로그 적재 중단

**증상**: WAF 차단(403), CloudWatch 메트릭은 정상인데 S3 WAF 로그가 5/11 이후 단 한 건도 없음

**진단**
- Firehose 확인 → delivery stream 자체 없음 → WAF direct-to-S3 구조였음
- S3 bucket policy 확인 → `DenyNonSSL` 하나만 존재. `delivery.logs.amazonaws.com` 허용 없음

**원인**: WAF direct-to-S3 logging은 `delivery.logs.amazonaws.com`이 직접 S3에 씀. 이 principal 허용 없으면 WAF 로깅 설정이 있어도 적재가 조용히 실패. CloudWatch는 WAF가 직접 push하는 별개 경로라 영향 없었음.

**수정**: `infra/modules/waf/main.tf` → `aws_s3_bucket_policy`에 `AWSLogDeliveryWrite` + `AWSLogDeliveryAclCheck` 추가

**검증**: SQLi 전송 → 10분 후 S3 신규 파일 생성 → Athena `BLOCK=1` → Grafana 반영
```
WAF 차단 → S3 적재 → Athena → Grafana ✅
```

---

### 트러블슈팅 2 — terraform plan "No changes" (수정했는데 반영 안 됨)

**증상**: `main.tf` 수정 후 plan 실행했는데 "No changes" 출력. 실제 AWS는 변경 안 됨.

**원인**: `-target` 모듈 이름 오기입
```bash
# 틀림 — module.waf 는 존재하지 않음
terraform plan -target=module.waf.aws_s3_bucket_policy.waf_logs_ssl

# 맞음
terraform plan -target=module.security.aws_s3_bucket_policy.waf_logs_ssl
```
`infra/main.tf`에서 WAF 모듈 블록 이름이 `security`임. 존재하지 않는 target 지정 시 Terraform은 "No changes" 반환.

**교훈**: `-target` 사용 전 `main.tf`에서 모듈 블록 이름 먼저 확인.

---

### 작업 내용

**eval_model_v2.py 작성** (`ai/inference/`)
- 현행 모델(train_model.py 계보) 성능 평가. 기존 eval_model.py는 구 모델 계보라 피처 불일치.
- 정답 레이블: `action == 'BLOCK'` → 1
- 결과: Precision 58% / Recall 50% / F1 0.54 / FPR 10.4% / 처리속도 0.016ms
- WAF+AI 탐지 범위: WAF 단독 400건 → WAF+AI 545건 (+36.3%)

**문서 수치 정정**
- Velog 4편 + README: `450건 / 1,750건 / 1,350건 / 22.9%` → `400건 / 1,800건 / 1,400건 / 22.2%`
- README: AI 성능 평가 표, CloudWatch vs Athena 역할 분리 섹션 추가

**Grafana 대시보드 (6패널 완성)**
- CloudWatch Time series `WAF 차단 이벤트 추이` 신규 추가. 테스트 SQLi spike 확인.
- Athena 5패널 legend 한글화: `지역 차단 (비KR)`, `평판 불량 IP`, `SQL Injection`
- Pie chart에 오늘 테스트 SQLi 1건 반영 확인 → end-to-end 검증 완료

---

### 내일 할 일

- [ ] 대시보드 제목 `New dashboard` → `WAF 보안 관제 현황`
- [ ] Gauge 제목 `GeoBlock-Non-KR` → `지역 차단 현황 (비한국 IP)`
- [ ] Bar chart 막대 alias: `AWS-AWSManagedRulesAmazonIpReputationList` → `IP 평판 차단`, `AWS-AWSManagedRulesSQLiRuleSet` → `SQL Injection 차단`
- [ ] Table 컬럼 한글화: `client_ip`→`공격 IP` / `country`→`국가` / `rule`→`차단 룰` / `hit_count`→`차단 건수`
- [ ] Time series 패널 상단 전체 너비로 레이아웃 조정
- [ ] `monitor.py` 실행 → SecurityPreventer Lambda CloudWatch 메트릭 확인 → AI 탐지 패널 추가
- [ ] Velog 4편 본문 작성 (monitor.py 검증 후)
