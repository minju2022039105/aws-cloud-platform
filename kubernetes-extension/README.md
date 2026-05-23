# Kubernetes Extension

> 기존 서버리스 보안 자동화 포트폴리오의 Kubernetes 확장 프로젝트

기존 프로젝트는 AWS Lambda + API Gateway 기반 서버리스 구조로 설계되어 있습니다.
이 디렉토리는 동일한 AI 추론 엔진을 컨테이너로 배포하는 흐름을 별도로 구현합니다.

---

## 구조

```
kubernetes-extension/
├── ai-inference-server/   # FastAPI 기반 AI 추론 서버
│   ├── app/
│   │   ├── main.py        # /predict 엔드포인트
│   │   ├── model_loader.py
│   │   └── schemas.py
│   ├── Dockerfile
│   └── requirements.txt
├── k8s/                   # 순수 YAML 매니페스트
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── hpa.yaml
└── helm/                  # Helm 차트
    └── ai-inference/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
```

---

## API

| 엔드포인트 | 설명 |
|:---|:---|
| `GET /health` | 헬스체크 |
| `POST /predict` | WAF 로그 피처 5개 입력 → anomaly(0/1), score 반환 |

**요청 예시**
```json
{
  "country_code": 1.0,
  "rule_code": 2.0,
  "uri_len": 45.0,
  "path_entropy": 2.3,
  "args_entropy": 3.8
}
```

**응답 예시**
```json
{
  "anomaly": 1,
  "score": -0.1523
}
```

---

## 로컬 실행 (kind)

```bash
# 클러스터 생성
kind create cluster --name devsecops-local

# 이미지 빌드 (레포 루트에서 실행)
docker build -t ai-inference:latest -f kubernetes-extension/ai-inference-server/Dockerfile .

# kind에 이미지 로드
kind load docker-image ai-inference:latest --name devsecops-local

# 배포
kubectl apply -f k8s/

# 확인
kubectl get pods
kubectl port-forward svc/ai-inference 8080:80
curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"country_code":1,"rule_code":2,"uri_len":45,"path_entropy":2.3,"args_entropy":3.8}'
```

---

## Helm 배포

```bash
helm install ai-inference ./helm/ai-inference
helm upgrade ai-inference ./helm/ai-inference
helm rollback ai-inference 1
```

---

## Security Gate: Trivy 이미지 스캔

```bash
trivy image --severity HIGH,CRITICAL ai-inference:latest
```

기존 프로젝트에서 Trivy로 Terraform IaC를 정적 분석한 것과 동일한 도구로
컨테이너 이미지 취약점까지 커버합니다.

---

## Phase 2: EKS (선택, $5~10)

시간과 비용 여유가 있을 때만 진행합니다.

```bash
eksctl create cluster --name devsecops-k8s --region us-east-1
aws ecr create-repository --repository-name ai-inference
# ECR push + EKS 배포 + IRSA로 S3 모델 로드

# 반드시 정리
eksctl delete cluster --name devsecops-k8s
```
