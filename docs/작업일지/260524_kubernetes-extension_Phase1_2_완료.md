# [260524] kubernetes-extension Phase 1 + 2 완료

---

## 1. Phase 1: 로컬 실습 (kind)

### 환경 세팅
- kind 설치 (`v0.27.0`)
- kubectl 기존 설치 확인 (`v1.34.1`), Docker (`29.4.3`)
- `kind create cluster --name devsecops-local` → 클러스터 생성

### Docker 이미지 빌드 + 배포
- `docker build -f kubernetes-extension/ai-inference-server/Dockerfile -t ai-inference:latest .`
- `kind load docker-image ai-inference:latest --name devsecops-local`
- `kubectl apply -f kubernetes-extension/k8s/` → Deployment / Service / ConfigMap / HPA 생성
- `/predict` 호출 성공: `{"anomaly":1,"score":-0.0988}`

### Rolling Update / Rollback
- `docker tag ai-inference:latest ai-inference:v2` → kind 로드 → `kubectl set image`
- `kubectl rollout status` 확인 후 `kubectl rollout undo` 롤백
- `kubectl rollout history` → REVISION 2→3 확인

### Trivy 이미지 스캔 + CVE 조치

| CVE | 대상 | 조치 |
|:---|:---|:---|
| CVE-2024-47874 | starlette 0.38.6 | fastapi 0.115.6으로 업그레이드 |
| CVE-2025-62727 | starlette 0.41.3 | starlette>=0.49.1 핀 추가 |
| CVE-2025-69720 | ncurses (Debian) | 업스트림 미패치 — 인지 중 |

- CRITICAL: 0, Python 패키지 취약점 전부 조치 완료

### Helm 배포
- `kubectl delete -f kubernetes-extension/k8s/` → 기존 리소스 삭제
- `helm install ai-inference kubernetes-extension/helm/ai-inference/`
- `/predict` 호출 재확인

---

## 2. Phase 2: EKS 검증

### eksctl 설치
- `eksctl` 최신 버전 설치 → `/usr/local/bin/`

### ECR + 이미지 push
- `aws ecr create-repository --repository-name ai-inference`
- ECR 로그인 → `docker tag` + `docker push`
- ECR URI: `095035153545.dkr.ecr.us-east-1.amazonaws.com/ai-inference`

### EKS 클러스터 생성
- `eksctl create cluster --name devsecops-k8s --region us-east-1 --node-type t3.medium --nodes 1`
- 약 15분 소요

### 배포 + 검증
- `deployment.yaml` image를 ECR URI로 교체 후 `kubectl apply`
- `/predict` 호출 성공: `{"anomaly":1,"score":-0.0988}`
- 스크린샷 캡처 완료

### 클러스터 삭제 (과금 방지)
- `eksctl delete cluster --name devsecops-k8s` → `all cluster resources were deleted`
- `aws ecr delete-repository --repository-name ai-inference --force`
- `deployment.yaml` image 원복 (`ai-inference:latest`, `IfNotPresent`)

---

## 3. README 업데이트

- 제목 문구 수정
- Rolling Update / Rollback 섹션 추가
- Trivy 스캔 결과 표 + HIGH 취약점 설명 추가
- 구현 범위 섹션 추가

---

## 4. 트러블슈팅

**Docker credential helper 오류**
- 증상: `error getting credentials - err: exit status 1`
- 원인: `~/.docker/config.json`의 `credsStore: desktop.exe` — WSL에서 접근 불가
- 조치: `echo '{"credsStore": ""}' > ~/.docker/config.json` 후 재로그인

**starlette CVE 두 번 조치**
- 0.38.6 → 0.41.3 (1차) → 0.49.1 이상 (2차)
- fastapi 버전 고정 해제 (`fastapi>=0.115.6`)로 pip 의존성 충돌 해결

---

## 5. 완료 기준 체크

**Phase 1 (로컬)**
- [x] kind 클러스터에서 `/predict` 호출 성공
- [x] HPA 설정 완료
- [x] Helm 차트로 배포
- [x] Trivy 이미지 스캔 통과 (Python 패키지 CVE 조치)
- [x] Rolling Update / Rollback 검증

**Phase 2 (EKS)**
- [x] EKS 배포 후 엔드포인트 호출 성공
- [x] 클러스터 destroy 완료

---

## 다음 작업

- [ ] Velog 7편 작성 (kubernetes-extension 실습 정리)
- [ ] 이력서 kubernetes-extension 내용 반영
