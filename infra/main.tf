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

  my_ip          = var.my_ip
  account_id     = var.account_id
  s3_bucket_name = var.s3_bucket_name
  kms_key_arn    = var.kms_key_arn
  waf_ipset_arn  = var.waf_ipset_arn
}

# 2. 보안 설정 (WAF)
module "security" {
  source             = "./modules/waf"
  shared_kms_key_arn = aws_kms_key.shared_log_key.arn
  s3_bucket_name     = var.s3_bucket_name
  account_id         = var.account_id
  trusted_ip_ranges  = var.waf_trusted_ip_ranges
}

# 3. 부하 분산 (ALB)
module "alb" {
  source          = "./modules/alb"
  vpc_id          = module.network.vpc_id
  public_subnets  = module.network.public_subnet_ids
  instance_id     = aws_instance.security_node.id
  my_ip           = var.my_ip
  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id
}

# ==========================================
# 3. 개별 리소스 (EC2)
# ==========================================

resource "aws_instance" "security_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [module.network.security_group_id]

  iam_instance_profile = module.network.ec2_instance_profile_name

  # AWS-0028: IMDSv2 강제 — 토큰 없이 메타데이터 접근 불가 (SSRF 방어)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # AWS-0131: 루트 볼륨 암호화 — 물리 디스크 탈취 시 데이터 보호
  root_block_device {
    encrypted  = true
    kms_key_id = aws_kms_key.shared_log_key.arn
  }

  tags = { Name = "DevSecOps-Analysis-Node", Project = "devsecops-platform" }
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

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudTrailEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:${var.aws_region}:${var.account_id}:trail/${var.project_name}-trail"
          }
        }
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
          }
        }
      }
    ]
  })
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
  name              = "devsecops-security-alerts"
  # AWS-0095: 전송 중 및 저장 데이터 암호화 — 알림 내용(IP, 공격 유형) 보호
  kms_master_key_id = aws_kms_key.shared_log_key.id
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