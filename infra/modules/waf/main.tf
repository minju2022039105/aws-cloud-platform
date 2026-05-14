resource "aws_s3_bucket" "waf_logs" {
  bucket        = var.s3_bucket_name
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

# ISMS 2.10 — S3 HTTPS 전용 접근 강제
resource "aws_s3_bucket_policy" "waf_logs_ssl" {
  bucket     = aws_s3_bucket.waf_logs.id
  depends_on = [aws_s3_bucket_public_access_block.waf_logs_block]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [
        aws_s3_bucket.waf_logs.arn,
        "${aws_s3_bucket.waf_logs.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# 2.1. KMS 키 정책 정의 (WAF 로깅 권한 포함)
resource "aws_kms_key" "waf_s3_key" {
  description             = "KMS key for WAF S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # [Statement 1] 루트 및 관리자(민주님) 권한
      {
        Sid    = "Enable Admin Privilege"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${var.account_id}:root",
            "arn:aws:iam::${var.account_id}:user/system/devsecops-admin-user"
          ]
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # [Statement 2] WAF 로깅 서비스 허용 
      {
        Sid    = "Allow WAF Log Delivery to use the key"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      # [Statement 3] S3 서비스를 통한 접근 (기존 정책 유지)[cite: 1]
      {
        Sid    = "Allow S3 Access"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "s3.us-east-1.amazonaws.com",
            "kms:CallerAccount" = var.account_id
          }
        }
      }
    ]
  })
}

# 2.2 S3 버킷 암호화 설정 (위에서 만든 키와 연결)
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs_encryption" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    apply_server_side_encryption_by_default {
      # 변수 대신 위에서 정의한 키의 ARN을 직접 참조하여 오류 방지
      kms_master_key_id = aws_kms_key.waf_s3_key.arn 
      sse_algorithm     = "aws:kms"
    }
    # S3 Bucket Key 활성화로 KMS 호출 비용 최적화[cite: 1]
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

# [Priority 0] Geo-Blocking (KR 전용) - 임시 COUNT 모드 (end-to-end 테스트용, 테스트 후 block으로 복귀)
  rule {
    name     = "GeoBlock-Non-KR"
    priority = 0
    action {
      count {}
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

  # [Priority 2] SQL 인젝션 방어 — /admin/* URI와 신뢰 IP는 검사 제외 (Scope-down)
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

        # Scope-down: 아래 조건에 해당하는 요청만 WAF가 검사함
        # 조건에 해당하지 않으면 이 룰을 완전히 건너뜀
        scope_down_statement {
          not_statement {
            statement {
              # trusted_ip_ranges가 있으면 or_statement(URI + IP 둘 다 제외),
              # 없으면 byte_match_statement만 단독 사용 — or_statement는 2개 이상 필요
              dynamic "or_statement" {
                for_each = length(var.trusted_ip_ranges) > 0 ? [1] : []
                content {
                  statement {
                    byte_match_statement {
                      field_to_match {
                        uri_path {}
                      }
                      positional_constraint = "STARTS_WITH"
                      search_string         = "/admin/"
                      text_transformation {
                        priority = 0
                        type     = "LOWERCASE"
                      }
                    }
                  }
                  statement {
                    ip_set_reference_statement {
                      arn = aws_wafv2_ip_set.trusted_ips[0].arn
                    }
                  }
                }
              }
              dynamic "byte_match_statement" {
                for_each = length(var.trusted_ip_ranges) == 0 ? [1] : []
                content {
                  field_to_match {
                    uri_path {}
                  }
                  positional_constraint = "STARTS_WITH"
                  search_string         = "/admin/"
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "awsSQLiRules"
      sampled_requests_enabled   = true
    }
  }

  # [Priority 3] 일반 웹 취약점 방어 — /health, /metrics 같은 내부 경로 제외
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

        scope_down_statement {
          not_statement {
            statement {
              or_statement {
                statement {
                  byte_match_statement {
                    field_to_match {
                      uri_path {}
                    }
                    positional_constraint = "STARTS_WITH"
                    search_string         = "/health"
                    text_transformation {
                      priority = 0
                      type     = "LOWERCASE"
                    }
                  }
                }
                statement {
                  byte_match_statement {
                    field_to_match {
                      uri_path {}
                    }
                    positional_constraint = "STARTS_WITH"
                    search_string         = "/metrics"
                    text_transformation {
                      priority = 0
                      type     = "LOWERCASE"
                    }
                  }
                }
              }
            }
          }
        }
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

# WAF 로깅 설정 
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_s3_bucket.waf_logs.arn]

  # 팁: 로그 필터링을 추가하면 필요한 데이터(공격 로그)만 골라 쌓을 수 있어요!
  logging_filter {
    default_behavior = "KEEP" # 기본적으로 모든 로그 유지
    filter {
      behavior = "KEEP"
      condition {
        action_condition {
          action = "BLOCK" 
        }
      }
      requirement = "MEETS_ANY"
    }
  }
}

# 5-a. Scope-down용 신뢰 IP Set (var.trusted_ip_ranges가 있을 때만 생성)
resource "aws_wafv2_ip_set" "trusted_ips" {
  count              = length(var.trusted_ip_ranges) > 0 ? 1 : 0
  name               = "devsecops-trusted-ips"
  description        = "WAF Scope-down 검사 제외 신뢰 IP 대역"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.trusted_ip_ranges
}

# 5-b. AI 차단용 IP Set 생성
resource "aws_wafv2_ip_set" "ai_block_list" {
  name               = "devsecops-ai-block-list"
  description        = "IP set managed by AI anomaly detection engine"
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
    subscriber_email_addresses = [var.alert_email]
  }
}