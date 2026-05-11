# [260511] ISMS 컴플라이언스 — AWS Config Rules 구축

## 1. 구축 배경

포폴 지원 포지션(클라우드 보안 아키텍트) JD에 ISMS/ISO27001 컴플라이언스 경험이 요구됨.
기존 아키텍처(WAF, GuardDuty, CloudTrail)가 ISMS 통제항목과 실질적으로 겹치므로,
AWS Config Rules로 자동 점검 파이프라인을 구축하여 컴플라이언스 근거를 명시적으로 확보.

---

## 2. 구축 내용

### 2-1. `infra/config.tf` 신규 생성

| 리소스 | 역할 |
|---|---|
| `aws_config_configuration_recorder` | 전체 리소스 유형 기록 |
| `aws_config_delivery_channel` | 기존 CloudTrail S3 버킷 재사용, 일 1회 스냅샷 |
| `aws_guardduty_detector` | GuardDuty 활성화 |
| `aws_iam_account_password_policy` | 패스워드 복잡성 정책 (14자, 대소문자+숫자+특수문자, 90일 만료) |
| `aws_cloudwatch_event_rule` (config) | NON_COMPLIANT 이벤트 → 기존 SNS 알림 연동 |

### 2-2. ISMS 통제항목 기반 Config Rules 11개

| ISMS 항목 | Config Rule | 최종 상태 |
|---|---|---|
| 2.5 인증 및 권한관리 | root 액세스 키 미사용 | 준수 ✅ |
| 2.5 인증 및 권한관리 | IAM 패스워드 정책 | 준수 ✅ |
| 2.5 인증 및 권한관리 | 콘솔 접근 MFA 활성화 | 평가 없음 (IAM 콘솔 사용자 없음) |
| 2.6 접근통제 | S3 퍼블릭 읽기 차단 | 준수 ✅ |
| 2.6 접근통제 | S3 퍼블릭 쓰기 차단 | 준수 ✅ |
| 2.6 접근통제 | VPC 기본 보안그룹 비활성 | 준수 ✅ |
| 2.9 로그 관리 | CloudTrail 활성화 | 준수 ✅ |
| 2.9 로그 관리 | CloudTrail 로그 무결성 검증 | 준수 ✅ |
| 2.10 시스템 보안관리 | S3 SSL 전용 접근 | 준수 ✅ |
| 2.10 시스템 보안관리 | EBS 볼륨 암호화 | 평가 없음 (EC2 없음) |
| 2.11 사고 예방 및 대응 | GuardDuty 활성화 | 준수 ✅ |

---

## 3. 미준수 항목 수정 이력

### Fix-1. Root 액세스 키 삭제
**발견**: `iam-root-access-key-check` NON_COMPLIANT  
**원인**: 초기 설정 시 생성한 root 액세스 키 잔존 (마지막 사용 51일 전)  
**해결**: AWS 콘솔 → Security credentials에서 수동 삭제

### Fix-2. IAM 패스워드 정책 미설정
**발견**: `iam-password-policy` NON_COMPLIANT  
**해결**: `aws_iam_account_password_policy` 리소스 추가 → terraform apply

### Fix-3. VPC 기본 보안그룹 규칙 존재
**발견**: `vpc-default-sg-closed` NON_COMPLIANT — sg-096c6b0a1f0e708df (기본 VPC)  
**원인**: Terraform 관리 VPC의 default SG는 `ingress=[]` 처리했으나, AWS 계정 기본 VPC의 default SG는 Terraform 관리 외  
**해결**:
- Terraform VPC: `aws_default_security_group`에 `ingress = []`, `egress = []` 명시
- 기본 VPC: CLI로 인바운드(self-referencing) + 아웃바운드(0.0.0.0/0) 규칙 직접 제거

### Fix-4. S3 버킷 5개 SSL 정책 누락
**발견**: `s3-ssl-requests-only` NON_COMPLIANT — 5개 버킷  
**해결**:
- Terraform 관리 버킷 3개 (cloudtrail_logs, waf_logs, model_store): `aws_s3_bucket_policy` 추가 → terraform apply
- Terraform 외부 버킷 2개 (tfstate, sec-core): `aws s3api put-bucket-policy` CLI로 직접 추가

### Fix-5. GuardDuty 미활성화
**발견**: `guardduty-enabled` NON_COMPLIANT  
**해결**: `aws_guardduty_detector` 리소스 추가 → terraform apply

---

## 4. 아키텍처 설계 포인트

- **기존 인프라 재사용**: Config 전달 채널에 CloudTrail 전용 S3 버킷(`/config` prefix 분리) 재활용 → 버킷 추가 비용 없음
- **알림 통합**: NON_COMPLIANT 이벤트를 기존 `devsecops-security-alerts` SNS 토픽으로 라우팅 → 단일 알림 채널 유지
- **Rule 명명 규칙**: `isms-{항목번호}-{내용}` 형식으로 ISMS 매핑 추적 가능하게 설계

---

## 5. 블로그 포스트 수정

### 02_코드가 보안이다.md (2편)

- 도입부 압축 (6줄 → 3줄)
- 2절 YAML 코드블록 압축 + `"코드가 AWS에 닿기 전에 파이프라인이 멈춘다"` 인용구 처리
- `.trivyignore` 철학 문장 인용구 스타일로 변경
- OIDC 마무리 문장 인용구 추가
- 5절에 함수명 불일치 트러블슈팅 추가 (실제 겪은 `ResourceNotFoundException` 기반)
- 이미지 위치 4곳 삽입 (파이프라인 성공, Security Gates, S3 tfstate, 에러 로그)

### 01_WAF만으로는-부족한-이유.md (1편)

- 제목 변경: `WAF만으로는 부족했다: AI 이상 탐지를 붙인 이유`
- WAF 과금 표현 수정: 요청 수 기준 과금 → 로그/Athena/Lambda 처리량 증가 관점으로 정정
- KMS 비용 폭탄 섹션 3줄로 압축 → 5편 트러블슈팅으로 이동 명시

---

## 6. 다음 작업

- [ ] 벨로그 이미지 URL 교체 후 1편, 2편 업로드
- [ ] 포폴 문서 작성: ISMS 컴플라이언스 파이프라인 서술 정리
- [ ] Config 비용 모니터링 (예상 월 $1~3)
