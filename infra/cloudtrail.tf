# ==========================================
# 로깅 & 감사 체계: CloudTrail + Access Analyzer
# ==========================================

# CloudTrail 전용 S3 버킷 (WAF 버킷과 분리 — 버킷 정책 충돌 방지)
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${var.project_name}-cloudtrail-${var.account_id}"
  force_destroy = true
  tags          = { Name = "cloudtrail-logs", Project = var.project_name }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.shared_log_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# CloudTrail + VPC Flow Logs 쓰기 권한 버킷 정책
resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket     = aws_s3_bucket.cloudtrail_logs.id
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonSSL"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.cloudtrail_logs.arn,
          "${aws_s3_bucket.cloudtrail_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "CloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${var.account_id}:trail/${var.project_name}-trail"
          }
        }
      },
      {
        Sid    = "CloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
            "AWS:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${var.account_id}:trail/${var.project_name}-trail"
          }
        }
      },
      {
        Sid    = "VPCFlowLogAclCheck"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "VPCFlowLogWrite"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/vpc-flow-logs/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# CloudTrail 활성화 (전 리전 + 로그 무결성 검증)
resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.shared_log_key.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags       = { Project = var.project_name }
  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}

# IAM Access Analyzer — 계정 전체 외부 접근 가능 리소스 자동 탐지
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${var.project_name}-account-analyzer"
  type          = "ACCOUNT"
  tags          = { Project = var.project_name }
}

# VPC Flow Logs → S3 장기 보관 (CloudWatch 버전은 modules/vpc/main.tf에 이미 존재)
# 30일 이상 보존이 필요한 감사 로그를 S3에 병렬 전송
resource "aws_flow_log" "s3_archive" {
  vpc_id               = module.network.vpc_id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${aws_s3_bucket.cloudtrail_logs.arn}/vpc-flow-logs/"

  tags       = { Name = "devsecops-vpc-flow-s3", Project = var.project_name }
  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}
