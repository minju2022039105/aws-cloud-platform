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

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t3.micro"
}

variable "s3_bucket_name" {
  description = "WAF 로그 및 AI 분석 결과 저장 S3 버킷명"
  type        = string
}

variable "kms_key_arn" {
  description = "EC2 AI 엔진이 WAF 로그 복호화에 사용하는 KMS 키 ARN"
  type        = string
}

variable "waf_ipset_arn" {
  description = "Lambda가 업데이트하는 WAF IP Set ARN"
  type        = string
}