# Kubernetes 미니 프로젝트 시작 전 개념 정리

> 프로젝트 착수 전 궁금했던 것들 Q&A 정리

---

## Q. 레포를 따로 만들어야 하나?

No. 기존 레포 안에 `kubernetes-extension/` 디렉토리를 추가하는 방식.

EKS를 기존 프로젝트에 억지로 붙이면 "서버리스 보안 자동화"라는 메시지가 흐려지고,
별도 레포로 분리하면 연결 맥락이 사라진다.

**면접 답변**
> "기존 프로젝트는 서버리스 구조로 설계했고, Kubernetes 공백은 별도 미니 확장 프로젝트에서 보완했습니다."

---

## Q. Kubernetes가 뭔 일을 해주는 건가?

컨테이너 여러 개를 운영할 때 생기는 귀찮은 일을 자동으로 처리해준다.

Docker 혼자 쓰면 "컨테이너 하나 실행"까지만 해준다. 쿠버네티스는 그 이후를 담당한다.

| 상황 | 쿠버네티스가 하는 것 |
|:---|:---|
| 컨테이너 죽으면 | 자동 재시작 |
| 트래픽 몰리면 | 컨테이너 수 자동 증가 (HPA) |
| 새 버전 배포 | 기존 꺼 하나씩 교체, 에러 나면 자동 롤백 |
| 컨테이너 여러 개 | 트래픽 알아서 분산 |

이 프로젝트에서는 AI 추론 서버(`/predict`)를 Lambda 대신 컨테이너로 올릴 때 활용.
모델 파일 교체가 Lambda보다 명확하고, 롤백도 이미지 버전으로 관리 가능.

---

## Q. HPA가 뭔가?

**HPA = Horizontal Pod Autoscaler** (수평 자동 확장)

> "CPU 70% 넘으면 컨테이너 더 띄워, 한가해지면 다시 줄여"

수직 확장(서버 스펙 올리기)이 아니라 수평 확장(컨테이너 수 늘리기) 방식.

```yaml
minReplicas: 1
maxReplicas: 5
targetCPUUtilizationPercentage: 70
```

**주의**: HPA가 동작하려면 `metrics-server`가 클러스터에 설치되어 있어야 한다.
kind에서 이걸 빠뜨리면 `unknown/unknown` 뜨면서 HPA가 아무것도 안 한다.

---

## Q. Helm은 뭔가?

**Helm = 쿠버네티스용 패키지 매니저** (apt, pip, npm과 같은 개념)

yaml 파일을 템플릿으로 만들고, 환경별 값을 분리해서 관리한다.

```yaml
# values.yaml — 환경별로 다른 부분만
dev:
  replicas: 1
prod:
  replicas: 3
```

```bash
helm install my-app ./chart -f values-prod.yaml
```

**면접 답변**
> "환경별 값 분리와 배포 단위 관리를 위해 사용했습니다."

---

## Q. kind가 뭔가?

**kind = Kubernetes in Docker**

로컬 PC에서 쿠버네티스 클러스터를 띄우는 도구.
Docker 컨테이너를 서버인 척 사용해서 가짜 클러스터를 만든다. 비용 없음.

| 도구 | 특징 |
|:---|:---|
| **kind** | Docker 기반, 가벼움, CI 환경과 유사 |
| minikube | VM 기반, 무거움 |
| k3s | 경량 배포판 |

```bash
kind create cluster --name devsecops-local
kubectl cluster-info --context kind-devsecops-local
kind delete cluster --name devsecops-local
```

로컬에서 다 검증하고 EKS는 최종 확인용 1회만 사용 → 비용 거의 0원.

---

## 예상 소요 시간

Phase 1 (로컬, 필수): **1~1.5주**

| 항목 | 예상 시간 |
|:---|:---:|
| k8s 기본 오브젝트 (Pod/Deployment/Service 등) | 2~3일 |
| AI 추론 서버 컨테이너화 | 0.5~1일 |
| kind 배포 + HPA | 1일 |
| Helm 차트 작성 | 1~1.5일 |
| Trivy 이미지 스캔 | 0.5일 |
| README + 완료 기준 체크 | 0.5일 |

Phase 2 (EKS, 선택): **+1~2일**
