resource "aws_s3_bucket" "waf_logs" {
  bucket        = "aws-waf-logs-minju-0417-project"
  force_destroy = true
}

# 1. 퍼블릭 액세스 차단 (Result #1, #2, #4, #5, #10 해결)
resource "aws_s3_bucket_public_access_block" "waf_logs_block" {
  bucket = aws_s3_bucket.waf_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. 기본 암호화 설정 (KMS 비용 최적화 및 권한 확보 버전)
resource "aws_kms_key" "waf_s3_key" {
  description             = "KMS key for WAF S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # [추가] Root 계정이 키를 제어할 수 있도록 정책 명시
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable Admin Privilege"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::095035153545:root" # 민주님 계정 ID
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
    # [추가] 600만 건의 API 호출 비용을 막아주는 핵심 옵션
    bucket_key_enabled = true 
  }
}

# 3. 버전 관리 활성화 (Result #9 해결)
resource "aws_s3_bucket_versioning" "waf_logs_versioning" {
  bucket = aws_s3_bucket.waf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 4. 액세스 로깅 활성화 (Result #8 해결)
# 실제 프로젝트에서는 별도의 로깅 전용 버킷을 지정하는 것이 좋으나, 우선 자기 자신으로 설정
resource "aws_s3_bucket_logging" "waf_logs_logging" {
  bucket = aws_s3_bucket.waf_logs.id

  target_bucket = aws_s3_bucket.waf_logs.id
  target_prefix = "log/"
}

# 5. 진짜 WAF Web ACL 생성 (규칙 추가 버전!)
resource "aws_wafv2_web_acl" "main" {
  name        = "devsecops-waf"
  description = "WAF for ALB with Managed Rules"
  scope       = "REGIONAL"

  default_action {
    allow {} 
  }

  # [추가] 규칙 0: AI 기반 실시간 차단 리스트 검사
  rule {
    name     = "AI-RealTime-Block-Rule"
    priority = 0 # 가장 먼저 검사하도록 0번 부여
    action {
      block {} # 리스트에 있으면 즉시 차단
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

  # [규칙 1] 가장 일반적인 웹 공격 방어 (Common Rule Set)
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1 # 우선순위 1번
    override_action {
      none {} # 차단(Block)을 그대로 수행함
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

  # [규칙 2] SQL 인젝션 방어 (SQLi Rule Set)
  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 2 # 우선순위 2번
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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "devsecopsWAF"
    sampled_requests_enabled   = true
  }
}

# 6. WAF 로깅 설정 (방금 만든 S3 버킷과 WAF를 연결)
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_s3_bucket.waf_logs.arn] # 위에서 만든 버킷 ARN
}

# [추가] AI 차단용 IP Set 생성
# [수정본] visibility_config 블록을 제거했습니다.
resource "aws_wafv2_ip_set" "ai_block_list" {
  name               = "devsecops-ai-block-list"
  description        = "IP set managed by Security-AIOps-IsolationForest"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = [] 
}

resource "aws_budgets_budget" "s3_kms_monitor" {
  name              = "monthly-devsecops-budget"
  budget_type       = "COST"
  limit_amount      = "10" # 10달러 넘으면 바로 나한테 알려줘!
  limit_unit        = "USD"
  time_unit         = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80 # 예산의 80%($8) 사용 시 알림
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["민주님 메일 주소"] 
  }
}