# =====================================================================
# edge_security.tf — Lambda@Edge + CloudFront 보안 레이어 (Week 1)
#
# 리전 제약: Lambda@Edge는 반드시 us-east-1 배포.
#           기본 provider가 us-east-1이므로 별도 alias 불필요.
# =====================================================================

# ── 모델 저장용 S3 버킷 ───────────────────────────────────────────────
# module.security(WAF 모듈) destroy 시 기존 WAF 로그 버킷이 함께 삭제됨.
# Lambda@Edge 모델 파일은 WAF 로그와 분리된 전용 버킷에 보관.
resource "aws_s3_bucket" "model_store" {
  bucket        = "devsecops-edge-models-${var.account_id}"
  force_destroy = true
  tags          = { Project = "devsecops-platform", Purpose = "ml-model-storage" }
}

# AWS-0132: SSE-KMS 적용 — 공유 KMS 키로 모델 파일 암호화
# bucket_key_enabled: S3 Bucket Key 활성화 → KMS API 호출 ~99% 감소 (비용 최적화)
resource "aws_s3_bucket_server_side_encryption_configuration" "model_store" {
  bucket = aws_s3_bucket.model_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.shared_log_key.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "model_store" {
  bucket                  = aws_s3_bucket.model_store.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ISMS 2.10 — S3 HTTPS 전용 접근 강제
resource "aws_s3_bucket_policy" "model_store_ssl" {
  bucket     = aws_s3_bucket.model_store.id
  depends_on = [aws_s3_bucket_public_access_block.model_store]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.model_store.arn,
        "${aws_s3_bucket.model_store.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ── Lambda 패키지 압축 ────────────────────────────────────────────────
data "archive_file" "edge_security_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/edge_security"
  output_path = "${path.root}/../lambda/edge_security.zip"
}

# ── IAM 역할 ──────────────────────────────────────────────────────────
resource "aws_iam_role" "edge_lambda" {
  name = "devsecops-edge-lambda-role"

  # edgelambda.amazonaws.com 필수:
  # Lambda@Edge는 CloudFront가 대신 호출하므로 일반 lambda.amazonaws.com 단독으로는 실행 불가
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "edge_logs" {
  role = aws_iam_role.edge_lambda.name
  # CloudWatch Logs 쓰기 권한 — Lambda@Edge 로그는 각 엣지 리전에 분산 저장됨
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_role_policy" "edge_model_read" {
  name = "edge-model-read"
  role = aws_iam_role.edge_lambda.id

  # 최소 권한 원칙(PoLP): models/ 경로만 읽기, 쓰기·삭제 불가
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.model_store.arn}/models/*"
    }]
  })
}

# ── Lambda@Edge 함수 ──────────────────────────────────────────────────
resource "aws_lambda_function" "edge_security" {
  filename         = data.archive_file.edge_security_zip.output_path
  function_name    = "devsecops-edge-security"
  role             = aws_iam_role.edge_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.edge_security_zip.output_base64sha256
  publish          = true # Lambda@Edge는 $LATEST 사용 불가 — qualified_arn(버전 ARN) 필수
  memory_size      = 256  # JSON 모델 역직렬화 + boto3 로드 여유분 (Cold Start ~3~5s)
  timeout          = 15   # S3 다운로드 Cold Start 최대 ~8s 고려, Origin Request 한도 30s

  # Lambda@Edge 제약: 환경변수 미지원 → handler.py 내 상수(_S3_BUCKET 등)로 관리
}

# ── CloudFront 전용 WAF (CLOUDFRONT scope) ────────────────────────────
# AWS-0011: CloudFront WAF 미연결 경고 해소
# 기존 devsecops-waf는 REGIONAL scope → CloudFront 연결 불가 → 별도 CLOUDFRONT scope 생성
resource "aws_wafv2_web_acl" "cloudfront" {
  name  = "devsecops-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # GeoBlock은 CloudFront geo_restriction(KR whitelist)이 이미 처리 — 중복 제외

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
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
      metric_name                = "CloudFrontCRSMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
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
      metric_name                = "CloudFrontSQLiMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3
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
      metric_name                = "CloudFrontIPReputationMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "devsecops-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = { Project = "devsecops-platform" }
}

# ── CloudFront Functions (Viewer Request) ────────────────────────────
# Geo-block은 CloudFront 기본 geo_restriction(무료)으로, IP 차단만 여기서 담당
resource "aws_cloudfront_function" "ip_block" {
  name    = "devsecops-ip-block"
  runtime = "cloudfront-js-1.0"
  publish = true
  code    = file("${path.module}/cloudfront_functions/ip_block.js")
}

# ── CloudFront 배포 ───────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "DevSecOps 서버리스 보안 파이프라인 v1"

  # PriceClass_100: 북미+유럽 엣지만 활성화 — 가장 저렴한 옵션
  # 한국 트래픽은 자동으로 가장 가까운 POP(도쿄/홍콩 등)으로 라우팅됨
  price_class = "PriceClass_100"
  web_acl_id  = aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name = "${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com"
    origin_id   = "primary-origin"
    origin_path = "/${aws_api_gateway_stage.default.stage_name}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # 오리진 통신 암호화 강제
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "primary-origin"
    viewer_protocol_policy = "redirect-to-https" # HTTP → HTTPS 강제 리다이렉트
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true # 이상 탐지 피처로 QS 필요
      headers      = ["Authorization", "Content-Type", "User-Agent"]
      cookies { forward = "none" }
    }

    # CloudFront Functions: Viewer Request — 1ms 이하, IP 차단 담당
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.ip_block.arn
    }

    # Lambda@Edge Origin Request 단계 선택 이유:
    # - Viewer Request: 5s 제한, 1MB 패키지 → S3 모델 로드 Cold Start 시 초과 위험
    # - Origin Request: 30s 제한, 50MB 패키지 → Cold Start 여유 확보
    lambda_function_association {
      event_type   = "origin-request"
      lambda_arn   = aws_lambda_function.edge_security.qualified_arn # 버전 포함 ARN
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["KR"]
    }
  }

  # tfsec:ignore:aws-cloudfront-use-secure-tls-policy
  viewer_certificate {
    # 커스텀 도메인 미설정 시 *.cloudfront.net 기본 인증서 사용 (비용 0)
    cloudfront_default_certificate = true
  }

  tags = { Project = "devsecops-platform", Stage = "week1-edge-security" }
}

output "cloudfront_domain" {
  description = "CloudFront 배포 도메인 — 이 주소로 트래픽 인입"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "edge_lambda_version_arn" {
  description = "Lambda@Edge 버전 ARN (CloudFront 연결 확인용)"
  value       = aws_lambda_function.edge_security.qualified_arn
}
