# ==========================================
# VPC & Networking
# ==========================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "devsecops-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "devsecops-public-1a" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = { Name = "devsecops-public-1b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "devsecops-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# EC2 보안 그룹 (port 80 ALB→EC2 ingress는 루트 모듈의 aws_security_group_rule로 분리)
resource "aws_security_group" "main_sg" {
  name   = "devsecops-main-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.my_ip
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.my_ip
    description = "Allow Grafana access from admin IP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# ==========================================
# IAM (VPC 모듈에 통합)
# ==========================================

resource "aws_iam_role" "ec2_ai_role" {
  name = "devsecops-ec2-ai-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "lambda_blocker_role" {
  name = "devsecops-lambda-blocker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "ec2_ai_policy" {
  name        = "devsecops-ec2-ai-policy"
  description = "Least privilege policy for EC2 AI analysis engine"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWAFLogsFromS3"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*"
        ]
      },
      {
        Sid      = "DecryptWAFLogBucketKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.kms_key_arn
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
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Sid      = "PutCustomMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid    = "WriteCloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_blocker_policy" {
  name        = "devsecops-lambda-blocker-policy"
  description = "Least privilege policy for Lambda WAF IPSet blocker"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAIResultFromS3"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/results/*"
      },
      {
        Sid    = "UpdateWAFIPSet"
        Effect = "Allow"
        Action = ["wafv2:GetIPSet", "wafv2:UpdateIPSet"]
        Resource = var.waf_ipset_arn
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ai_attach" {
  role       = aws_iam_role.ec2_ai_role.name
  policy_arn = aws_iam_policy.ec2_ai_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_blocker_attach" {
  role       = aws_iam_role.lambda_blocker_role.name
  policy_arn = aws_iam_policy.lambda_blocker_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "devsecops-ec2-profile"
  role = aws_iam_role.ec2_ai_role.name
}

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

# modules/vpc/main.tf

resource "aws_iam_policy" "github_actions_minimal_policy" {
  name        = "github-actions-minimal-policy"
  description = "Super-refined minimal permissions for DevSecOps"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 기초 인프라 조회 및 VPC 관리
        Effect   = "Allow"
        Action   = [
          "ec2:Describe*",
          "ec2:CreateVpc",
          "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet",
          "ec2:CreateSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        # [핵심] 인스턴스 생성 시 t3.micro만 허용 (비용 폭탄 방지)
        Effect   = "Allow"
        Action   = ["ec2:RunInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:InstanceType" = ["t3.micro"]
          }
        }
      },
      {
        # 정지/삭제 시 특정 태그가 달린 리소스만 제어 허용
        Effect   = "Allow"
        Action   = ["ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = "devsecops-platform"
          }
        }
      },
      {
        # ALB 세부 권한 (Wildcard 제거 버전)
        Effect   = "Allow"
        Action   = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:AddTags"
        ]
        Resource = "*"
      }
    ]
  })
}