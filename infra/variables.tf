# infra/variables.tf

variable "aws_region" {
  description = "AWS 리전 설정"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS 계정 ID (보안 정책 ARN 생성용)"
  type        = string
}

variable "my_ip" {
  description = "보안 그룹에서 접근을 허용할 관리자 IP 목록 (학교, 집 등 여러 IP 추가 가능)"
  type        = list(string)
}

variable "project_name" {
  description = "리소스 태깅용 프로젝트 이름"
  type        = string
  default     = "devsecops-platform"
}

variable "s3_bucket_name" {
  description = "WAF 로그 및 AI 분석 결과 저장 S3 버킷명"
  type        = string
}


variable "domain_name" {
  description = "ALB HTTPS에 사용할 도메인 (Route53에 등록된 도메인)"
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "ACM DNS 검증 레코드를 생성할 Route53 Hosted Zone ID"
  type        = string
  default     = ""
}

variable "waf_trusted_ip_ranges" {
  description = "WAF Scope-down에서 검사 제외할 신뢰 IP 대역 목록 (CIDR)"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "보안 알림 수신 이메일 (SNS, Budget 알림용) — terraform.tfvars에 설정"
  type        = string
}
