output "vpc_id" {
  value = aws_vpc.main.id
}

# 기존 EC2가 사용하던 단일 서브넷 ID
output "public_subnet_id" {
  value = aws_subnet.public.id
}

# ⭐ ALB가 사용할 서브넷 '리스트' (두 개를 묶어서 보냅니다)
output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.public_2.id]
}

output "security_group_id" {
  value = aws_security_group.main_sg.id
}