# ==========================================
# 1. EC2 & Lambda Role (분리)
# ==========================================

# EC2 Role

resource "aws_iam_role" "ec2_ai_role" {
  name = "devsecops-ec2-ai-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# Lambda role

resource "aws_iam_role" "lambda_blocker_role" {
  name = "devsecops-lambda-blocker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# ==========================================
# 1.1 EC2 AI Role Policy
# ==========================================

resource "aws_iam_policy" "ec2_ai_policy" {
  name        = "devsecops-ec2-ai-policy"
  description = "Least privilege policy for EC2 AI analysis engine"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWAFLogsFromS3"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-waf-logs-minju-0417-project",
          "arn:aws:s3:::aws-waf-logs-minju-0417-project/*"
        ]
      },
      {
        Sid    = "DecryptWAFLogBucketKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "arn:aws:kms:us-east-1:095035153545:key/f05a310f-3c92-4b81-af3d-a51050e17b46"
      },
      {
        Sid    = "RunAthenaQueries"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetWorkGroup"
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadGlueCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Sid    = "PutCustomMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "WriteCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==========================================
# 1.2. Lambda Blocker Policy
# ==========================================
resource "aws_iam_policy" "lambda_blocker_policy" {
  name        = "devsecops-lambda-blocker-policy"
  description = "Least privilege policy for Lambda WAF IPSet blocker"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAIResultFromS3"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::aws-waf-logs-minju-0417-project/results/*"
      },
      {
        Sid    = "UpdateWAFIPSet"
        Effect = "Allow"
        Action = [
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet"
        ]
        Resource = "arn:aws:wafv2:us-east-1:095035153545:regional/ipset/devsecops-ai-block-list/266e5501-31b8-46ca-b3eb-3a58c28c51f7"
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==========================================
# 3. Policy Attachments
# ==========================================

resource "aws_iam_role_policy_attachment" "ec2_ai_attach" {
  role       = aws_iam_role.ec2_ai_role.name
  policy_arn = aws_iam_policy.ec2_ai_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_blocker_attach" {
  role       = aws_iam_role.lambda_blocker_role.name
  policy_arn = aws_iam_policy.lambda_blocker_policy.arn
}

# ==========================================
# 4. EC2 Instance Profile
# ==========================================

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "devsecops-ec2-profile"
  role = aws_iam_role.ec2_ai_role.name
}

# ==========================================
# 5. GitHub Actions OIDC
# ==========================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1c5877c10b42798e692138096e47c13459e984d7"]
}

resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:minju2022039105/aws-devsecops-platform:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

