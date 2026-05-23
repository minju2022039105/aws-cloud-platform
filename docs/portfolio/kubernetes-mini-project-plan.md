# Kubernetes 미니 프로젝트 계획서

> 목적: 기존 서버리스 포트폴리오의 Kubernetes 공백 보완
> 방식: 기존 프로젝트 메시지를 유지하면서 별도 확장 디렉토리로 분리
> 비용 목표: 거의 0원 (EKS는 선택적 1회 검증)

---

## 포지셔닝 원칙

기존 프로젝트에 EKS를 크게 붙이지 않는다.
현재 포트폴리오의 강점은 **서버리스 보안 자동화 구조**이고, EKS를 억지로 연결하면 메시지가 흐려진다.

대신 같은 레포 안에 `kubernetes-extension/` 디렉토리를 별도로 추가한다.

**면접 답변 구조**

> "기존 프로젝트는 서버리스 구조로 설계했고,
> Kubernetes 공백은 별도 미니 확장 프로젝트에서
> 컨테이너 배포와 보안 스캔 흐름으로 보완했습니다."

---

## 디렉토리 구조

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
├── helm/                  # Helm 차트
│   └── ai-inference/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
└── README.md
```

---

## Phase 1: 로컬 실습 (2주, 비용 없음)

### 환경

kind (Kubernetes in Docker) 사용 — minikube보다 가볍고 CI 환경과 유사

```bash
kind create cluster --name devsecops-local
kubectl cluster-info --context kind-devsecops-local
```

### 실습 순서

| 주차 | 내용 |
|:---:|:---|
| 1주차 | Pod / Deployment / Service / ConfigMap / Secret 직접 작성 |
| 1주차 | Ingress, liveness/readiness probe, Rolling Update, Rollback |
| 2주차 | AI 추론 서버 컨테이너화 + kind 배포 |
| 2주차 | HPA 설정, Helm 차트 작성, Trivy 이미지 스캔 |

### 만들 것: AI 추론 서버

기존 `ai/inference/` 코드를 FastAPI로 감싸서 `/predict` 엔드포인트 제공.
입력: WAF 로그 피처 5개 (`country_code`, `rule_code`, `uri_len`, `path_entropy`, `args_entropy`)
출력: `anomaly` (0/1), `score`

```python
# app/main.py 핵심 구조
@app.post("/predict")
def predict(request: PredictRequest):
    features = [[
        request.country_code,
        request.rule_code,
        request.uri_len,
        request.path_entropy,
        request.args_entropy
    ]]
    score = model.decision_function(features)[0]
    anomaly = int(model.predict(features)[0] == -1)
    return {"anomaly": anomaly, "score": round(float(score), 4)}
```

### Security Gate: Trivy 이미지 스캔

기존 Trivy IaC 스캔에서 **컨테이너 이미지 스캔**으로 확장.

```bash
trivy image --severity HIGH,CRITICAL ai-inference:latest
```

기존 프로젝트와의 연결 포인트:
- 기존: Trivy로 Terraform 코드 정적 분석
- 확장: Trivy로 컨테이너 이미지 취약점 스캔
- 동일한 도구로 IaC + 이미지 두 레이어를 커버하는 구조

---

## Phase 2: EKS 검증 (선택, $5~10)

시간과 비용 여유가 있을 때만 진행. 로컬에서 완성 후 EKS에서 1회 배포 검증.

**핵심 확인 항목만**
- EKS 클러스터 생성 + kubectl 연결
- ECR에 이미지 push + EKS 배포
- IRSA로 S3 모델 파일 로드 (GitHub Actions OIDC와 동일한 원리)

```bash
# 실습 후 반드시 정리
eksctl delete cluster --name devsecops-k8s
```

---

## 완료 기준

**로컬 (필수)**
- [ ] kind 클러스터에서 AI 추론 서버 배포 및 `/predict` 호출 성공
- [ ] HPA 설정 완료
- [ ] Helm 차트로 배포 가능
- [ ] Trivy 이미지 스캔 통과
- [ ] Rolling Update / Rollback 검증
- [ ] `kubernetes-extension/README.md` 작성

**EKS (선택)**
- [ ] EKS 배포 후 엔드포인트 호출 성공
- [ ] IRSA로 S3 모델 파일 로드 성공
- [ ] 클러스터 destroy 완료

---

## 면접 답변 준비

| 예상 질문 | 답변 방향 |
|:---|:---|
| "왜 Lambda 대신 컨테이너를?" | 모델 교체 시 이미지만 교체하면 되어 롤백과 버전 관리가 명확해짐 |
| "Kubernetes 운영 경험이 있나요?" | 로컬 kind 환경에서 배포 파이프라인 구현. 실 트래픽 운영 경험은 없음 |
| "Helm을 왜 쓰나요?" | 환경별(dev/prod) 값 분리와 배포 단위 관리를 위해 |
| "IRSA가 뭔가요?" | EKS Pod가 AWS API를 호출할 때 Access Key 없이 ServiceAccount 기반 OIDC 토큰으로 인증. GitHub Actions OIDC와 원리가 동일 |
