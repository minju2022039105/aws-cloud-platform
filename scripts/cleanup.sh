#!/bin/bash
# =============================================================
# cleanup.sh — 비용 절약 모드 (공부 끝났을 때 실행)
#
# 절약 효과:
#   ALB        ~$16/월  → destroy
#   EC2        ~$7.5/월 → stop  (디스크 데이터 보존)
#   EIP        ~$3.6/월 → destroy (정지 인스턴스에 붙어있으면 과금)
#   합계       ~$27/월 절약
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
echo -e "${CYAN}  DevSecOps Cleanup — 비용 절약 모드   ${NC}"
echo -e "${CYAN}========================================${NC}"

# ── 1. EC2 인스턴스 ID 조회 ──────────────────────────────────
echo -e "\n${YELLOW}[1/3] EC2 인스턴스 조회 중...${NC}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=DevSecOps-Analysis-Node" \
            "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo -e "${YELLOW}  EC2 인스턴스를 찾을 수 없습니다. 이미 정지됐거나 없을 수 있어요.${NC}"
else
  INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)

  echo -e "  인스턴스: ${CYAN}$INSTANCE_ID${NC} (현재 상태: $INSTANCE_STATE)"

  if [ "$INSTANCE_STATE" = "running" ]; then
    echo -e "  EC2 정지 중... (디스크 데이터는 보존됩니다)"
    aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
    echo -e "  ${GREEN}✓ EC2 정지 요청 완료${NC} (완전 정지까지 약 30초 소요)"
  else
    echo -e "  ${YELLOW}이미 정지 상태입니다. 스킵.${NC}"
  fi
fi

# ── 2. ALB + EIP terraform destroy ───────────────────────────
echo -e "\n${YELLOW}[2/3] ALB / EIP 삭제 중 (terraform destroy)...${NC}"
echo -e "  ${YELLOW}대상: module.alb, aws_eip.analysis_node_eip, aws_security_group_rule.allow_alb_to_ec2${NC}"

cd "$INFRA_DIR"

terraform destroy \
  -target=module.alb \
  -target=aws_eip.analysis_node_eip \
  -target=aws_security_group_rule.allow_alb_to_ec2 \
  -auto-approve

echo -e "  ${GREEN}✓ ALB / EIP 삭제 완료${NC}"

# ── 3. 완료 요약 ──────────────────────────────────────────────
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Cleanup 완료!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  EC2   : 정지됨 (디스크 데이터 보존)"
echo -e "  ALB   : 삭제됨"
echo -e "  EIP   : 삭제됨"
echo -e ""
echo -e "  ${CYAN}예상 절약: 약 \$27/월${NC}"
echo -e "  재시작하려면: ${CYAN}./scripts/wakeup.sh${NC}"
echo ""
