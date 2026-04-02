resource "aws_s3_bucket" "waf_logs" {
  bucket        = "aws-waf-logs-minju-0417-project"
  force_destroy = true
}

# 1. S3 퍼블릭 액세스 차단 (보안 강화)
resource "aws_s3_bucket_public_access_block" "waf_logs_block" {
  bucket = aws_s3_bucket.waf_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. KMS 암호화 및 비용 최적화 설정
resource "aws_kms_key" "waf_s3_key" {
  description             = "KMS key for WAF S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable Admin Privilege"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::095035153545:root" 
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs_encryption" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.waf_s3_key.arn
      sse_algorithm     = "aws:kms"
    }
    # [비용 최적화] S3 Bucket Key 활성화로 KMS 호출 비용 절감
    bucket_key_enabled = true 
  }
}

# 3. WAF Web ACL (리드미 우선순위 0~4 반영)
resource "aws_wafv2_web_acl" "main" {
  name        = "devsecops-waf"
  description = "WAF with Geo-Blocking and AIOps SOAR"
  scope       = "REGIONAL"

  default_action {
    allow {} 
  }

# [Priority 0] Geo-Blocking (KR 전용) - 한국 외 IP 차단
  rule {
    name     = "GeoBlock-Non-KR"
    priority = 0 
    action {
      block {} 
    }
    statement {
      not_statement {
        statement { # 이 statement 블록이 반드시 들어가야 에러가 해결됩니다.
          geo_match_statement {
            country_codes = ["KR"]
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "geoBlockNonKR"
      sampled_requests_enabled   = true
    }
  }
    
  # [Priority 1] AI 기반 실시간 차단 (SOAR 자동 대응)
  rule {
    name     = "AI-RealTime-Block-Rule"
    priority = 1
    action {
      block {} 
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.ai_block_list.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aiRealTimeBlock"
      sampled_requests_enabled   = true
    }
  }

  # [Priority 2] SQL 인젝션 방어 (Managed Rule)
  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "awsSQLiRules"
      sampled_requests_enabled   = true
    }
  }

  # [Priority 3] 일반 웹 취약점 방어 (Common Rule Set)
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "awsCommonRules"
      sampled_requests_enabled   = true
    }
  }

  # [Priority 4] IP Reputation List (악성 IP 사전 차단)
  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 4
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "awsReputationRules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "devsecopsWAF"
    sampled_requests_enabled   = true
  }
}

# 4. WAF 로깅 설정 (S3 연결)
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_s3_bucket.waf_logs.arn]
}

# 5. AI 차단용 IP Set 생성
resource "aws_wafv2_ip_set" "ai_block_list" {
  name               = "devsecops-ai-block-list"
  description        = "IP set managed by Security-AIOps-IsolationForest"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = [] 
}

# 6. 비용 거버넌스 알람 (KMS/S3 예산 관리)
resource "aws_budgets_budget" "s3_kms_monitor" {
  name              = "monthly-devsecops-budget"
  budget_type       = "COST"
  limit_amount      = "10"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80 
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["mingmingdo30@gmail.com"]
  }
}