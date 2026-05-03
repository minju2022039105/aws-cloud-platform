output "alb_arn" {
  description = "ALB의 ARN 주소입니다. WAF 연결에 사용됩니다."
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "접속할 때 사용할 ALB의 DNS 주소입니다."
  value       = aws_lb.main.dns_name
}

output "alb_sg_id" {
  description = "ALB 보안 그룹 ID (EC2 SG에서 인바운드 허용 규칙에 사용)"
  value       = aws_security_group.alb_sg.id
}
