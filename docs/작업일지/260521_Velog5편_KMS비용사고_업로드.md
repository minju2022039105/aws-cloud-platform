## [260521] Velog 5편 업로드 — KMS 비용 폭증 트러블슈팅

---

### 작업 내용

**Velog 5편 발행 완료** (`docs/blog/05_트러블슈팅-KMS-비용-폭증-사고.md`)

- 제목: *614만 건의 KMS 호출 — 무한루프가 $30 청구서를 만든 날*
- AWS WAF + AI 이상 탐지 플랫폼 구축기 시리즈 5편
- KMS 비용 사고 원인 분석 → 긴급 대응 → 재발 방지 → 전면 개선까지 전 과정 서술

---

### 글 핵심 내용 요약

**사고 개요**
- KMS API 호출 6,141,359건 → $18.42 과금 (총 청구 $30.60)
- `monitor.py`의 `while True` 무한루프가 SSE-KMS 버킷에 1초마다 S3 PUT → KMS `GenerateDataKey` 연쇄 호출
- SSH 세션 종료 후에도 EC2 프로세스가 살아남아 한 달간 누적

**긴급 대응**
- KMS 키 삭제 예약 (Root 계정으로 Key Policy 수정 후 진행)
- ALB 삭제 및 퍼블릭 IPv4 리소스 정리
- AWS Support Billing Case 접수 (학습 목적 일회성 Waiver 요청)

**재발 방지 및 인프라 전면 개선**

| 개선 항목 | 내용 |
|-----------|------|
| 암호화 방식 변경 | 고빈도 로그 버킷은 SSE-S3로 전환, SSE-KMS 필요 시 `bucket_key_enabled = true` 필수 |
| KMS 아키텍처 개편 | 리소스별 개별 키 → 루트 공유 키(`shared_log_key`) 단일화 |
| KMS 비용 결과 | $18.42 → $1.41 (키 월정액 $1.00 + API 호출 $0.41) |
| Terraform 상태 복구 | DynamoDB lock table 체크섬 불일치 → `delete-item` 후 `terraform init -reconfigure` |
| IAM 역할 분리 | EC2/Lambda 통합 Role → `ec2_ai_role` / `lambda_blocker_role` 최소 권한 분리 |
| SNS 보안 알림 | WAF 설정 변경 이벤트 → 이메일 즉시 알림 (SNS 토픽도 공유 KMS 키로 암호화) |
| WAF 우선순위 재정립 | GeoBlock(0) → AI-RealTime-Block(1) → SQLi(2) → Common(3) → IP Reputation(4) |
| AWS Budgets 설정 | 월 $5 초과 시 이메일 알림 |

---

### 오늘 기준 전체 산출물 상태

| 항목 | 상태 |
|------|------|
| Velog 1편 | ✅ 발행 완료 |
| Velog 2편 | ✅ 발행 완료 |
| Velog 3편 | ✅ 발행 완료 |
| Velog 4편 | ✅ 발행 완료 |
| Velog 5편 (KMS 비용 사고) | ✅ 발행 완료 |
| Velog 6편 초안 | 📝 작성 완료 (이미지 삽입 후 발행 예정) |
| SOAR 파이프라인 | ✅ 완성 |
| Grafana WAF/AI 대시보드 | ✅ 완성 |

---

### 다음 할 일

- [ ] Velog 6편 이미지 삽입 후 발행
- [ ] README 전체 업데이트
- [ ] 전체 커밋 정리 및 push
