#!/bin/bash
# =============================================================
# wakeup.sh — 인프라 재시작 (공부 시작할 때 실행)
#
# cleanup.sh 로 내린 리소스를 다시 올립니다:
#   ALB + EIP → terraform apply
#   EC2       → aws ec2 start-instances
# =============================================================

set -e

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
REGION="us-east-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  DevSecOps Wakeup — 인프라 재시작     ${NC}"
echo -e "${CYAN}========================================${NC}"

# ── 1. ALB + EIP terraform apply ─────────────────────────────
echo -e "\n${YELLOW}[1/3] ALB / EIP 재생성 중 (terraform apply)...${NC}"

cd "$INFRA_DIR"

terraform apply \
  -target=module.alb \
  -target=aws_eip.analysis_node_eip \
  -target=aws_security_group_rule.allow_alb_to_ec2 \
  -auto-approve

echo -e "  ${GREEN}✓ ALB / EIP 재생성 완료${NC}"

# ── 2. EC2 시작 ───────────────────────────────────────────────
echo -e "\n${YELLOW}[2/3] EC2 인스턴스 시작 중...${NC}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=DevSecOps-Analysis-Node" \
            "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo -e "${RED}  EC2 인스턴스를 찾을 수 없습니다. terraform apply 전체를 실행해주세요.${NC}"
  echo -e "  cd infra && terraform apply"
  exit 1
fi

INSTANCE_STATE=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text)

if [ "$INSTANCE_STATE" = "running" ]; then
  echo -e "  ${YELLOW}이미 실행 중입니다. 스킵.${NC}"
else
  aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
  echo -e "  ${GREEN}✓ EC2 시작 요청 완료. 준비까지 약 30~60초 소요됩니다.${NC}"

  # running 상태 될 때까지 대기
  echo -e "  running 상태 대기 중..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
  echo -e "  ${GREEN}✓ EC2 running 상태 확인${NC}"
fi

# ── 3. EIP를 EC2에 재연결 (terraform apply로 처리) ───────────
echo -e "\n${YELLOW}[3/3] EIP 연결 상태 동기화 중...${NC}"
terraform apply -target=aws_eip.analysis_node_eip -auto-approve

# ── 4. 접속 정보 출력 ─────────────────────────────────────────
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Wakeup 완료! 접속 정보:${NC}"
echo -e "${GREEN}========================================${NC}"

terraform output 2>/dev/null || true

echo ""
