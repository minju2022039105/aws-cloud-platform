output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.public_2.id]
}

output "security_group_id" {
  value = aws_security_group.main_sg.id
}

# IAM outputs (VPC 모듈로 통합)

output "ec2_ai_role_arn" {
  value       = aws_iam_role.ec2_ai_role.arn
  description = "ARN of EC2 AI Engine IAM Role"
}

output "lambda_blocker_role_arn" {
  value       = aws_iam_role.lambda_blocker_role.arn
  description = "ARN of Lambda Blocker IAM Role"
}

output "ec2_instance_profile_name" {
  value       = aws_iam_instance_profile.ec2_profile.name
  description = "EC2 Instance Profile Name"
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_role.arn
  description = "ARN of GitHub Actions OIDC Role"
}

output "private_app_subnet_ids" {
  value       = aws_subnet.private_app[*].id
  description = "Private App Subnet IDs (EKS 노드 그룹용)"
}

output "private_db_subnet_ids" {
  value       = aws_subnet.private_db[*].id
  description = "Private DB Subnet IDs (RDS용)"
}

output "nat_gateway_id" {
  value       = aws_nat_gateway.main.id
  description = "NAT Gateway ID"
}
