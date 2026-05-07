# infra/modules/alb/variables.tf

variable "vpc_id" {}
variable "public_subnets" { type = list(string) }
variable "instance_id" {}

variable "my_ip" {
  type        = list(string)
  description = "루트에서 전달받을 관리자 IP 리스트"
}

variable "domain_name" {
  type        = string
  description = "ACM 인증서 발급 및 HTTPS에 사용할 도메인 (예: example.com)"
}

variable "route53_zone_id" {
  type        = string
  description = "DNS 검증 레코드를 생성할 Route53 Hosted Zone ID"
}
