# 1. ALB 보안 그룹 (80포트 개방)
resource "aws_security_group" "alb_sg" {
  name   = "devsecops-alb-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. ALB 본체 생성
resource "aws_lb" "main" {
  name               = "minju-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnets # 변수로 받아올 거예요
}

# 3. 대상 그룹 (EC2를 바라봄)
resource "aws_lb_target_group" "main" {
  name     = "minju-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id
}

# 4. 대상 그룹에 민주님 EC2 연결
resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = var.instance_id # 변수로 받아올 거예요
  port             = 80
}

# 5. 리스너 (문지기)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

