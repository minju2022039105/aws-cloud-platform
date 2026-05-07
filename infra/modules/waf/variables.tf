variable "shared_kms_key_arn" {
  description = "공유 KMS 키 ARN (루트 모듈에서 전달받음)"
  type        = string
}

variable "s3_bucket_name" {
  description = "WAF 로그 저장 S3 버킷명"
  type        = string
}

variable "account_id" {
  description = "AWS 계정 ID (KMS 정책 ARN 구성용)"
  type        = string
}

variable "trusted_ip_ranges" {
  description = "WAF Managed Rule 검사를 건너뛸 신뢰 IP CIDR 목록 (사내망, 관리 서버 등)"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "WAF 예산 알림 수신 이메일"
  type        = string
}