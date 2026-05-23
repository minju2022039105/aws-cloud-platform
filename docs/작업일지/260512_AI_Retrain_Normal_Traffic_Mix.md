# [260512] AI 탐지 엔진 재학습 + Velog 3편 보안 검증 정리

## 1. 배경

기존 학습 데이터(`final_preprocessed_waf_data.csv`)는 Nikto 공격 로그 중심으로 구성되어 있어 정상 트래픽(ALLOW) 패턴이 부족했다.  
이 상태에서는 Isolation Forest가 “정상 요청”의 기준을 충분히 학습하지 못해 contamination 설정의 신뢰도가 낮았다.

또한 Velog 3편에서 tfsec을 보안 검증 사례로 다루고 있었기 때문에, 실제 코드 기준으로 tfsec을 재실행하고 CI 파이프라인 반영 여부까지 정리할 필요가 있었다.

---

## 2. 목표

- 정상 트래픽 합성 데이터 생성
- 공격 로그 + 정상 로그 혼합 CSV 구성
- Isolation Forest 재학습 및 점수 분포 확인
- Velog 3편 최종 수정 및 업로드
- tfsec 결과 재검토 후 CI/CD 파이프라인 반영

---

## 3. AI 탐지 엔진 재학습

### 데이터 구성

| 구분 | 건수 | 비고 |
|---|---:|---|
| 공격 로그 | 400건 | 기존 Nikto BLOCK 로그 중 유효 행 |
| 정상 로그 | 1,350건 | 합성 정상 트래픽 |
| 합계 | 1,750건 | 셔플 후 학습 CSV 교체 |

정상 트래픽은 `scripts/generate_normal_traffic.py`로 생성했다.  
KR IP, 정상 URI 패턴, `action=ALLOW`, `rule_code=2` 기준으로 구성했다.

### 주요 수정

- `rule_code=2`를 Default_Action / ALLOW로 사용
- 기존 공격-only 데이터 편향 완화
- contamination: `0.15 → 0.25`
- `uri_entropy` 기반 Shannon Entropy 피처 활용

### 재학습 결과

| 지표 | 결과 |
|---|---:|
| 이상 탐지 건수 | 345건 |
| 탐지 비율 | 19.2% |
| Score IQR | 0.0611 |
| 점수 분포 | 과적합 징후 없음 |
| 모델 저장 경로 | `ai-security/models/isolation_forest_model.pkl` |

정상 트래픽을 혼합하면서 전량 BLOCK 데이터 기반 학습 문제를 완화했다.  
점수 분포도 특정 구간에 과하게 몰리지 않아, 재학습 결과는 안정적인 편으로 판단했다.

---

## 4. Velog 3편 수정 및 업로드

Velog 3편은 WAF Terraform 코드화와 tfsec 분석을 중심으로 작성했다.

### 반영한 수정

- 비용 표현 완화  
  - “무거운 룰” → “평가 로직이 복잡한 룰”
- Scope-down 예시 수정  
  - `/admin/` 제외 → `/health` 제외
- tfsec 섹션 압축  
  - Rule ID별 상세 설명 축소
  - 결과 테이블, 수정/무시 판단, 서버리스 전환 효과는 유지
- 마무리 강화  
  - 단순 도구 사용기가 아니라 보안·비용·운영 리스크를 함께 고려한 설계 경험으로 정리

업로드 완료.

---

## 5. tfsec 재검토 및 CI 반영

Velog 3편에서 tfsec을 다루고 있었지만, 실제 CI/CD 파이프라인에는 포함되어 있지 않았다.  
취업용 포트폴리오 관점에서 글과 실제 파이프라인의 정합성을 맞추기 위해 tfsec을 수동 실행 후 정리했다.

### 최초 결과

| 심각도 | 건수 |
|---|---:|
| Critical | 1 |
| High | 10 |
| Medium | 8 |
| Low | 11 |

### 처리 기준

- 실제 수정이 필요한 항목 → 코드 수정
- 설계상 필요한 항목 → `tfsec:ignore` 주석으로 사유 기록
- Low/Medium 항목 → CI에서는 `--minimum-severity HIGH` 기준으로 제외

### 실제 수정

- Cognito password reuse prevention  
  - `3 → 24`로 강화

### 재실행 결과

| 항목 | 결과 |
|---|---:|
| Critical | 0 |
| High | 0 |
| Ignored | 36 |

이후 `deploy.yml`에 tfsec 스텝을 추가했고, GitHub Actions 보안 게이트가 통과했다.

---

## 6. 정리

이번 작업은 단순히 AI 모델을 다시 학습하거나 tfsec을 추가한 것이 아니라, 프로젝트의 설명과 실제 구현 상태를 맞추는 과정이었다.

AI 탐지 엔진 쪽에서는 정상 트래픽을 추가해 데이터 편향을 줄였고, 보안 인프라 쪽에서는 tfsec 결과를 기준으로 실제 수정할 항목과 설계상 감수할 항목을 구분했다.

특히 Velog 3편은 단순 기술 정리가 아니라, WAF 우선순위·Scope-down·tfsec ignore·서버리스 전환처럼 “왜 그렇게 판단했는지”를 보여주는 포트폴리오 글로 정리했다.

---

## 7. 다음 작업

- [ ] Velog 4편: AI 이상 탐지 엔진 작성
  - Isolation Forest 선택 이유
  - Shannon Entropy 피처
  - contamination 조정 근거
  - 정상/공격 데이터 불균형 문제
- [ ] Velog 5편: KMS 비용 폭증 트러블슈팅
  - CloudTrail 추적 과정
  - KMS 호출 원인 분석
  - Bucket Key 적용 이유