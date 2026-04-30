# [260429] AWS 인프라 보안 고도화 및 KMS 비용 최적화

**1. 개요 (오늘 할 일 / 목표)**

- 파편화된 KMS 키 구조를 **공유 키(Shared Key) 체계**로 전환하여 관리 효율성 제고
- **S3 Bucket Key** 활성화를 통해 일일 KMS API 호출 비용 절감 ($30 → $1 미만)
- IAM 최소 권한 원칙(PoLP)에 따른 EC2 및 Lambda 역할 분리 및 리팩토링
- WAF 우선순위 재정립 및 **보안 알림(SNS) 파이프라인** 구축 완료

**2. 환경 정보**

- **OS:** Windows 11 + Ubuntu (WSL)
- **IaC Tool:** Terraform (v1.x 이상)
- **Cloud:** AWS (Region: us-east-1, N. Virginia)
- **Architecture:** WAF v2, ALB, S3, KMS, EventBridge, SNS, IAM

**3. 작업 절차 (Step by Step)**

1. **KMS 공유 아키텍처 설계:** 루트 `main.tf`에 통합 `shared_log_key` 생성 및 모듈 변수 연결
2. **IAM 리팩토링:** 기존 통합 Role 삭제 후 `ec2_ai_role` 및 `lambda_blocker_role` 개별 정의
3. **WAF 정책 최적화:** Geo-Blocking 및 AI 실시간 차단 룰 우선순위 조정 및 Managed Rule 적용
4. **알림 시스템 구축:** SNS 토픽 생성 및 EventBridge 규칙 연동 (이메일 구독 완료)
5. **인프라 최종 배포:** `terraform apply`를 통한 49개 신규 리소스 배포 성공

**4. 문제/오류 및 해결 기록 (Troubleshooting)**

**① KMS 아키텍처 및 관리 효율성**

- **이전:** 각 리소스마다 개별 KMS 키가 생성되어 관리가 파편화됨.
- **변경 사항:**
    - 공유 KMS 키(`shared_log_key`)를 루트 모듈에서 생성하여 관리 체계 일원화.
    - **자동 키 순환(`enable_key_rotation`)** 활성화를 통해 보안 규정 준수.

**② KMS API 호출 비용 과다**

- **기존 문제:** S3 로그 저장 시 발생하는 KMS API 호출로 인해 매일 약 $30 비용 발생.
- **해결:**
    - **S3 Bucket Key(`bucket_key_enabled = true`)** 설정을 적용하여 키 재사용률 극대화.
    - KMS API 호출 횟수를 99% 이상 감소시켜 **비용을 1달러 미만으로 절감.**

**③ IAM 권한 참조 오류 및 보안 취약성**

- **기존 문제:** 통합 Role 사용으로 권한 남용 위험이 있고, 하드코딩된 이름 참조로 인해 배포 오류 발생.
- **해결:**
    - **역할 분리:** EC2 분석용과 Lambda 차단용 역할을 분리하여 최소 권한 원칙 적용.
    - **동적 참조:** `ec2_instance_profile_name`을 모듈 결과값에서 직접 가져오도록 수정하여 참조 오류 해결.

**④ Terraform Backend 상태 불일치**

- **기존 문제:** S3 backend의 `tfstate`와 DynamoDB의 `checksum` 불일치로 작업 중단.
- **해결:** DynamoDB의 `terraform.tfstate-md5` 항목 삭제 후 `terraform init -reconfigure`로 상태 동기화 완료.

**5. 테스트 방법 및 증적 (Verification)**

- **Apply 결과:** `Resources: 49 added` 확인 및 인프라 정합성 검증
- **WAF 우선순위:** GeoBlock(0) → AI-Block(1) → Managed Rules(2-4) 순서 정상 반영 확인
- **알림 체계:** SNS 구독 승인(Confirm subscription) 완료 및 메일 수신 테스트 통과
- **IAM 검증:** `terraform validate`를 통해 리팩토링된 권한 구조의 문법 및 참조 정상 확인

**6. 작업 완료 항목 (Checklist)**

- [x]  버지니아 리전 통합 Shared KMS Key 구축 완료
- [x]  S3 Bucket Key 적용을 통한 비용 최적화 설계 반영
- [x]  IAM Role/Profile 분리 및 최소 권한 정책 수립
- [x]  WAF-ALB 연동 및 보안 알림 파이프라인 활성화
- [x]  Terraform Backend 상태 복구 및 안정화

**7. 다음 계획 / TODO**

- WAF 로그 분석을 위한 Athena 쿼리 시나리오 작성 및 문서화
- CloudTrail을 활용한 KMS API 과도 호출 서비스 추적 및 재발 방지 정책 수립
- AIOps 탐지 모델(Isolation Forest)과 WAF IP Set 자동 업데이트 로직 고도화
