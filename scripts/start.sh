#!/bin/bash

INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$INFRA_DIR/apply.log"
CLUSTER_NAME="devsecops-eks"
REGION="us-east-1"

echo "=============================="
echo " DevSecOps Platform - START"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

# ===== [1/8] AWS 자격증명 확인 =====
echo ""
echo "[1/8] AWS 자격증명 확인 중..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text) || {
  echo "ERROR: AWS 자격증명이 설정되지 않았습니다."
  exit 1
}
echo "  계정: $ACCOUNT_ID"

# ===== [2/8] Terraform Apply =====
echo ""
echo "[2/8] Terraform Apply 실행 중..."
cd "$INFRA_DIR"
if [ ! -d ".terraform" ]; then
  terraform init
fi
terraform apply -auto-approve 2>&1 | tee "$LOG_FILE"

echo ""
echo "  [Output]"
terraform output 2>/dev/null || true

# ===== [3/8] kubeconfig 업데이트 =====
echo ""
echo "[3/8] kubeconfig 업데이트 중..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
echo "  kubectl 연결 확인..."
kubectl get nodes

# ===== [4/8] ArgoCD 설치 =====
echo ""
echo "[4/8] ArgoCD 설치 중..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "  ArgoCD CRD 준비 대기 중..."
kubectl wait --for=condition=established crd/applications.argoproj.io --timeout=120s
echo "  ArgoCD Server 준비 대기 중 (최대 5분)..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# ===== [5/8] GitOps 설정 =====
echo ""
echo "[5/8] GitOps 설정 중..."

echo "  ArgoCD Project 'minju' 생성..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: minju
  namespace: argocd
spec:
  description: Minju Platform Project
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

echo "  App of Apps 적용 중..."
kubectl apply -f "$ROOT_DIR/gitops/apps/app-of-apps.yaml"
echo "  ArgoCD가 nginx를 자동 배포합니다 (GitOps)"

# ===== [6/8] IRSA 설정 (Cluster Autoscaler용) =====
echo ""
echo "[6/8] IRSA 설정 중 (Cluster Autoscaler)..."

echo "  OIDC Provider 연동..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve

OIDC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d/ -f5)
echo "  OIDC ID: $OIDC_ID"

echo "  IAM Role 생성 중..."
python3 -c "
import json, sys
policy = {
  'Version': '2012-10-17',
  'Statement': [{
    'Effect': 'Allow',
    'Principal': {
      'Federated': 'arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}'
    },
    'Action': 'sts:AssumeRoleWithWebIdentity',
    'Condition': {
      'StringEquals': {
        'oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub': 'system:serviceaccount:kube-system:cluster-autoscaler-aws-cluster-autoscaler'
      }
    }
  }]
}
print(json.dumps(policy, indent=2))
" > /tmp/trust-policy.json

ROLE_NAME="devsecops-cluster-autoscaler-role"
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Cluster Autoscaler IRSA Role" 2>/dev/null || \
aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess
echo "  IAM Role 준비 완료: $ROLE_NAME"

# ===== [7/8] Observability 스택 설치 =====
echo ""
echo "[7/8] Observability 스택 설치 중..."

echo "  Metrics Server 설치..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "  Helm repo 추가..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo update

echo "  Prometheus + Grafana 설치 중..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "$ROOT_DIR/kubernetes-extension/helm/monitoring/prometheus-values.yaml"

# ===== [8/8] Cluster Autoscaler 설치 =====
echo ""
echo "[8/8] Cluster Autoscaler 설치 중..."
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$REGION" \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "  NetworkPolicy 적용 중..."
kubectl apply -f "$ROOT_DIR/kubernetes-extension/k8s/network-policy/platform-netpol.yaml"

# ===== 완료 =====
echo ""
echo "=============================="
echo " 인프라 배포 완료"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="
echo ""
echo "  kubectl get nodes"
kubectl get nodes
echo ""
echo "  kubectl get pods -A"
kubectl get pods -A
echo ""
echo "  [ArgoCD 초기 비밀번호]"
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo "" || \
  echo "  (ArgoCD 준비 중 — 잠시 후 확인하세요)"
echo ""
echo "  [Grafana 접속 정보]"
echo "  admin / devsecops1234!"
kubectl get svc monitoring-grafana -n monitoring 2>/dev/null | grep -v NAME || true
