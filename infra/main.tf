# ==========================================
# 1. 인프라 모듈
# ==========================================

# 네트워크 및 IAM
module "network" {
  source = "./modules/vpc"

  my_ip          = var.my_ip
  account_id     = var.account_id
  s3_bucket_name = var.s3_bucket_name
  kms_key_arn    = var.kms_key_arn
  waf_ipset_arn  = module.security.ai_block_list_arn
}

# 보안 설정 (WAF)
module "security" {
  source             = "./modules/waf"
  shared_kms_key_arn = aws_kms_key.shared_log_key.arn
  s3_bucket_name     = var.s3_bucket_name
  account_id         = var.account_id
  trusted_ip_ranges  = var.waf_trusted_ip_ranges
  alert_email        = var.alert_email
}

# ==========================================
# 2. 공유 보안 자원
# ==========================================

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
# 3. 알림 설정
# ==========================================

resource "aws_sns_topic" "security_alerts" {
  name              = "devsecops-security-alerts"
  # AWS-0095: 전송 중 및 저장 데이터 암호화 — 알림 내용(IP, 공격 유형) 보호
  kms_master_key_id = aws_kms_key.shared_log_key.id
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
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
