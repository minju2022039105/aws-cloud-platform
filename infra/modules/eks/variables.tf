variable "cluster_name" {
  type    = string
  default = "devsecops-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (VPC 모듈 output)"
}

variable "private_app_subnet_ids" {
  type        = list(string)
  description = "EKS 노드 그룹을 배치할 Private App 서브넷 ID 목록"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}
