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