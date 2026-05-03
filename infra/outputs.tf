# ==========================================
# 1. 웹 서비스 접속 정보 (WAF 적용 대상)
# ==========================================
output "alb_dns_name" {
  description = "🔥 [중요] WAF 로그를 쌓으려면 이 주소로 접속하세요!"
  value       = module.alb.alb_dns_name
}

# ==========================================
# 2. 서버 관리 정보 (SSH 접속용)
# ==========================================
output "fixed_public_ip" {
  description = "EC2 분석 서버(Ubuntu) 접속용 고정 IP입니다."
  value       = aws_eip.analysis_node_eip.public_ip
}

# ==========================================
# 3. (삭제) 보안 및 인증 정보 (IAM)
# ==========================================
# ==========================================
# 4. 인프라 연결 확인 (Debug)
# ==========================================
output "waf_web_acl_arn" {
  description = "현재 활성화된 WAF Web ACL의 ARN"
  value       = module.security.web_acl_arn
}
# ==========================================
# 5. 분석용 EC2 서버 인스턴스 정보
# ==========================================
output "ec2_profile_name" {
  description = "현재 EC2에 할당된 IAM 프로필 확인용"
  # ❌ aws_iam_instance_profile.ec2_profile.name (직접 참조 에러)
  # ✅ module.[모듈명].[output명] (정상 참조)
  value       = module.network.ec2_instance_profile_name
  }
# ==========================================
# 6. GitHub Actions OIDC 인증 정보 (추가)
# ==========================================
output "final_role_arn" {
  description = "GitHub Actions에서 사용할 OIDC Role ARN입니다."
  value       = module.network.github_actions_role_arn
}