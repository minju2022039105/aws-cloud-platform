
> 이 글은 **AWS WAF + AI 이상 탐지 플랫폼 구축기** 시리즈의 7편입니다.
> 기존 서버리스 구조를 유지하면서 Kubernetes 역량을 보완한 미니 확장 프로젝트를 기록합니다.
> 전체 코드는 [GitHub](https://github.com/minju2022039105/aws-devsecops-platform)에서 확인할 수 있습니다.

---

## 왜 Kubernetes를 추가했나

이 프로젝트는 AWS Lambda + API Gateway 기반 서버리스 구조로 설계되어 있습니다. 서버리스는 인프라 관리 부담이 없고 비용 효율이 좋아 AI 추론 엔진 배포에 적합한 선택이었습니다.

그런데 면접에서 한 가지 질문이 예상됩니다.

> "Kubernetes 경험이 있나요?"

많은 클라우드/DevOps 포지션에서 Kubernetes 경험을 요구하거나 우대합니다. 서버리스로 설계한 이유를 설명할 수 있더라도, K8s를 전혀 다뤄보지 않았다면 아쉬운 부분이 될 수 있습니다.

기존 프로젝트에 EKS를 억지로 붙이면 서버리스 보안 자동화라는 메시지가 흐려집니다. 대신 같은 레포 안에 `kubernetes-extension/` 디렉토리를 별도로 추가했습니다.

면접 답변 구조는 이렇습니다.

> "기존 프로젝트는 서버리스 구조로 설계했고,
> Kubernetes 배포 경험은 별도 미니 확장 프로젝트에서
> 컨테이너 배포와 보안 스캔 흐름으로 보완했습니다."

---

## 무엇을 만들었나

기존 프로젝트의 AI 추론 엔진(`Isolation Forest` 모델)을 FastAPI로 감싸 Kubernetes에 배포했습니다.

```
kubernetes-extension/
├── ai-inference-server/   # FastAPI 기반 AI 추론 서버
│   ├── app/
│   │   ├── main.py        # /health, /predict 엔드포인트
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
```

`/predict` 엔드포인트는 WAF 로그 피처 5개를 입력받아 이상 여부를 판단합니다.

```python
@app.post("/predict")
def predict(request: PredictRequest):
    features = [[
        request.country_code,
        request.rule_code,
        request.uri_len,
        request.path_entropy,
        request.args_entropy
    ]]
    scaled = scaler.transform(features)
    score = model.decision_function(scaled)[0]
    anomaly = int(model.predict(scaled)[0] == -1)
    return {"anomaly": anomaly, "score": round(float(score), 4)}
```

---

## Phase 1: 로컬 실습 (kind)

비용 없이 Kubernetes를 로컬에서 실습할 수 있는 환경으로 kind(Kubernetes in Docker)를 선택했습니다. minikube보다 가볍고 CI 환경과 유사한 구조입니다.

### 클러스터 생성

```bash
kind create cluster --name devsecops-local
kubectl get nodes
```

```
NAME                            STATUS   ROLES           AGE   VERSION
devsecops-local-control-plane   Ready    control-plane   1m    v1.32.2
```

### Docker 이미지 빌드

Dockerfile은 레포 루트를 빌드 컨텍스트로 사용합니다. AI 모델 파일(`ai/models/*.pkl`)을 컨테이너 내부에 포함시키기 위해서입니다.

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY kubernetes-extension/ai-inference-server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY kubernetes-extension/ai-inference-server/app/ ./app/
COPY ai/models/isolation_forest_model.pkl /models/isolation_forest_model.pkl
COPY ai/models/scaler.pkl /models/scaler.pkl

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

```bash
# 레포 루트에서 실행
docker build -f kubernetes-extension/ai-inference-server/Dockerfile -t ai-inference:latest .

# kind 클러스터에 이미지 로드
kind load docker-image ai-inference:latest --name devsecops-local
```

### kubectl 배포

```bash
kubectl apply -f kubernetes-extension/k8s/
kubectl get pods
```

```
NAME                           READY   STATUS    RESTARTS   AGE
ai-inference-bdf9d9487-gjdd8   1/1     Running   0          15s
```

`/predict` 호출로 동작을 확인했습니다.

```bash
kubectl port-forward svc/ai-inference 8080:80

curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"country_code":1,"rule_code":2,"uri_len":50,"path_entropy":1.2,"args_entropy":3.5}'
```

```json
{"anomaly": 1, "score": -0.0988}
```

<!-- 📸 스크린샷 #1 — kubectl get pods Running 상태
  내용: 터미널에서 kubectl get pods 결과 (1/1 Running)
  효과: 로컬 kind 클러스터에서 실제 동작함을 증명
-->

---

## Rolling Update / Rollback

Kubernetes의 핵심 운영 기능 중 하나입니다. 새 버전 배포 시 기존 Pod를 점진적으로 교체하고, 문제가 생기면 이전 버전으로 즉시 복구합니다.

```bash
# v2 이미지 태그 후 kind에 로드
docker tag ai-inference:latest ai-inference:v2
kind load docker-image ai-inference:v2 --name devsecops-local

# Rolling Update 적용
kubectl set image deployment/ai-inference ai-inference=ai-inference:v2

# 롤아웃 상태 확인
kubectl rollout status deployment/ai-inference
```

```
Waiting for deployment "ai-inference" rollout to finish: 1 old replicas are pending termination...
deployment "ai-inference" successfully rolled out
```

```bash
# Rollback
kubectl rollout undo deployment/ai-inference

# 히스토리 확인
kubectl rollout history deployment/ai-inference
```

```
REVISION  CHANGE-CAUSE
2         <none>
3         <none>
```

---

## Security Gate: Trivy 이미지 스캔

기존 프로젝트에서 Trivy로 Terraform IaC를 정적 분석했습니다. 이번엔 동일한 도구로 컨테이너 이미지 취약점 스캔까지 확장했습니다. 하나의 도구로 IaC와 이미지 두 레이어를 커버하는 구조입니다.

```bash
trivy image --severity HIGH,CRITICAL ai-inference:latest
```

첫 번째 스캔 결과입니다.

```
starlette (METADATA)  CVE-2024-47874  HIGH  fixed  0.38.6  →  0.40.0
```

FastAPI 의존성으로 설치된 starlette 0.38.6에 DoS 취약점이 있었습니다. `requirements.txt`에서 fastapi 버전을 올려 해결했습니다.

```
fastapi==0.115.0  →  fastapi>=0.115.6
```

두 번째 스캔에서 starlette가 0.41.3으로 올라갔는데, 새로운 CVE가 발견됐습니다.

```
starlette (METADATA)  CVE-2025-62727  HIGH  fixed  0.41.3  →  0.49.1
```

`starlette>=0.49.1`을 명시적으로 핀했습니다. pip가 fastapi 버전 고정과 충돌할 수 있어 `fastapi>=0.115.6`으로 완화했습니다.

최종 스캔 결과입니다.

**CRITICAL: 0**
- Python 패키지 취약점: 전부 조치 완료
- Debian OS 패키지(ncurses): 업스트림 미패치 상태로 기록

| CVE | 대상 | 조치 |
|:---|:---|:---|
| CVE-2024-47874 | starlette 0.38.6 | fastapi 버전 업그레이드 |
| CVE-2025-62727 | starlette 0.41.3 | starlette>=0.49.1 핀 추가 |
| CVE-2025-69720 | ncurses (Debian) | 업스트림 패치 대기 중 |

<!-- 📸 스크린샷 #2 — Trivy 최종 스캔 결과
  내용: trivy image 명령어 결과 터미널 화면 (Python 섹션 clean, ncurses HIGH만 남은 상태)
  효과: "CVE를 인식하고 조치했다"는 것을 실제 스캔 결과로 증명
-->

---

## Helm 배포

Helm은 Kubernetes 배포를 패키지 단위로 관리하는 도구입니다. `kubectl apply -f`로 yaml을 하나씩 적용하는 것과 달리, 여러 리소스를 하나의 차트로 묶어 배포, 업그레이드, 롤백을 일관되게 관리할 수 있습니다.

실무에서는 dev/staging/prod 환경별 값 관리가 필요하기 때문에 Helm 기반 배포 흐름도 함께 정리했습니다. `values.yaml`에서 환경별 값을 분리해 image 태그나 replica 수를 환경마다 다르게 구성할 수 있다는 점이 핵심입니다.

```yaml
# values.yaml
replicaCount: 1

image:
  repository: ai-inference
  tag: latest
  pullPolicy: IfNotPresent

hpa:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

```bash
# 기존 kubectl 배포 제거
kubectl delete -f kubernetes-extension/k8s/

# Helm으로 재배포
helm install ai-inference kubernetes-extension/helm/ai-inference/
```

```
NAME: ai-inference
STATUS: deployed
REVISION: 1
```

`/predict` 호출로 동작을 재확인했습니다.

---

## Phase 2: EKS 실제 배포

로컬 검증이 끝난 뒤, 실제 AWS EKS에서도 동일하게 동작하는지 확인했습니다.

### ECR 이미지 push

```bash
# ECR 레포지토리 생성
aws ecr create-repository --repository-name ai-inference --region us-east-1

# ECR 로그인 + 이미지 push
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com

ECR_URI=$(aws ecr describe-repositories \
  --repository-names ai-inference \
  --region us-east-1 \
  --query 'repositories[0].repositoryUri' \
  --output text)

docker tag ai-inference:latest $ECR_URI:latest
docker push $ECR_URI:latest
```

### EKS 클러스터 생성 + 배포

```bash
eksctl create cluster \
  --name devsecops-k8s \
  --region us-east-1 \
  --node-type t3.medium \
  --nodes 1 \
  --managed
```

`deployment.yaml`의 image를 ECR URI로 교체한 뒤 동일하게 배포했습니다.

```bash
kubectl apply -f kubernetes-extension/k8s/
kubectl get pods
```

```
NAME                           READY   STATUS    RESTARTS   AGE
ai-inference-cd57845f7-c87g8   1/1     Running   0          19s
```

```bash
kubectl port-forward svc/ai-inference 8080:80
curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"country_code":1,"rule_code":2,"uri_len":50,"path_entropy":1.2,"args_entropy":3.5}'
```

```json
{"anomaly": 1, "score": -0.0988}
```

kind와 EKS에서 동일한 결과가 나왔습니다. 로컬에서 검증한 배포 구조가 실제 클라우드에서도 그대로 동작함을 확인했습니다.

### 클러스터 삭제

```bash
eksctl delete cluster --name devsecops-k8s --region us-east-1
aws ecr delete-repository --repository-name ai-inference --region us-east-1 --force
```

비용 발생 시간은 약 30분으로 제한했고, 실습 직후 클러스터와 ECR 레포지토리를 삭제했습니다.

<!-- 📸 스크린샷 #3 — EKS kubectl get pods Running 상태
  내용: EKS 클러스터에서 kubectl get pods 결과 (1/1 Running)
  효과: 로컬이 아닌 실제 AWS EKS에서 동작함을 증명
-->

<!-- 📸 스크린샷 #4 — EKS /predict 호출 결과
  내용: curl /predict 결과 터미널 화면 ({"anomaly":1,"score":-0.0988})
  효과: 엔드포인트까지 실제 동작 검증
-->

---

## 마치며

서버리스와 Kubernetes는 상호 배타적인 선택이 아닙니다. 이 프로젝트에서 서버리스가 적합한 이유를 설명할 수 있게 됐고, 동시에 Kubernetes 배포 흐름도 직접 다뤄봤습니다.

오늘 배포 과정에서 인상적이었던 건 Trivy였습니다. IaC 스캔에서 이미 써본 도구인데, 이미지 스캔으로 확장하는 것이 자연스러웠습니다. 스캔을 돌리자마자 starlette CVE가 두 개 나왔고, 버전을 올리고 재스캔하는 흐름이 보안 게이트를 파이프라인에 넣는 실제 감각을 줬습니다.

다음 편은 이 시리즈의 마무리로, 전체 아키텍처와 회고를 정리할 예정입니다.
