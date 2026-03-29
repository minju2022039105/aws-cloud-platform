# ==========================================
# 1. 초기 설정 (Provider & Data Sources)
# ==========================================
# 최신 Ubuntu 24.04 AMI 검색
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical 공식 계정

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ==========================================
# 2. 인프라 모듈 (핵심 부품들)
# ==========================================

# 네트워크 (VPC, Subnet, IGW)
module "network" {
  source = "./vpc"
}

# 계정 권한 (IAM)
module "identity" {
  source = "./iam"
}

# 보안 설정 (WAF & S3 Logging)
module "security" {
  source = "./waf"
}

# 부하 분산 및 WAF 연결 (ALB)
module "alb" {
  source         = "./alb"
  vpc_id         = module.network.vpc_id
  public_subnets = module.network.public_subnet_ids
  instance_id    = aws_instance.security_node.id
}

# ==========================================
# 3. 개별 리소스 (EC2 & 보안 설정)
# ==========================================

# 분석용 EC2 서버 인스턴스
resource "aws_instance" "security_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer.key_name

  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [module.network.security_group_id]
  
  # ⭐️ 여기를 수정하세요! (문자열이 아니라 모듈의 결과값을 가져옵니다)
  iam_instance_profile   = module.identity.ec2_profile_name 

  tags = { Name = "DevSecOps-Analysis-Node" }
}

# ==========================================
# 4. 보안 접속 (SSH Key Pair)
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

# ==========================================
# 5. 최종 연결 (WAF + ALB Association)
# ==========================================

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = module.alb.alb_arn
  web_acl_arn  = module.security.web_acl_arn
}

# main.tf 파일 하단부 확인
# 고정 IP (EIP) 할당
resource "aws_eip" "analysis_node_eip" {
  instance = aws_instance.security_node.id
  domain   = "vpc"

  tags = { Name = "DevSecOps-Fixed-IP" }
}

# ==========================================
# 6. EventBridge + SNS 메일 알림 테라폼 코드
# ==========================================
# 1. 알림을 보낼 SNS 주제(Topic) 생성
resource "aws_sns_topic" "security_alerts" {
  name = "devsecops-security-alerts"
}

# 2. 이메일 구독 설정 (민주님 메일 주소 입력)
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "민주님_메일_주소@example.com" # 여기에 실제 메일 주소를 적으세요!
}

# 3. EventBridge 규칙 생성 (예: WAF에서 차단 이벤트 발생 시)
resource "aws_cloudwatch_event_rule" "waf_block_event" {
  name        = "waf-block-detection"
  description = "Capture WAF Block events and send notification"

  event_pattern = jsonencode({
    "source": ["aws.wafv2"],
    "detail-type": ["WAF Configuration Change", "AWS API Call via CloudTrail"],
    "detail": {
      "eventName": ["UpdateWebACL", "DeleteWebACL"]
    }
  })
}

# 4. EventBridge 타겟을 SNS로 설정
resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.waf_block_event.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

# 5. SNS 정책 설정 (EventBridge가 SNS에 메시지를 보낼 수 있게 허용)
resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    actions   = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.security_alerts.arn]
  }
}