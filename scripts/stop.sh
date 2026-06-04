#!/bin/bash
set -e

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
LOG_FILE="$INFRA_DIR/destroy.log"

echo "=============================="
echo " DevSecOps Platform - STOP"
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
echo "[2/3] 삭제될 리소스 목록 확인 중..."
RESOURCE_COUNT=$(terraform state list 2>/dev/null | grep -v '^data\.' | wc -l)
echo "  삭제 대상 리소스: ${RESOURCE_COUNT}개"

echo ""
echo "[3/3] Terraform Destroy 실행 중..."
terraform destroy -auto-approve 2>&1 | tee "$LOG_FILE"

echo ""
echo "=============================="
echo " 인프라 삭제 완료"
echo " 로그: $LOG_FILE"
echo "=============================="
echo ""
echo "  KMS 키는 7일 후 실제 삭제됩니다 (deletion_window_in_days = 7)"
