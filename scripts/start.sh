#!/bin/bash
set -e

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
LOG_FILE="$INFRA_DIR/apply.log"

echo "=============================="
echo " DevSecOps Platform - START"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

cd "$INFRA_DIR"

echo "[1/3] AWS 자격증명 확인 중..."
aws sts get-caller-identity --query 'Account' --output text > /dev/null || {
  echo "ERROR: AWS 자격증명이 설정되지 않았습니다."
  echo "  aws configure 또는 AWS_PROFILE 환경변수를 확인하세요."
  exit 1
}
echo "  계정: $(aws sts get-caller-identity --query 'Account' --output text)"

echo ""
echo "[2/3] Terraform 초기화 확인 중..."
if [ ! -d ".terraform" ]; then
  terraform init
fi

echo ""
echo "[3/3] Terraform Apply 실행 중..."
terraform apply -auto-approve 2>&1 | tee "$LOG_FILE"

echo ""
echo "=============================="
echo " 인프라 배포 완료"
echo " 로그: $LOG_FILE"
echo "=============================="
echo ""
echo "[주요 Output]"
terraform output 2>/dev/null || true
