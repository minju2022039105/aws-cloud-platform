# Terraform IaC로 구현한 탄력적 EKS 3-Tier 아키텍처 및 GitOps 파이프라인 구축

> 이 글은 **AWS Cloud Infrastructure Platform 구축기** 시리즈의 1편입니다.
> Terraform IaC로 3-Tier 네트워크와 Amazon EKS 클러스터를 코드화하고, ArgoCD GitOps · HPA · Cluster Autoscaler까지 운영 자동화 플랫폼을 구축한 과정을 다룹니다.
>
> 다음 글: [2편 — Kubernetes 환경에서의 컨테이너 애플리케이션 배포 자동화 및 Helm 기반 패키지 관리](https://velog.io/@yapp/07.-1.-%EC%84%9C%EB%B2%84%EB%A6%AC%EC%8A%A4-%ED%8F%AC%ED%8A%B8%ED%8F%B4%EB%A6%AC%EC%98%A4%EC%97%90-Kubernetes-%EB%8D%94%ED%95%98%EA%B8%B0-kind%EB%B6%80%ED%84%B0-EKS%EA%B9%8C%EC%A7%80)

---

Terraform으로 3-Tier AWS 인프라를 코드화하고,  
Amazon EKS 위에 ArgoCD GitOps, HPA, Cluster Autoscaler, Prometheus를 올려  
운영 자동화 플랫폼을 하루 만에 구축했다.

구축 과정에서 만난 실제 문제들도 함께 정리한다.

- kubectl 설치 실패 (Docker Desktop symlink 충돌)
- HPA `<unknown>` (Metrics Server 누락)
- Cluster Autoscaler CrashLoopBackOff (IMDSv2 hop limit → IRSA로 해결)

---

**최종 구성**

```
✓ 3-Tier VPC (Public / Private App / Private DB)
✓ Amazon EKS v1.30 — Terraform 모듈로 코드화
✓ ArgoCD GitOps — App of Apps 패턴
✓ HPA (CPU 70%, 2–5 replicas)
✓ Cluster Autoscaler + IRSA
✓ Prometheus + Grafana (in-cluster)
✓ NetworkPolicy (default-deny + nginx 80 허용)
```

---

## 1. 왜 3-Tier VPC인가

기존 VPC는 Public 서브넷만 있었다. EKS 노드를 Public에 올리면 노드 IP가 외부에 노출된다.

그래서 아래 구조로 확장했고, 아키텍처도 수정했다.
(여담이지만, 아키텍처 수정하는게 은근 번거롭다)

```
Public 서브넷 (×2)      → IGW, NAT Gateway, ELB
Private App 서브넷 (×2) → EKS Node Group
Private DB 서브넷 (×2)  → 향후 RDS용 예약
```
노드는 Private App 서브넷에 배치하고, NAT Gateway를 통해 ECR pull과 AWS API 호출을 처리한다. 외부에서 노드 IP로 직접 접근하는 경로가 없다.
**Before**
![](https://velog.velcdn.com/images/yapp/post/647efa60-d414-4480-bcac-a50edb3dcbf3/image.png)

---
**After**
![](https://velog.velcdn.com/images/yapp/post/9ffcc020-836c-45fd-83c8-357add4d89c0/image.png)



---

## 2. Terraform으로 VPC 확장

기존 `modules/vpc/main.tf`에 서브넷을 추가했다.

```hcl
# Private App 서브넷 — EKS 노드용
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 11}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/devsecops-eks" = "shared"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}
```

Private App 서브넷에 `kubernetes.io/role/internal-elb = 1` 태그를 붙이는 게 중요하다. EKS가 내부 ELB를 생성할 서브넷을 이 태그로 찾는다.

---

## 3. EKS 모듈 작성

`infra/modules/eks/`를 새로 만들었다. Terraform으로 EKS 전체를 코드화하면 `terraform destroy` 한 번으로 완전 삭제가 된다.

```hcl
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = concat(var.private_app_subnet_ids, var.public_subnet_ids)
    endpoint_public_access  = true
    endpoint_private_access = true
  }
}

resource "aws_eks_node_group" "platform" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "platform-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_app_subnet_ids  # Private에만 배치

  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }
}
```

노드 IAM Role에는 아래 3개 정책이 필요하다. 빠지면 노드가 클러스터에 Join을 못한다.

- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`

---

## 4. 삽질 1 — kubectl not found

`terraform apply` 완료 후 첫 번째 장벽을 만났다.

```
kubectl: command not found
```

WSL에서 kubectl을 설치하려 했는데 계속 실패했다. 원인은 Docker Desktop이었다. Docker Desktop이 `/usr/local/bin/kubectl`을 **심볼릭 링크**로 점유하고 있어서 일반 설치 방법으로는 덮어쓸 수 없었다.

해결:

```bash
curl -LO "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

`sudo install`은 심볼릭 링크를 실제 바이너리로 교체해준다.

설치 후 노드 상태 확인:

![kubectl nodes ready — 2노드 Ready, nginx pods Running](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/01_kubectl_nodes_ready_pods_running.png)

---

## 5. ArgoCD GitOps — App of Apps 패턴

ArgoCD를 설치하고 **App of Apps 패턴**을 적용했다.

### 왜 App of Apps인가

ArgoCD에서 앱을 하나씩 직접 등록하면, 앱이 10개가 됐을 때 관리 포인트가 10개가 된다.  
App of Apps는 **루트 Application 하나가 나머지 Application 전체를 Git에서 읽어 자동 생성**하는 패턴이다.

```
루트 Application (app-of-apps)
      │  gitops/apps/ 경로 감시
      └── nginx Application
                │  kubernetes-extension/k8s/nginx/ 경로 감시
                └── Deployment, Service, HPA
```

새 앱을 추가하려면 `gitops/apps/`에 yaml 하나 push하면 끝이다. ArgoCD가 알아서 감지하고 배포한다.

### syncPolicy — automated + selfHeal

```yaml
# gitops/apps/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: minju
  source:
    repoURL: https://github.com/minju2022039105/aws-devsecops-platform
    targetRevision: main
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- `automated`: `main` push → 자동 감지 → 클러스터 반영
- `prune`: Git에서 삭제된 리소스는 클러스터에서도 삭제
- `selfHeal`: 누군가 클러스터를 직접 수정해도 Git 상태로 자동 복구

이 세 가지를 켜면 Git이 클러스터의 단일 진실 공급원(Single Source of Truth)이 된다.  
kubectl로 직접 배포할 일이 없어진다.

![ArgoCD nginx 앱 카드 — Healthy / Synced](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/04_argocd_nginx_app_card.png)

![ArgoCD App Tree — svc / deploy / rs / pod](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/24_argocd_nginx_final_tree_with_hpa.png)

![ArgoCD Network — ELB → Service → Pod](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/18_argocd_nginx_network_elb_pods.png)

---

## 6. HPA + 삽질 2 — Metrics Server

nginx Deployment에 HPA를 붙였다.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx
  namespace: platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

근데 적용 후 HPA 상태가 이상했다.

```
NAME    TARGETS      MINPODS   MAXPODS   REPLICAS
nginx   <unknown>/70%  2         5         2
```

TARGETS가 `<unknown>`. HPA가 CPU 메트릭을 못 읽고 있었다.

원인은 **Metrics Server 미설치**였다. EKS는 Metrics Server를 기본으로 포함하지 않는다. HPA는 Metrics Server가 수집한 CPU 데이터를 기반으로 동작하기 때문에, Metrics Server 없이는 아무것도 안 된다.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

설치 후 정상화:

```
NAME    TARGETS      MINPODS   MAXPODS   REPLICAS
nginx   cpu: 1%/70%  2         5         2
```

![Cluster Autoscaler Running + HPA 1%/70% 정상](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/23_cluster_autoscaler_running_hpa_active.png)

---

## 7. Cluster Autoscaler + 삽질 3 — IRSA

Pod 레벨 확장(HPA)은 됐으니 노드 레벨 확장(Cluster Autoscaler)을 설치했다.

Helm으로 설치했는데 Pod가 계속 CrashLoopBackOff였다.

```
no EC2 IMDS role found, please make sure your Cluster Autoscaler is running on EC2
```

원인은 **EKS IMDSv2 hop limit**이었다.

EKS 노드의 IMDSv2 기본 hop limit은 1이다. 인스턴스(노드) 자체에서 IMDS 호출은 되지만, 그 위에 올라가는 Pod에서 IMDS를 호출하면 hop count가 2가 되어 차단된다. Cluster Autoscaler Pod가 EC2 인스턴스 메타데이터에 접근하지 못하니 IAM 권한을 가져오지 못하고 크래시가 난 것이다.

해결책은 **IRSA(IAM Roles for Service Accounts)**다.

IRSA는 IMDS 대신 EKS OIDC Provider를 통해 STS에서 임시 자격증명을 발급받는 방식이다. Pod에서 AWS API를 호출할 때 EKS 표준 패턴이다.

```
EKS OIDC Provider
      │  신뢰 정책 (ServiceAccount 조건)
      ▼
IAM Role (devsecops-cluster-autoscaler-role)
      │  AutoScalingFullAccess + EC2ReadOnlyAccess
      ▼
K8s ServiceAccount → eks.amazonaws.com/role-arn 어노테이션
      ▼
Cluster Autoscaler Pod → STS AssumeRoleWithWebIdentity
```

```bash
# 1. OIDC Provider 연동
eksctl utils associate-iam-oidc-provider \
  --cluster devsecops-eks --region us-east-1 --approve

# 2. OIDC ID 추출
OIDC_ID=$(aws eks describe-cluster \
  --name devsecops-eks --region us-east-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d/ -f5)

# 3. IAM Role 생성 (Trust Policy에 ServiceAccount 조건)
# 4. AutoScalingFullAccess + EC2ReadOnlyAccess 정책 연결
# 5. Helm으로 Cluster Autoscaler 설치 (role-arn 어노테이션 포함)
```

이후 정상 동작:

```
cluster-autoscaler-aws-cluster-autoscaler-xxx   1/1   Running
```

> **배운 점**: EKS에서 Pod가 AWS API를 호출해야 한다면 처음부터 IRSA로 설계해야 한다. Node IAM Role에 권한을 넣는 방식은 최소 권한 원칙에도 어긋나고, IMDSv2 hop limit 문제도 피할 수 없다.

---

## 8. Prometheus + Grafana

`kube-prometheus-stack` Helm 차트로 클러스터 내부에 설치했다.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f kubernetes-extension/helm/monitoring/prometheus-values.yaml
```

주요 설정:

```yaml
grafana:
  service:
    type: LoadBalancer
  adminPassword: "devsecops1234!"

prometheus:
  prometheusSpec:
    retention: 3d
    resources:
      requests:
        memory: 512Mi

alertmanager:
  enabled: false  # 비용 절감

nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
```

Grafana에서 Kubernetes / Compute Resources / Namespace (Pods) 대시보드를 열면 nginx Pod의 CPU/Memory를 실시간으로 볼 수 있다.

![Grafana — platform namespace nginx Pod CPU/Memory](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/13_grafana_platform_nginx_pods_detail.png)

![Grafana — platform namespace 통합 메트릭](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/10_grafana_platform_namespace_nginx_metrics.png)

---

## 9. NetworkPolicy — 최소 권한 원칙

platform 네임스페이스에 NetworkPolicy를 적용했다. 기본 차단하고 nginx만 열어주는 방식이다.

```yaml
# 전체 차단
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: platform
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# nginx만 80 허용
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-nginx-ingress
  namespace: platform
spec:
  podSelector:
    matchLabels:
      app: nginx
  ingress:
  - ports:
    - port: 80
```

---

## 최종 결과

```
NAMESPACE    NAME                                              READY   STATUS
argocd       argocd-application-controller-0                  1/1     Running
argocd       argocd-server-xxx                                1/1     Running
kube-system  cluster-autoscaler-aws-cluster-autoscaler-xxx    1/1     Running
kube-system  metrics-server-xxx                               1/1     Running
monitoring   monitoring-grafana-xxx                           3/3     Running
monitoring   prometheus-monitoring-kube-prometheus-xxx        2/2     Running
platform     nginx-65c76d8466-5kmwq                           1/1     Running
platform     nginx-65c76d8466-lvqrp                           1/1     Running
```

```
NAME    TARGETS      MINPODS   MAXPODS   REPLICAS
nginx   cpu: 1%/70%  2         5         2
```

![전체 네임스페이스 Pod Running 확인](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/22_kubectl_all_pods_running.png)

![nginx Welcome Page — ELB 엔드포인트 접속 확인](https://raw.githubusercontent.com/minju2022039105/aws-devsecops-platform/main/docs/architecture/%EC%8A%A4%ED%81%AC%EB%A6%B0%EC%83%B7/3tier_0613/21_nginx_welcome_page_browser.png)

---

## 삽질 요약

| 문제 | 원인 | 해결 |
|:---|:---|:---|
| kubectl not found | Docker Desktop symlink 점유 | `sudo install`로 바이너리 직접 교체 |
| HPA TARGETS `<unknown>` | Metrics Server 미설치 | components.yaml 적용 |
| Cluster Autoscaler CrashLoopBackOff | IMDSv2 hop limit으로 IMDS 접근 불가 | IRSA(OIDC 기반 STS)로 전환 |
| ArgoCD path not found | 파일 push 전에 sync 시도 | GitHub push 후 hard refresh |

---

## 마치며

EKS 구축에서 가장 많이 막힌 건 IRSA였다.

단순히 "권한 주기"가 아니라 OIDC → STS → ServiceAccount → Pod 순으로 이어지는 신뢰 체계를 이해해야 했다. CrashLoopBackOff 로그에서 `no EC2 IMDS role found`가 나왔을 때 처음엔 IAM Role 권한 문제인 줄 알았는데, 알고 보니 Pod가 Role을 조회하는 경로 자체가 막혀 있던 것이었다.

이번 작업으로 실제로 검증한 것들:

- **Terraform 모듈화** — vpc / eks를 독립 모듈로 분리하면 EKS만 따로 plan/destroy할 수 있다
- **GitOps 운영 방식** — Git push 하나로 배포가 끝나는 흐름을 직접 만들어봤다
- **HPA와 Cluster Autoscaler의 역할 차이** — HPA는 Pod를 늘리고, Autoscaler는 노드를 늘린다. 둘을 같이 써야 진짜 자동 확장이 된다
- **IRSA 기반 권한 관리** — EKS에서 Pod가 AWS API를 써야 한다면 Node IAM Role이 아니라 IRSA가 정답이다

다음 단계는 ALB Ingress Controller 도입과 FastAPI AI 추론 서버를 GitOps로 운영하는 것이다.

다음 편에서는 이 EKS 클러스터 위에 실제 애플리케이션을 컨테이너로 배포하고, Helm으로 패키지를 관리하는 과정을 다룬다.

---

**시리즈 네비게이션**
다음 글: [2편 — Kubernetes 환경에서의 컨테이너 애플리케이션 배포 자동화 및 Helm 기반 패키지 관리](https://velog.io/@yapp/07.-1.-%EC%84%9C%EB%B2%84%EB%A6%AC%EC%8A%A4-%ED%8F%AC%ED%8A%B8%ED%8F%B4%EB%A6%AC%EC%98%A4%EC%97%90-Kubernetes-%EB%8D%94%ED%95%98%EA%B8%B0-kind%EB%B6%80%ED%84%B0-EKS%EA%B9%8C%EC%A7%80)

GitHub: https://github.com/minju2022039105/aws-devsecops-platform
