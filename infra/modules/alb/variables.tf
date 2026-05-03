# infra/modules/alb/variables.tf

variable "vpc_id" {}
variable "public_subnets" { type = list(string) }
variable "instance_id" {}

variable "my_ip" {
  type        = list(string)
  description = "루트에서 전달받을 관리자 IP 리스트"
}