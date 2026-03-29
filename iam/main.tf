# ==========================================
# 1. EC2 & Lambda Role (전체 통합 버전)
# ==========================================
resource "aws_iam_role" "ec2_role" {
  name = "devsecops-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { 
        Service = [
          "ec2.amazonaws.com",
          "lambda.amazonaws.com"
        ]
      }
    }]
  })
}

resource "aws_iam_policy" "s3_access_policy" {
  name        = "devsecops-s3-access-policy"
  description = "Allow EC2 and Lambda to access S3, KMS, Athena, CloudWatch and WAF"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # (1) S3 권한
      {
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject","s3:GetBucketLocation","s3:GetEncryptionConfiguration"]
        Effect   = "Allow"
        Resource = [
          "arn:aws:s3:::aws-waf-logs-minju-0417-project",
          "arn:aws:s3:::aws-waf-logs-minju-0417-project/*"
        ]
      },
      # (2) KMS 권한
      {
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Effect   = "Allow"
        Resource = "arn:aws:kms:us-east-1:095035153545:key/f05a310f-3c92-4b81-af3d-a51050e17b46"
      },
      # (3) Athena & CloudWatch 권한
      {
        Action = [
          "athena:*",
          "glue:*",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      # (4) 람다 호출 권한
      {
        Action   = "lambda:InvokeFunction"
        Effect   = "Allow"
        Resource = "*"
      },
      # 🔥 (5) 추가: WAF IP Set 수정 권한 
      {
        Action = [
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:wafv2:us-east-1:095035153545:regional/ipset/devsecops-ai-block-list/266e5501-31b8-46ca-b3eb-3a58c28c51f7"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

# ==========================================
# 2. IAM Admin User for Terraform
# ==========================================
resource "aws_iam_user" "devsecops_admin" {
  name = "devsecops-admin-user"
  path = "/system/"
}

resource "aws_iam_user_policy_attachment" "admin_attach" {
  user       = aws_iam_user.devsecops_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "admin_key" {
  user = aws_iam_user.devsecops_admin.name
}

# ==========================================
# 3. EC2 Instance Profile (에러 해결용 추가)
# ==========================================
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "devsecops-ec2-profile"
  role = aws_iam_role.ec2_role.name
}
# ==========================================
# 4. GitHub Actions OIDC (보안 강화용)
# ==========================================

# 1. GitHub을 믿을 수 있는 공급자로 등록
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["1c5877c10b42798e692138096e47c13459e984d7"]
}

# 2. GitHub Actions 로봇이 빌려 쓸 Role 생성
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
          # 민주님의 GitHub 계정명/레포이름으로 딱 제한! (보안의 핵심)
          "token.actions.githubusercontent.com:sub" = "repo:minju2022039105/aws-devsecops-platform:*"
        }
      }
    }]
  })
}

# 3. 로봇에게 줄 권한 (EC2 관리 권한)
resource "aws_iam_role_policy_attachment" "github_actions_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# 4. root의 main.tf에서 이 값을 쓰기 위해 출력 설정
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_role.arn
}