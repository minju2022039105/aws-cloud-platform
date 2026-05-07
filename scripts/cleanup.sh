#!/bin/bash
# =============================================================
# cleanup.sh — 서버리스 전환 전 인프라 정리 (아키텍처 전환 방안 기준)
#
# 삭제 대상 (의존성 역순):
#   1단계: aws_wafv2_web_acl_association.main  (WAF-ALB 연결 해제)
#   2단계: module.alb                           ~$16/월
#           module.security (WAF)               ~$5/월 + 요청당
#           aws_instance.security_node (EC2)    ~$8/월
#           aws_eip.analysis_node_eip           ~$3.6/월
#           aws_security_group_rule.allow_alb_to_ec2
#
# 유지 대상 (비용 거의 0):
#   S3, IAM, CloudWatch, Lambda
#
# 절약 효과: ~$35/월 → ~$1~2/월
# =============================================================

set -e

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  DevSecOps Cleanup — 서버리스 전환    ${NC}"
echo -e "${CYAN}========================================${NC}"

cd "$INFRA_DIR"

# ── 1. WAF-ALB 연결 해제 (의존성 때문에 반드시 먼저) ─────────
echo -e "\n${YELLOW}[1/2] WAF-ALB 연결 해제 중...${NC}"
echo -e "  ${YELLOW}대상: aws_wafv2_web_acl_association.main${NC}"

terraform destroy \
  -target=aws_wafv2_web_acl_association.main \
  -refresh=false \
  -auto-approve

echo -e "  ${GREEN}✓ WAF 연결 해제 완료${NC}"

# ── 2. ALB / WAF / EC2 / EIP 한 번에 destroy ────────────────
echo -e "\n${YELLOW}[2/2] ALB / WAF / EC2 / EIP 삭제 중...${NC}"
echo -e "  ${YELLOW}대상: module.alb, module.security, aws_instance.security_node,${NC}"
echo -e "  ${YELLOW}       aws_eip.analysis_node_eip, aws_security_group_rule.allow_alb_to_ec2${NC}"

terraform destroy \
  -target=module.alb \
  -target=module.security \
  -target=aws_instance.security_node \
  -target=aws_eip.analysis_node_eip \
  -target=aws_security_group_rule.allow_alb_to_ec2 \
  -refresh=false \
  -auto-approve

echo -e "  ${GREEN}✓ ALB / WAF / EC2 / EIP 삭제 완료${NC}"

# ── 3. 완료 요약 ──────────────────────────────────────────────
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Cleanup 완료!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  WAF   : 삭제됨 (module.security)"
echo -e "  ALB   : 삭제됨"
echo -e "  EC2   : 삭제됨"
echo -e "  EIP   : 삭제됨"
echo -e "  유지  : S3, IAM, CloudWatch, Lambda"
echo -e ""
echo -e "  ${CYAN}예상 절약: 약 \$33~34/월 (월 \$35 → \$1~2)${NC}"
echo -e "  다음 단계: ${CYAN}CloudFront + Lambda 재설계 (아키텍처 전환 방안 참고)${NC}"
echo ""
