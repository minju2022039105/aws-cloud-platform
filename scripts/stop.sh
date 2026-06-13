#!/bin/bash

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$INFRA_DIR/destroy.log"
CLUSTER_NAME="devsecops-eks"
REGION="us-east-1"

echo "=============================="
echo " DevSecOps Platform - STOP"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

# ===== [1/7] AWS 자격증명 확인 =====
echo ""
echo "[1/7] AWS 자격증명 확인 중..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text) || {
  echo "ERROR: AWS 자격증명이 설정되지 않았습니다."
  exit 1
}
echo "  계정: $ACCOUNT_ID"

# ===== [2/7] kubeconfig 업데이트 =====
echo ""
echo "[2/7] kubeconfig 업데이트 중..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" 2>/dev/null || {
  echo "  WARNING: EKS 클러스터 접근 불가 — K8s 리소스 정리를 건너뜁니다."
  K8S_SKIP=true
}

# ===== [3/7] K8s 리소스 정리 =====
echo ""
echo "[3/7] K8s 리소스 정리 중..."

if [ -z "$K8S_SKIP" ]; then
  echo "  [3-1] Helm: cluster-autoscaler 제거..."
  helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true

  echo "  [3-2] Helm: kube-prometheus-stack 제거..."
  helm uninstall monitoring -n monitoring 2>/dev/null || true

  echo "  [3-3] ArgoCD Application 제거..."
  kubectl delete application nginx app-of-apps -n argocd 2>/dev/null || true

  echo "  [3-4] ArgoCD AppProject 제거..."
  kubectl delete appproject minju -n argocd 2>/dev/null || true

  echo "  [3-5] ArgoCD 제거..."
  kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true

  echo "  [3-6] Metrics Server 제거..."
  kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true

  echo "  [3-7] NetworkPolicy 제거..."
  kubectl delete -f "$ROOT_DIR/kubernetes-extension/k8s/network-policy/platform-netpol.yaml" 2>/dev/null || true

  echo "  [3-8] Namespace 제거 (platform, monitoring, argocd)..."
  kubectl delete namespace platform monitoring argocd 2>/dev/null || true

  echo "  K8s 리소스 정리 완료"
else
  echo "  SKIP (클러스터 접근 불가)"
fi

# ===== [4/7] IAM Role 정리 =====
echo ""
echo "[4/7] IAM Role 정리 중..."
ROLE_NAME="devsecops-cluster-autoscaler-role"

aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess 2>/dev/null || true

aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess 2>/dev/null || true

aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && \
  echo "  IAM Role 삭제 완료: $ROLE_NAME" || \
  echo "  IAM Role 없음 (이미 삭제됐거나 미생성)"

# ===== [5/7] OIDC Provider 정리 =====
echo ""
echo "[5/7] OIDC Provider 정리 중..."
OIDC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text 2>/dev/null | cut -d/ -f5)

if [ -n "$OIDC_ID" ]; then
  OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null && \
    echo "  OIDC Provider 삭제 완료" || \
    echo "  OIDC Provider 없음 (이미 삭제됐거나 미생성)"
else
  echo "  SKIP (OIDC ID 확인 불가)"
fi

# ===== [6/7] Terraform Destroy =====
echo ""
echo "[6/7] Terraform Destroy 실행 중..."
cd "$INFRA_DIR"
terraform destroy -auto-approve 2>&1 | tee "$LOG_FILE"

# ===== [7/7] 완료 =====
echo ""
echo "=============================="
echo " 인프라 삭제 완료"
echo " 로그: $LOG_FILE"
echo "=============================="
echo ""
echo "  KMS 키는 7일 후 실제 삭제됩니다 (deletion_window_in_days = 7)"
