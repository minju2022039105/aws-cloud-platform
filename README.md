# AWS Cloud Infrastructure Platform — Terraform · EKS · GitOps

> Terraform으로 3-Tier VPC와 EKS 클러스터를 코드화하고, ArgoCD GitOps로 배포를 자동화하며, Prometheus + Grafana로 관측성을 확보한 클라우드 플랫폼 구축 프로젝트.  
> GitHub Actions OIDC 기반 무자격증명 CI/CD · HPA + Cluster Autoscaler 자동 확장 · 구조적 비용 최적화까지 통합 구현. (WAF/SOAR 보안 자동화는 하단에 별도 기록)

**개인 프로젝트** | 2026.04 ~ 진행중 | [블로그 시리즈](https://velog.io/@yapp/series/WAF%EA%B0%80-%EB%AA%BB-%EC%9E%A1%EB%8A%94-%EA%B3%B5%EA%B2%A9-AI%EB%A1%9C-%EC%9E%A1%EA%B8%B0)

---

## Key Results

| 영역 | 성과 |
| :--- | :--- |
| **Infrastructure as Code** | `terraform apply` 1회로 VPC → EKS → WAF 전체 스택 프로비저닝 (재현 시간 ~15분) |
| **GitOps 배포** | ArgoCD App of Apps — Git push → 클러스터 자동 동기화, 수동 배포 제로 |
| **이중 자동 확장** | HPA(Pod) + Cluster Autoscaler(Node) + IRSA 기반 탄력적 워크로드 운영 |
| **비용 최적화** | KMS 호출 순환 구조(월 614만 건) 규명 → 서버리스 재설계로 월 비용 92% 절감 |
| **무자격증명 CI/CD** | GitHub Actions OIDC + Trivy/Bandit 3단계 스캔 — 장기 Access Key 제거, HIGH/CRITICAL 0건 배포 |

---

## Project Overview

Terraform으로 AWS 인프라를 코드화하고 Amazon EKS 기반 클라우드 플랫폼을 구축했습니다.

GitOps 기반 배포 자동화, 자동 확장(HPA·Cluster Autoscaler), 관측성(Prometheus·Grafana), 보안 자동화를 통합 구현했습니다.

| 레이어 | 구성 | 핵심 기술 |
| :--- | :--- | :--- |
| **Infrastructure** | 3-Tier VPC + EKS 클러스터 Terraform 코드화 | Terraform, VPC, EKS, IAM |
| **Platform Engineering** | GitOps · 자동 확장 · 네트워크 보안 | ArgoCD, HPA, Cluster Autoscaler, IRSA |
| **CI/CD Automation** | 무자격증명 배포 + 보안 게이트 | GitHub Actions OIDC, Trivy, Bandit |
| **Observability** | 클러스터 메트릭 + WAF 로그 분석 | Prometheus, Grafana, CloudWatch, Athena |
| **Security Automation** | SOAR 파이프라인 + AI 이상 탐지 | Lambda, WAF, Isolation Forest, SNS |

---

## Architecture

![전체 아키텍처](docs/architecture/architecture-v2.png)

> Terraform → EKS → GitOps → Auto Scaling → Observability → Security Automation
>
> 인프라 프로비저닝부터 운영 자동화까지 AWS 클라우드 플랫폼의 전체 라이프사이클을 구현했습니다.

---

## Tech Stack

| 분류 | 기술 |
| :--- | :--- |
| **IaC** | Terraform (모듈: vpc / waf / eks) |
| **Container / Orchestration** | Amazon EKS v1.30, kubectl, Helm, Docker |
| **GitOps** | ArgoCD (App of Apps), kube-prometheus-stack |
| **Auto-scaling** | HPA, Cluster Autoscaler, IRSA (EKS OIDC + IAM Role) |
| **CI/CD** | GitHub Actions (OIDC), Trivy, Bandit, tfsec |
| **Observability** | Prometheus, Grafana, CloudWatch, Athena |
| **Security** | AWS WAF v2, CloudFront, Lambda@Edge, NetworkPolicy |
| **AI/ML** | Scikit-learn (Isolation Forest) |
| **Serverless** | AWS Lambda (3종), API Gateway, S3, SNS, Kinesis |
| **Compliance** | AWS Config (Rules ×11), GuardDuty, CloudTrail, KMS |
| **Language & Scripting** | Python (FastAPI), Bash/Shell |

---

## 블로그 시리즈

> **AWS Cloud Infrastructure Platform 구축기** — Terraform IaC 기반 인프라 구축부터 GitOps · FinOps · CI/CD · WAF 가드레일 · 이상 탐지 · SOAR 자동화까지, 설계 결정 근거와 트러블슈팅을 8편으로 기록했습니다.

| 순서 | 제목 | 핵심 내용 | 분류 |
| :---: | :--- | :--- | :---: |
| [1](https://velog.io/@yapp/08.-Terraform%EC%9C%BC%EB%A1%9C-EKS-3-Tier-%ED%94%8C%EB%9E%AB%ED%8F%BC-%EA%B5%AC%EC%B6%95%ED%95%98%EA%B8%B0-ArgoCD-GitOps%EB%B6%80%ED%84%B0-IRSA-%ED%8A%B8%EB%9F%AC%EB%B8%94%EC%8A%88%ED%8C%85) | Terraform IaC로 구현한 탄력적 EKS 3-Tier 아키텍처 및 GitOps 파이프라인 구축 | 3-Tier VPC, EKS, ArgoCD GitOps, HPA+Cluster Autoscaler+IRSA | **Infra** |
| [2](https://velog.io/@yapp/07.-1.-%EC%84%9C%EB%B2%84%EB%A6%AC%EC%8A%A4-%ED%8F%AC%ED%8A%B8%ED%8F%B4%EB%A6%AC%EC%98%A4%EC%97%90-Kubernetes-%EB%8D%94%ED%95%98%EA%B8%B0-kind%EB%B6%80%ED%84%B0-EKS%EA%B9%8C%EC%A7%80) | Kubernetes 환경에서의 컨테이너 애플리케이션 배포 자동화 및 Helm 기반 패키지 관리 | kind/EKS 배포, Rolling Update/Rollback, Trivy 이미지 스캔, Helm | **Infra** |
| [3](https://velog.io/@yapp/5.-614%EB%A7%8C-%EA%B1%B4%EC%9D%98-KMS-%ED%98%B8%EC%B6%9C-%EB%AC%B4%ED%95%9C%EB%A3%A8%ED%94%84%EA%B0%80-30-%EC%B2%AD%EA%B5%AC%EC%84%9C%EB%A5%BC-%EB%A7%8C%EB%93%A0-%EB%82%A0) | [FinOps] 614만 건의 KMS API 호출 분석을 통한 아키텍처 재설계 및 인프라 비용 92% 절감 | Cost Explorer·CloudTrail 역추적, 공유 KMS 키 재설계 | **Infra/FinOps** |
| [4](https://velog.io/@yapp/03WAF-%EB%A3%B0-5%EB%8B%A8%EA%B3%84%EB%A5%BC-Terraform%EC%9C%BC%EB%A1%9C-%EC%BD%94%EB%93%9C%ED%99%94%ED%95%98%EB%8B%A4) | AWS WAF v2 인프라 코드화(IaC) 및 tfsec 정적 분석 기반의 컴플라이언스 자동화 | WAF Priority 설계, tfsec 정적 분석, Terraform 모듈화 | **Infra** |
| [5](https://velog.io/@yapp/%EB%B3%B4%EC%95%88%EC%9D%80-%EB%B0%B0%ED%8F%AC-%EC%A0%84%EC%97%90-%EC%8B%9C%EC%9E%91%EB%90%9C%EB%8B%A4-AWS-DevSecOps-CICD-%EC%84%A4%EA%B3%84%EA%B8%B0) | GitHub Actions OIDC 기반의 무자격증명(Credentialless) CI/CD 인프라 구축 | OIDC, Trivy·Bandit 보안 게이트, tfstate 원격 백엔드 | **CI/CD** |
| [6](https://velog.io/@yapp/WAF%EB%A7%8C%EC%9C%BC%EB%A1%9C%EB%8A%94-%EB%B6%80%EC%A1%B1%ED%96%88%EB%8B%A4-AI-%EC%9D%B4%EC%83%81-%ED%83%90%EC%A7%80%EB%A5%BC-%EB%B6%99%EC%9D%B8-%EC%9D%B4%EC%9C%A0) | 대규모 웹 애플리케이션 위협 분석 및 AWS WAF 기반의 정적 가드레일 설계 | Prevention/Detection/Response 3계층, GeoBlock 우선순위 | **Security** |
| [7](https://velog.io/@yapp/WAF%EA%B0%80-%EB%86%93%EC%B9%9C-%EA%B2%83%EC%9D%84-AI%EA%B0%80-%EC%9E%A1%EB%8A%94-%EB%B2%95-Isolation-Forest-Shannon-Entropy-%EA%B7%B8%EB%A6%AC%EA%B3%A0-%EC%A0%95%EC%A7%81%ED%95%9C-%ED%95%9C%EA%B3%84) | WAF 로그 데이터 기반의 이상 탐지 엔진 설계 및 Isolation Forest 모델링 | 피처 엔지니어링, Isolation Forest, 모델 평가 | **Security** |
| [8](https://velog.io/@yapp/%ED%83%90%EC%A7%80%EC%97%90%EC%84%9C-%EC%B0%A8%EB%8B%A8%EA%B9%8C%EC%A7%80-%EC%9E%90%EB%8F%99%ED%99%94%ED%95%98%EB%8B%A4-SOAR-%ED%8C%8C%EC%9D%B4%ED%94%84%EB%9D%BC%EC%9D%B8%EA%B3%BC-AI-%EB%8C%80%EC%8B%9C%EB%B3%B4%EB%93%9C-%EA%B5%AC%EC%B6%95%EA%B8%B0) | 이벤트 기반 인프라를 활용한 실시간 위협 탐지 및 SOAR 자동 차단 파이프라인 | S3 이벤트 트리거, Lambda·Athena·WAF 연동, Grafana 대시보드 | **Infra** |

---

## ─── Infrastructure
## 1. Terraform 기반 AWS 인프라 구축

```
infra/
├── main.tf          # Provider, S3 Backend + DynamoDB 상태 잠금
├── eks.tf           # EKS 모듈 호출
├── lambda.tf        # Lambda 함수 3종
├── apigateway.tf
├── cloudtrail.tf
├── config.tf        # ISMS Config Rules 11개
└── modules/
    ├── vpc/         # 3-Tier VPC (Public / Private App / Private DB)
    ├── waf/         # Regional WAF v2
    └── eks/         # EKS Cluster + Managed Node Group + IAM Roles
```

### 3-Tier VPC 네트워크 설계

| 서브넷 | CIDR | 용도 |
| :--- | :--- | :--- |
| Public (×2) | 10.0.1–2.0/24 | IGW, NAT Gateway, ELB |
| Private App (×2) | 10.0.11–12.0/24 | EKS Node Group (워크로드 격리) |
| Private DB (×2) | 10.0.21–22.0/24 | 예약 (RDS 확장 고려) |

---

## ─── Platform Engineering

## 2. Amazon EKS 클러스터 구성

| 항목 | 값 |
| :--- | :--- |
| 클러스터 이름 | `devsecops-eks` |
| K8s 버전 | v1.30 |
| 노드 타입 | t3.medium |
| 노드 수 | desired: 2 / min: 1 / max: 3 |
| 노드 위치 | Private App 서브넷 |
| Endpoint | Public + Private |

![kubectl nodes ready](docs/architecture/스크린샷/3tier_0613/01_kubectl_nodes_ready_pods_running.png)

---

## 3. GitOps — ArgoCD App of Apps

**App of Apps 패턴** 으로 단일 루트 Application이 하위 Application 전체를 선언적으로 관리합니다.

| 설정 | 값 |
| :--- | :--- |
| Project | `minju` |
| Sync Policy | Automated (prune + selfHeal) |
| Target | `main` 브랜치 |
| Destination | `https://kubernetes.default.svc` |

![ArgoCD App Tree (HPA 포함)](docs/architecture/스크린샷/3tier_0613/24_argocd_nginx_final_tree_with_hpa.png)

---

## 4. Auto Scaling — HPA + Cluster Autoscaler + IRSA

Pod 레벨 자동 확장(HPA)과 노드 레벨 자동 확장(Cluster Autoscaler)을 함께 구성했습니다.

### HPA (Horizontal Pod Autoscaler)

| 항목 | 값 |
| :--- | :--- |
| 대상 | nginx Deployment |
| CPU 임계치 | 70% |
| minReplicas | 2 |
| maxReplicas | 5 |
| 의존성 | Metrics Server |

```bash
kubectl get hpa -n platform
# NAME    TARGETS      MINPODS   MAXPODS   REPLICAS
# nginx   cpu: 1%/70%  2         5         2
```

### Cluster Autoscaler + IRSA

IMDSv2 hop limit으로 Pod에서 직접 IAM 자격 증명 접근이 제한되어 IRSA를 적용했습니다.

```
EKS OIDC Provider
      │  신뢰 정책 (Condition: ServiceAccount 일치)
      ▼
IAM Role (devsecops-cluster-autoscaler-role)
      │  AutoScalingFullAccess + EC2ReadOnlyAccess
      ▼
K8s ServiceAccount (cluster-autoscaler)
      │  eks.amazonaws.com/role-arn 어노테이션
      ▼
Cluster Autoscaler Pod → STS AssumeRoleWithWebIdentity → AWS API
```

![Cluster Autoscaler + HPA 동작 확인](docs/architecture/스크린샷/3tier_0613/23_cluster_autoscaler_running_hpa_active.png)

**Zero Trust Network**: platform 네임스페이스 기본 Ingress 차단 + nginx port 80 단독 허용 (NetworkPolicy 2개 적용).

---

## ─── CI/CD Automation
## 5. GitHub Actions OIDC 기반 배포 자동화

장기 자격증명(Access Key) 없이 GitHub Actions → AWS 배포를 구현했습니다.

```
GitHub Actions Runner
      │  OIDC Token 발급
      ▼
AWS STS AssumeRoleWithWebIdentity
      │  Condition: repo + main 브랜치 한정
      ▼
github-actions-oidc-role → Terraform apply / Lambda deploy
```

```hcl
Condition = {
  StringLike = {
    "token.actions.githubusercontent.com:sub" = [
      "repo:minju2022039105/aws-cloud-platform:ref:refs/heads/main",
      "repo:minju2022039105/aws-cloud-platform:ref:refs/pull/*"
    ]
  }
}
```

main 브랜치 push와 PR 이벤트만 허용하고 다른 브랜치 push는 차단합니다.  
GitHub Secrets가 유출되어도 이 Condition 범위 밖의 컨텍스트에서는 AWS 접근이 불가능합니다.

### Security Gates

코드 변경 시 Trivy · Bandit이 자동 실행되며, 통과하지 못하면 Terraform apply가 차단됩니다.

Push to main → **Security Gates** (Trivy IaC + Bandit) → 통과 시 **Terraform Apply** (init → plan → apply, PR에 Plan 자동 코멘트) → **Lambda Deploy** (SecurityAnalyzer / SecurityPreventer / NormalTrafficGenerator)

| 도구 | 검사 대상 | 기준 |
| :--- | :--- | :--- |
| **Trivy IaC** | Terraform 코드 | HIGH / CRITICAL 차단 |
| **Bandit** | Python Lambda 코드 | Python 보안 취약점 |
| **tfsec** | Terraform 수동 감사 | 로컬 점검 도구 (CI 제외) |

tfsec 수동 점검 결과:

| Before | After |
|:---:|:---:|
| ![tfsec Before](docs/architecture/스크린샷/tfsec_before.png) | ![tfsec After](docs/architecture/스크린샷/tfsec_after.png) |

Critical 1 → **0**, High 10 → **0** 달성.

![CI/CD 파이프라인](docs/architecture/스크린샷/cd_pipeline.png)

---

## ─── Observability

## 6. Prometheus + Grafana (In-Cluster)

`kube-prometheus-stack` Helm 차트로 클러스터 내부에 Prometheus + Grafana를 배포했습니다.

| 항목 | 구성 |
| :--- | :--- |
| 배포 방식 | Helm (`helm/monitoring/prometheus-values.yaml`) |
| 수집 대상 | Node CPU/Memory, Pod 상태, kube-state-metrics |
| 시각화 | Grafana 내장 대시보드 (Kubernetes / Nodes / Pods) |
| 연동 | ArgoCD GitOps로 kube-prometheus-stack 관리 |

---

## 7. CloudWatch + Athena + Grafana Cloud

**Grafana 대시보드 패널**

| 패널 | 데이터소스 | 설명 |
| :--- | :--- | :--- |
| WAF 시간대별 차단 추이 | CloudWatch | BlockedRequests Time series |
| 룰별 차단 건수 | CloudWatch | 4개 룰 분리 Bar chart |
| 공격 유형 분포 | Athena | WAF 로그 기반 Pie chart |
| 국가별 차단 | Athena | Geomap |

![WAF 보안 관제 대시보드](docs/architecture/스크린샷/waf_dashboard.png)

---

## 8. Cost Optimization Case Study

### KMS 호출 순환 구조 → 서버리스 재설계

**문제**: CloudTrail → S3 로그 → 개별 KMS 암호화 → 614만 API 호출 → $30/일

**해결**
- 공유 KMS 키 + S3 Bucket Key 활성화
- ALB+EC2 → API Gateway+Lambda 서버리스 전환

**결과**: KMS 비용 $18.42 → $1.41 (92% 절감) + 월 고정비 $16~18 추가 절감

> 상세 원인 추적 과정은 [블로그 3편](https://velog.io/@yapp/5.-614%EB%A7%8C-%EA%B1%B4%EC%9D%98-KMS-%ED%98%B8%EC%B6%9C-%EB%AC%B4%ED%95%9C%EB%A3%A8%ED%94%84%EA%B0%80-30-%EC%B2%AD%EA%B5%AC%EC%84%9C%EB%A5%BC-%EB%A7%8C%EB%93%A0-%EB%82%A0)에 기록.

---

## ─── Security Automation
## 9. Security Layer

### WAF 우선순위 설계

| Priority | 규칙 | 근거 |
| :---: | :--- | :--- |
| 0 | GeoBlock-Non-KR | 한국 외 입구 차단 → 하위 룰 검사 비용 절감 |
| 1 | AI-RealTime-Block | AI가 식별한 위협 IP 즉각 차단 |
| 2–4 | AWS Managed Rules | SQLi, XSS 등 알려진 패턴 방어 |
| 5 | IP Reputation List | 평판 불량 IP 차단 |

### SOAR Pipeline

S3에 AI 분석 결과가 적재되는 즉시 Lambda가 위협 IP를 WAF에 자동 등록합니다.

![Event-Driven SOAR Pipeline](docs/architecture/SOAR.png)

```
monitor.py (AI 추론 결과 생성)
      │  S3 업로드: results/year=Y/month=M/day=D/aiops_*.json
      ▼
S3 ObjectCreated 트리거
      │
      ▼
Lambda: SecurityAnalyzer
      │  Athena aiops_results 쿼리 → anomaly=1 IP 추출
      ▼
Lambda: SecurityPreventer
      ├── WAF IP Set (devsecops-ai-block-list) 자동 업데이트
      └── CloudWatch Namespace: AIOps/Security
```

| 함수 | 역할 |
| :--- | :--- |
| `SecurityAnalyzer` | S3 트리거 → Athena 쿼리 → anomaly IP 추출 → Preventer 호출 |
| `SecurityPreventer` | 위협 IP → WAF IP Set 등록 + CloudWatch 메트릭 기록 |
| `NormalTrafficGenerator` | 6시간마다 정상 트래픽 생성 (AI 모델 학습용) |

![CloudWatch AI 탐지 메트릭](docs/architecture/스크린샷/cloudwatch_ai_metric.png)

### AI 이상 탐지

WAF 정적 룰의 사각지대를 보완하기 위한 보조 탐지 레이어로, Isolation Forest 모델을 SOAR 파이프라인에 연결했습니다.  
GeoIP·룰 코드·URI 엔트로피 등의 피처를 기반으로 WAF가 허용한 요청 중 이상 패턴을 탐지해 자동 차단 대상으로 전달합니다.  
설계 근거는 [블로그 7편](https://velog.io/@yapp/WAF%EA%B0%80-%EB%86%93%EC%B9%9C-%EA%B2%83%EC%9D%84-AI%EA%B0%80-%EC%9E%A1%EB%8A%94-%EB%B2%95-Isolation-Forest-Shannon-Entropy-%EA%B7%B8%EB%A6%AC%EA%B3%A0-%EC%A0%95%EC%A7%81%ED%95%9C-%ED%95%9C%EA%B3%84)에 기록했습니다.

### IAM 최소 권한

| Principal | Role | 설계 의도 |
| :--- | :--- | :--- |
| **GitHub Actions** | `github-actions-oidc-role` | 장기 자격증명 없음. main 브랜치 한정 |
| **Analyzer + Preventer Lambda** | `lambda_blocker_role` | WAF UpdateIPSet만 허용. 생성·삭제 권한 없음 |
| **Lambda@Edge** | `edge_lambda` | S3 models/* GetObject 읽기 전용 |
| **Cluster Autoscaler** | `cluster-autoscaler-role` | IRSA 기반. AutoScaling + EC2ReadOnly만 허용 |

### 컴플라이언스 (ISMS)

AWS Config Rules ×11로 ISMS 통제항목을 자동 점검합니다.  
NON_COMPLIANT 감지 → EventBridge → SNS 알림. 주요 항목: Root 키 미사용, S3 퍼블릭 차단, CloudTrail 무결성, GuardDuty 활성화.

---

## ─── 공통

## 10. Troubleshooting

| # | 문제 | 원인 | 해결 |
| :--- | :--- | :--- | :--- |
| 1 | KMS 비용 $30/일 급증 | 리소스별 개별 KMS 키 → API 호출 폭증 | 공유 KMS 키 + S3 Bucket Key 전환 |
| 2 | IAM AccessDenied (OIDC) | StringLike Condition → 모든 브랜치 Assume 가능 | OIDC Trust Policy 권한 최소화 검토 |
| 3 | HPA TARGETS `<unknown>` | Metrics Server 미설치 | components.yaml 적용 |
| 4 | Cluster Autoscaler CrashLoopBackOff | IMDSv2 hop limit으로 IMDS 접근 불가 | IRSA(OIDC 기반 STS) 방식으로 전환 |
| 5 | VPC Default SG 컴플라이언스 위반 | Terraform 외 기본 VPC self-referencing 잔존 | aws_default_security_group으로 Terraform 편입 |

---

## 11. 프로젝트 구조

```
aws-cloud-platform/
├── infra/                        # Terraform IaC
│   └── modules/
│       ├── vpc/                  # 3-Tier VPC
│       ├── waf/                  # Regional WAF
│       └── eks/                  # EKS Cluster + Node Group
├── lambda/                       # Lambda 함수
│   ├── analyzer/                 # SecurityAnalyzer
│   ├── preventer/                # SecurityPreventer
│   ├── edge_security/            # Lambda@Edge
│   └── traffic_generator/        # NormalTrafficGenerator
├── kubernetes-extension/
│   ├── ai-inference-server/      # FastAPI AI 추론 서버
│   ├── k8s/
│   │   ├── ai-inference/         # AI 추론 서버 매니페스트
│   │   ├── nginx/                # nginx Deployment / Service / HPA
│   │   └── network-policy/       # NetworkPolicy
│   └── helm/
│       ├── ai-inference/         # AI 추론 서버 Helm 차트
│       └── monitoring/           # prometheus-values.yaml
├── gitops/
│   └── apps/                     # ArgoCD App of Apps
├── ai/                           # AI/ML 엔진
│   ├── data/                     # 학습 데이터 (1,800건)
│   ├── models/                   # Isolation Forest, Scaler
│   └── training/                 # train_model.py
├── monitoring/
│   ├── prometheus-demo/          # monitor.py (SOAR 입력 생성기)
│   └── cloudwatch/               # Athena DDL
├── scripts/
│   ├── start.sh                  # 전체 스택 배포 (Terraform + K8s + Helm)
│   ├── stop.sh                   # 전체 스택 삭제
│   └── check_destroyed.sh        # 리소스 삭제 확인
└── docs/
    ├── architecture/             # 아키텍처 다이어그램 + 스크린샷
    ├── Velog/                    # 블로그 포스트 초안
    ├── 작업일지/                  # 날짜별 작업 기록
    └── terraform/                # plan / apply 로그
```

---

## 12. Next Steps

| 영역 | 계획 |
| :--- | :--- |
| Ingress | nginx LoadBalancer 직접 노출 → AWS ALB Ingress Controller + TLS 종단 적용 |
| Database | Private DB 서브넷에 RDS 연동, 애플리케이션 레이어 추가 |
| 로그 파이프라인 | Kinesis Firehose 기반 WAF 로그 실시간 직접 수집 |
| **FinOps** | AWS Compute Optimizer · Savings Plans 기반 비용 최적화 검토 |

---

## Cloud Infrastructure Platform — Status: Active
