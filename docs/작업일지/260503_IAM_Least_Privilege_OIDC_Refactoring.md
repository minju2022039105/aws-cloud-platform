# [260503] GitHub Actions IAM 권한 다이어트 — AmazonEC2FullAccess 제거 및 최소 권한 설계

## 1. 개요 (목표)

- GitHub Actions OIDC Role에 붙어있던 **`AmazonEC2FullAccess` 완전 제거**
- Terraform이 실제로 필요한 액션만 화이트리스트로 정의한 **커스텀 최소 권한 정책** 설계 및 배포
- **Condition 기반 접근 제어** 도입: 인스턴스 타입 제한 + 태그 기반 리소스 제어로 폭발 반경(Blast Radius) 최소화
- AWS-SCS(Security Specialty) 설계 원칙 — Least Privilege, Defense in Depth — 을 실제 인프라에 적용

## 2. 환경 정보

- **OS**: Windows 11 + Ubuntu (WSL)
- **IaC Tool**: Terraform v1.14.7
- **Cloud**: AWS (Region: us-east-1, N. Virginia)
- **변경 대상**: `infra/modules/vpc/main.tf`, `infra/modules/iam/main.tf`, `infra/variables.tf`, `infra/terraform.tfvars`

## 3. 작업 절차 (Step by Step)

1. **모듈 경로 정합성 복구 및 `terraform init`**: `module.identity` → `module.network` state 이전 (`terraform state mv` 10회) 및 init 성공 확인
2. **IAM 통합**: `modules/iam/` 의 IAM 리소스를 `modules/vpc/main.tf`로 병합하여 모듈 구조 단순화
3. **variables.tf / terraform.tfvars 생성**: 하드코딩된 계정 ID, 관리자 IP를 변수로 분리. `my_ip`를 `list(string)` 타입으로 선언하여 복수 IP 확장 가능하게 설계
4. **`github_actions_minimal_policy` 설계**: 기존 `AmazonEC2FullAccess` 대비 액션 범위를 수십 배 축소, Condition 2개 추가
5. **`modules/iam/main.tf` 정리**: 중복 리소스 및 구버전 정책 제거 — 잘못 실행 시 FullAccess가 재적용될 수 있는 위험 코드 차단
6. **`terraform apply` 배포 완료**: 변경 사항 AWS 반영 및 state 정합성 최종 확인

## 4. 핵심 보안 설계 상세

### ① AmazonEC2FullAccess 제거

```hcl
# 제거 전
resource "aws_iam_role_policy_attachment" "github_actions_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"  # 전체 EC2 권한
}
```

```hcl
# 적용 후 — 커스텀 최소 권한 정책 연결
resource "aws_iam_role_policy_attachment" "github_actions_minimal_attach" {
  policy_arn = aws_iam_policy.github_actions_minimal_policy.arn
}
```

### ② ec2:RunInstances — 인스턴스 타입 제한 (비용 제어)

```hcl
{
  Effect   = "Allow"
  Action   = ["ec2:RunInstances"]
  Resource = "*"
  Condition = {
    StringEquals = {
      "ec2:InstanceType" = ["t3.micro"]   # t3.xlarge 100대 기동 불가
    }
  }
}
```

**설계 의도**: `RunInstances`를 무조건 허용하면 고사양 인스턴스를 대량 생성하는 비용 폭탄 공격에 노출됨. 인스턴스 타입을 `t3.micro`로 고정하여 최대 피해 범위를 사전에 봉쇄.

### ③ Terminate / Stop / Start — 태그 기반 리소스 제어 (폭발 반경 제한)

```hcl
{
  Effect   = "Allow"
  Action   = ["ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances"]
  Resource = "*"
  Condition = {
    StringEquals = {
      "aws:ResourceTag/Project" = "devsecops-platform"
    }
  }
}
```

**설계 의도**: 자격증명 탈취 시나리오에서 공격자가 계정 내 **모든 EC2 인스턴스**를 종료하는 사태를 방지. `Project: devsecops-platform` 태그가 없는 리소스(타 프로젝트, 타 팀 인프라)는 건드릴 수 없음.

### ④ elasticloadbalancing — 와일드카드 제거, 12개 세부 액션 화이트리스트

```hcl
# 제거 전
Action = ["elasticloadbalancing:*"]   # ELB FullAccess와 동급

# 적용 후
Action = [
  "elasticloadbalancing:CreateLoadBalancer",
  "elasticloadbalancing:DeleteLoadBalancer",
  "elasticloadbalancing:DescribeLoadBalancers",
  "elasticloadbalancing:CreateTargetGroup",
  "elasticloadbalancing:DeleteTargetGroup",
  "elasticloadbalancing:DescribeTargetGroups",
  "elasticloadbalancing:RegisterTargets",
  "elasticloadbalancing:DeregisterTargets",
  "elasticloadbalancing:CreateListener",
  "elasticloadbalancing:DeleteListener",
  "elasticloadbalancing:DescribeListeners",
  "elasticloadbalancing:AddTags"
]
```

### ⑤ OIDC Trust Policy — 레포지토리 범위 고정

```hcl
Condition = {
  StringLike = {
    "token.actions.githubusercontent.com:sub" = "repo:minju2022039105/aws-devsecops-platform:*"
  }
}
```

**설계 의도**: OIDC는 장기 자격증명(Access Key)을 코드에 박지 않는 가장 안전한 CI/CD 인증 방식. 레포지토리 주소를 정확히 고정하여 타 레포/포크 레포에서의 Role Assume을 원천 차단.

## 5. 트러블슈팅

| 구분 | 증상 | 원인 | 조치 |
| :--- | :--- | :--- | :--- |
| **State Drift** | `terraform plan`에서 IAM 리소스 10개 destroy 예정 표시 | `module.identity` → `module.network` 리네임 시 state 미동기화 | `terraform state mv` 10회 실행으로 state 키 일괄 이전 |
| **순환 참조** | VPC 모듈이 ALB SG ID를 참조하려 하면 Cycle Error | `module.network`(VPC)과 `module.alb`가 서로 의존하는 구조 | 포트 80 ingress 규칙을 루트 모듈의 `aws_security_group_rule`로 분리 |
| **타입 불일치** | `list(string)` 모듈 변수에 `string` 값 전달 오류 | `variables.tf`의 `my_ip`가 `string`으로 선언됨 | `list(string)`으로 타입 변경, `terraform.tfvars`에서 `["IP/32"]` 형식으로 수정 |
| **Dead Code** | `modules/iam/main.tf`에 구버전 정책 잔존 | IAM 통합 후 구 파일 미정리 | 중복 리소스 및 `AmazonEC2FullAccess` 잔재 코드 전면 제거 |

## 6. 테스트 및 검증

- `terraform validate` → **`The configuration is valid.`** 확인
- `terraform plan` → **`0 to destroy`** 확인 (기존 리소스 무삭제)
- `terraform apply` → **`2 added, 0 changed, 0 destroyed`** 배포 성공
- AWS IAM 콘솔에서 `github-actions-oidc-role`의 연결 정책 확인: `AmazonEC2FullAccess` 없음, `github-actions-minimal-policy` 연결 확인

## 7. Technical Insight — AWS-SCS 관점에서의 설계 의도

이번 작업의 핵심은 **"동작하는 정책"이 아니라 "의도가 있는 정책"을 만드는 것**이었다.

AWS-SCS 시험 및 실무에서 IAM 정책 설계의 핵심 원칙은 다음 세 가지다:

1. **Least Privilege (최소 권한)**: 업무에 필요한 최소한의 권한만 부여. `FullAccess` 계열 관리형 정책은 학습/PoC 단계에서만 허용.
2. **Condition-based Access Control (조건부 접근 제어)**: 액션 허용 자체는 피할 수 없을 때, `Condition`으로 적용 범위를 제한. 인스턴스 타입 제한, 태그 기반 제어가 그 예.
3. **Blast Radius 최소화**: 자격증명이 탈취됐을 때 공격자가 할 수 있는 최악의 행동을 상정하고, 그 영향 범위를 코드 수준에서 봉쇄.

`AmazonEC2FullAccess` 하나면 계정 내 모든 EC2를 생성/삭제/변조할 수 있다. 이번 리팩토링 이후에는 자격증명이 유출되더라도 공격자가 할 수 있는 행동이 **`t3.micro` 생성**, **`Project: devsecops-platform` 태그 리소스 제어**로 제한된다. 이것이 Condition 기반 설계의 실질적 가치다.

## 8. 스크린샷 첨부 가이드

포폴 또는 기술 블로그에 이 작업의 설득력을 높이려면 아래 화면을 캡처해두는 것을 권장한다.

| 우선순위 | 캡처 대상 | 경로 / 방법 | 설명 |
| :---: | :--- | :--- | :--- |
| ⭐⭐⭐ | **IAM Role 연결 정책 비교** | AWS 콘솔 → IAM → Roles → `github-actions-oidc-role` → Permissions 탭 | `AmazonEC2FullAccess`가 사라지고 `github-actions-minimal-policy`만 남은 화면. Before/After 병렬 캡처 시 임팩트 극대화 |
| ⭐⭐⭐ | **terraform apply 결과** | 터미널 출력 | `2 added, 0 changed, 0 destroyed` 라인이 보이는 전체 apply 결과 |
| ⭐⭐ | **커스텀 정책 JSON** | AWS 콘솔 → IAM → Policies → `github-actions-minimal-policy` → JSON 탭 | Condition 블록(`ec2:InstanceType`, `aws:ResourceTag/Project`)이 보이는 실제 정책 JSON |
| ⭐⭐ | **terraform state list** | 터미널: `terraform state list` | `module.identity`가 없고 `module.network`에 IAM 리소스가 정상 포함된 state 목록 |
| ⭐ | **terraform validate 통과** | 터미널 출력 | `Success! The configuration is valid.` 화면 |
| ⭐ | **IAM Access Analyzer (선택)** | AWS 콘솔 → IAM → Access Analyzer | 미사용 권한 분석 결과. 있으면 "설계 후 검증까지 했다"는 추가 어필 포인트 |

## 9. 작업 완료 항목 (Checklist)

- [x] `AmazonEC2FullAccess` 완전 제거 및 커스텀 정책 연결 완료
- [x] `ec2:RunInstances` — `t3.micro` 인스턴스 타입 Condition 적용
- [x] `Terminate/Stop/Start` — `Project: devsecops-platform` 태그 Condition 적용
- [x] `elasticloadbalancing:*` → 12개 세부 액션 화이트리스트 교체
- [x] OIDC Condition 레포지토리 범위 고정 유지
- [x] `modules/iam/main.tf` 중복 리소스 및 위험 코드 전면 제거
- [x] `variables.tf` / `terraform.tfvars` 생성 — 하드코딩 제거 시작
- [x] `terraform validate` / `apply` 성공 확인

## 10. 다음 계획 / TODO

- `variables.tf` 확장: 하드코딩된 KMS ARN, WAF IPSet ARN, S3 버킷명 변수화
- HTTPS 리스너 추가: ACM 인증서 발급 → ALB에 443 리스너 연결 (보안 포폴 완성도 향상)
- VPC Flow Logs 활성화: 네트워크 레벨 감사 로그 확보
- IAM Access Analyzer 연동: 실제 사용 권한 기반 정책 자동 정제
