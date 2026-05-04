# infra/modules/vpc/variables.tf

# 1. 내 IP 주소 (리스트 타입으로 선언하여 집/학교 모두 수용)
variable "my_ip" {
  type        = list(string)
  description = "루트(infra/)에서 넘겨받을 관리자 IP 주소 리스트"
}

# 2. AWS 계정 ID (IAM 정책 ARN 생성 등에 사용)
variable "account_id" {
  type        = string
  description = "루트에서 넘겨받을 AWS 계정 ID"
}

variable "s3_bucket_name" {
  type        = string
  description = "WAF 로그 / AI 분석 결과 버킷명"
}

variable "kms_key_arn" {
  type        = string
  description = "WAF 로그 복호화용 KMS 키 ARN"
}

variable "waf_ipset_arn" {
  type        = string
  description = "Lambda가 업데이트하는 WAF IP Set ARN"
}