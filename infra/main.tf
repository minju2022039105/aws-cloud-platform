# ==========================================
# 1. 초기 설정 (Provider & Data Sources)
# ==========================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ==========================================
# 2. 인프라 모듈 (modules/ 경로 적용)
# ==========================================

# infra/main.tf

# 1. 네트워크 및 IAM (기존 vpc 모듈과 통합)
module "network" {
  source = "./modules/vpc" 
  
  # [핵심] 여기에 변수 배달!
  my_ip      = var.my_ip
  account_id = var.account_id
}

# 2. 보안 설정 (WAF)
module "security" {
  source             = "./modules/waf"
  shared_kms_key_arn = aws_kms_key.shared_log_key.arn
  # 만약 WAF에서도 내 IP만 허용하고 싶다면 여기에 추가
  # my_ip            = var.my_ip 
}

# 3. 부하 분산 (ALB)
module "alb" {
  source         = "./modules/alb"
  vpc_id         = module.network.vpc_id
  public_subnets = module.network.public_subnet_ids
  instance_id    = aws_instance.security_node.id
  
  # [핵심] ALB 보안 그룹에서도 내 IP만 허용하려면 배달!
  my_ip          = var.my_ip
}

# ==========================================
# 3. 개별 리소스 (EC2)
# ==========================================

resource "aws_instance" "security_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer.key_name

  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [module.network.security_group_id]

  # IAM을 VPC로 통합했으므로 network 모듈의 결과값을 참조
  iam_instance_profile = module.network.ec2_instance_profile_name
  
  tags = { Name = "DevSecOps-Analysis-Node" }
}

# ==========================================
# 4. 보안 접속 및 공유 자원
# ==========================================

resource "tls_private_key" "rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = "devsecops-key"
  public_key = tls_private_key.rsa.public_key_openssh
}

resource "local_file" "private_key" {
  content  = tls_private_key.rsa.private_key_pem
  filename = "my-key.pem"
}

resource "aws_kms_key" "shared_log_key" {
  description             = "Centralized Shared KMS Key for Security Logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# ==========================================
# 5. 최종 연결 및 알림 설정
# ==========================================

# ALB → EC2 포트 80 허용 규칙 (vpc/alb 순환 참조 방지를 위해 루트 모듈에서 선언)
resource "aws_security_group_rule" "allow_alb_to_ec2" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = module.network.security_group_id
  source_security_group_id = module.alb.alb_sg_id
  description              = "Allow HTTP traffic from ALB"
}

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = module.alb.alb_arn
  web_acl_arn  = module.security.web_acl_arn
}

resource "aws_eip" "analysis_node_eip" {
  instance = aws_instance.security_node.id
  domain   = "vpc"
  tags     = { Name = "DevSecOps-Fixed-IP" }
}

resource "aws_sns_topic" "security_alerts" {
  name = "devsecops-security-alerts"
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "yapp9069@naver.com" 
}

resource "aws_cloudwatch_event_rule" "waf_block_event" {
  name        = "waf-block-detection"
  description = "Capture WAF Block events and send notification"
  event_pattern = jsonencode({
    "source" : ["aws.wafv2"],
    "detail-type" : ["WAF Configuration Change", "AWS API Call via CloudTrail"],
    "detail" : {
      "eventName" : ["UpdateWebACL", "DeleteWebACL"]
    }
  })
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.waf_block_event.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.security_alerts.arn]
  }
}