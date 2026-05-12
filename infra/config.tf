# ==========================================
# ISMS 컴플라이언스: AWS Config
# ==========================================

resource "aws_iam_role" "config" {
  name = "${var.project_name}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 기존 cloudtrail 버킷에 Config 쓰기 권한 추가
resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-delivery"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/config/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.project_name}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# 기존 cloudtrail S3 버킷 + SNS 토픽 재사용
resource "aws_config_delivery_channel" "main" {
  name           = "${var.project_name}-config-channel"
  s3_bucket_name = aws_s3_bucket.cloudtrail_logs.id
  s3_key_prefix  = "config"
  sns_topic_arn  = aws_sns_topic.security_alerts.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ==========================================
# ISMS 통제항목 기반 Config Rules
# ==========================================

# ISMS 2.5 인증 및 권한관리 — root 액세스 키 미사용
resource "aws_config_config_rule" "iam_root_access_key" {
  name        = "isms-2-5-iam-root-access-key-check"
  description = "ISMS 2.5: root 계정 액세스 키 없는지 확인"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.5 인증 및 권한관리 — IAM 패스워드 정책
resource "aws_config_config_rule" "iam_password_policy" {
  name        = "isms-2-5-iam-password-policy"
  description = "ISMS 2.5: IAM 패스워드 복잡성 정책 적용 확인"

  source {
    owner             = "AWS"
    source_identifier = "IAM_PASSWORD_POLICY"
  }

  input_parameters = jsonencode({
    RequireUppercaseCharacters = "true"
    RequireLowercaseCharacters = "true"
    RequireSymbols             = "true"
    RequireNumbers             = "true"
    MinimumPasswordLength      = "14"
    PasswordReusePrevention    = "3"
    MaxPasswordAge             = "90"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.5 인증 및 권한관리 — 콘솔 접근 MFA 활성화
resource "aws_config_config_rule" "mfa_enabled" {
  name        = "isms-2-5-mfa-enabled-for-iam-console"
  description = "ISMS 2.5: 콘솔 접근 IAM 사용자 MFA 활성화 확인"

  source {
    owner             = "AWS"
    source_identifier = "MFA_ENABLED_FOR_IAM_CONSOLE_ACCESS"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.6 접근통제 — S3 퍼블릭 읽기 차단
resource "aws_config_config_rule" "s3_no_public_read" {
  name        = "isms-2-6-s3-public-read-prohibited"
  description = "ISMS 2.6: S3 버킷 퍼블릭 읽기 접근 차단 확인"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.6 접근통제 — S3 퍼블릭 쓰기 차단
resource "aws_config_config_rule" "s3_no_public_write" {
  name        = "isms-2-6-s3-public-write-prohibited"
  description = "ISMS 2.6: S3 버킷 퍼블릭 쓰기 접근 차단 확인"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.6 접근통제 — VPC 기본 보안그룹 비활성화
resource "aws_config_config_rule" "vpc_default_sg_closed" {
  name        = "isms-2-6-vpc-default-sg-closed"
  description = "ISMS 2.6: VPC 기본 보안그룹에 인바운드/아웃바운드 규칙 없는지 확인"

  source {
    owner             = "AWS"
    source_identifier = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.9 로그 관리 — CloudTrail 활성화
resource "aws_config_config_rule" "cloudtrail_enabled" {
  name        = "isms-2-9-cloudtrail-enabled"
  description = "ISMS 2.9: CloudTrail 트레일 활성화 확인"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.9 로그 관리 — CloudTrail 로그 무결성 검증
resource "aws_config_config_rule" "cloudtrail_log_validation" {
  name        = "isms-2-9-cloudtrail-log-validation"
  description = "ISMS 2.9: CloudTrail 로그 파일 무결성 검증 활성화 확인"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.10 시스템 보안관리 — S3 전송 암호화(SSL)
resource "aws_config_config_rule" "s3_ssl_only" {
  name        = "isms-2-10-s3-ssl-requests-only"
  description = "ISMS 2.10: S3 버킷 HTTPS 전용 접근 확인"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SSL_REQUESTS_ONLY"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.10 시스템 보안관리 — EBS 볼륨 암호화
resource "aws_config_config_rule" "ebs_encrypted" {
  name        = "isms-2-10-encrypted-volumes"
  description = "ISMS 2.10: EC2 인스턴스 연결 EBS 볼륨 암호화 확인"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ISMS 2.11 사고 예방 및 대응 — GuardDuty 활성화
resource "aws_config_config_rule" "guardduty_enabled" {
  name        = "isms-2-11-guardduty-enabled"
  description = "ISMS 2.11: GuardDuty 위협 탐지 서비스 활성화 확인"

  source {
    owner             = "AWS"
    source_identifier = "GUARDDUTY_ENABLED_CENTRALIZED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ==========================================
# Config NON_COMPLIANT 이벤트 → 기존 SNS 알림 연동
# ==========================================

resource "aws_cloudwatch_event_rule" "config_compliance" {
  name        = "config-compliance-change"
  description = "Config 컴플라이언스 위반 시 알림"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "config_sns" {
  rule      = aws_cloudwatch_event_rule.config_compliance.name
  target_id = "ConfigToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

# ==========================================
# ISMS 2.11 사고 예방 및 대응 — GuardDuty 활성화
# ==========================================

resource "aws_guardduty_detector" "main" {
  enable = true
  tags   = { Project = var.project_name }
}

# ==========================================
# ISMS 2.5 인증 및 권한관리 — IAM 패스워드 정책
# ==========================================

resource "aws_iam_account_password_policy" "main" {
  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}
