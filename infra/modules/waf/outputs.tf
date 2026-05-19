output "web_acl_arn" {
  description = "WAF Web ACL의 ARN 주소입니다."
  value       = aws_wafv2_web_acl.main.arn
}

output "ai_block_list_id" {
  description = "AI 차단 IP Set ID"
  value       = aws_wafv2_ip_set.ai_block_list.id
}

output "ai_block_list_name" {
  description = "AI 차단 IP Set 이름"
  value       = aws_wafv2_ip_set.ai_block_list.name
}

output "ai_block_list_arn" {
  description = "AI 차단 IP Set ARN"
  value       = aws_wafv2_ip_set.ai_block_list.arn
}

