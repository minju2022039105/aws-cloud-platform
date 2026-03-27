# ==========================================
# 1. 초기 설정 (Provider & Data Sources)
# ==========================================
# 최신 Ubuntu 24.04 AMI 검색
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical 공식 계정

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ==========================================
# 2. 인프라 모듈 (핵심 부품들)
# ==========================================

# 네트워크 (VPC, Subnet, IGW)
module "network" {
  source = "./vpc"
}

# 계정 권한 (IAM)
module "identity" {
  source = "./iam"
}

# 보안 설정 (WAF & S3 Logging)
module "security" {
  source = "./waf"
}

# 부하 분산 및 WAF 연결 (ALB)
module "alb" {
  source         = "./alb"
  vpc_id         = module.network.vpc_id
  public_subnets = module.network.public_subnet_ids
  instance_id    = aws_instance.security_node.id
}

# ==========================================
# 3. 개별 리소스 (EC2 & 보안 설정)
# ==========================================

# 분석용 EC2 서버 인스턴스
resource "aws_instance" "security_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer.key_name

  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [module.network.security_group_id]
  
  # ⭐️ 여기를 수정하세요! (문자열이 아니라 모듈의 결과값을 가져옵니다)
  iam_instance_profile   = module.identity.ec2_profile_name 

  tags = { Name = "DevSecOps-Analysis-Node" }
}

# ==========================================
# 4. 보안 접속 (SSH Key Pair)
# ==========================================

resource "tls_private_key" "rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = "devsecops-key"
  public_key = tls_private_key.rsa.public_key_openssh
}

resource "local_file" "private_key" {
  content  = tls_private_key.rsa.private_key_pem
  filename = "my-key.pem"
}

# ==========================================
# 5. 최종 연결 (WAF + ALB Association)
# ==========================================

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = module.alb.alb_arn
  web_acl_arn  = module.security.web_acl_arn
}

# main.tf 파일 하단부 확인
# 고정 IP (EIP) 할당
resource "aws_eip" "analysis_node_eip" {
  instance = aws_instance.security_node.id
  domain   = "vpc"

  tags = { Name = "DevSecOps-Fixed-IP" }
}