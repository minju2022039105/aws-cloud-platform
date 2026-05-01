output "web_acl_arn" {
  description = "WAF Web ACL의 ARN 주소입니다."
  value       = aws_wafv2_web_acl.main.arn # main.tf에 정의된 리소스명 확인!
}

