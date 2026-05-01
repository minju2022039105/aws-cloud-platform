output "alb_arn" {
  description = "ALB의 ARN 주소입니다. WAF 연결에 사용됩니다."
  value       = aws_lb.main.arn # alb/main.tf에 정의된 리소스 이름 확인!
}

output "alb_dns_name" {
  description = "접속할 때 사용할 ALB의 DNS 주소입니다."
  value       = aws_lb.main.dns_name
}
