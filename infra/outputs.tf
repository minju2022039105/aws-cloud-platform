# ==========================================
# 1. 웹 서비스 접속 정보
# ==========================================
output "api_gateway_url" {
  description = "API Gateway 기본 URL (커스텀 도메인 적용 전 테스트용)"
  value       = aws_api_gateway_stage.default.invoke_url
}

output "custom_domain_url" {
  description = "WAF 적용 서비스 접속 주소 (minju-devsec.store)"
  value       = "https://${var.domain_name}"
}

# ==========================================
# 2. 보안 자원 확인
# ==========================================
output "waf_web_acl_arn" {
  description = "현재 활성화된 WAF Web ACL의 ARN"
  value       = module.security.web_acl_arn
}

# ==========================================
# 3. 네트워크 / IAM
# ==========================================
output "ec2_profile_name" {
  description = "VPC 모듈에서 생성된 IAM 프로필명"
  value       = module.network.ec2_instance_profile_name
}

output "final_role_arn" {
  description = "GitHub Actions에서 사용할 OIDC Role ARN"
  value       = module.network.github_actions_role_arn
}
