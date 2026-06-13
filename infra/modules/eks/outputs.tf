output "cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "EKS 클러스터 이름"
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "EKS API Server 엔드포인트"
}

output "cluster_certificate_authority" {
  value       = aws_eks_cluster.main.certificate_authority[0].data
  description = "EKS 클러스터 CA 인증서 (base64)"
}

output "cluster_security_group_id" {
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description = "EKS가 자동 생성한 클러스터 보안 그룹 ID"
}
