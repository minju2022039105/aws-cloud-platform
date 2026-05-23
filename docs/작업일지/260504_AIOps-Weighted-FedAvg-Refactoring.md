# [260504] Security-AIOps-IsolationForest 고도화 — 데이터 품질 진단 및 Weighted FedAvg 구현

## 1. 개요 (목표)

- **졸업작품의 한계 극복**: 가공된 데이터셋(정확도 91%)에서 벗어나, 실제 **Nikto** 공격 로그를 기반으로 한 실무형 탐지 모델 검증
- **데이터 품질(Data Quality) 진단**: 벤치마크를 통한 Sentinel 값의 영향력 분석 및 이상치 탐지 성능 최적화
- **Weighted FedAvg(연합 학습) 구현**: 데이터 불균형 환경(본사 vs 지사)을 가정한 가중치 기반 모델 집계 아키텍처 설계
- **트러블슈팅**: `scikit-learn 1.8.0` 버전 업데이트에 따른 모델 내부 속성 접근 이슈 해결

## 2. 환경 정보

- **OS**: Windows 11 + Ubuntu (WSL)
- **Language**: Python 3.x (Virtual Environment)
- **ML Library**: scikit-learn v1.8.0
- **Tools**: Nikto (공격 로그 생성), Isolation Forest (이상 탐지 알고리즘)

## 3. 작업 절차 (Step by Step)

1. **Nikto 공격 시나리오 수행**: 실제 WAF 환경을 모사한 SQL Injection 공격 수행 및 로그 수집
2. **`benchmark.py` 실행 및 데이터 진단**: `contamination` 하이퍼파라미터 튜닝 및 학습 데이터 내 Sentinel(가짜 데이터) 노이즈 발견
3. **연합 학습 엔진 설계**: 각 노드의 데이터 샘플 수에 비례하여 글로벌 모델 기여도를 조절하는 **Weighted FedAvg** 로직 개발
4. **sklearn 버전 호환성 패치**: `sklearn 1.8.0`에서 변경된 `_decision_path_lengths` 등 Private 속성 추출 로직 적용
5. **`federated_learning.py` 시뮬레이션**: 3개 가상 노드(IDC, 지사, 소규모 지점) 간의 모델 파라미터 전송 및 집계 성공 확인

## 4. 핵심 기술 설계 상세

### ① 데이터 품질 분석 기반 파라미터 최적화

```python
# benchmark.py를 통한 contamination 결정 로직
# IQR 안정성과 실제 공격 비율(14.8%)의 교차 지점 확인
권장 contamination: 0.05
```
**설계 의도**: 단순히 성능 수치에만 매몰되지 않고, 데이터셋 내의 Sentinel 값(국가 코드 99 등)이 지표를 왜곡함을 인지함. 이에 따라 비지도 학습(Unsupervised) 관점에서 점수 분포를 분석하여 최적의 임계치를 도출함.

### ② Weighted FedAvg — 가중치 기반 모델 집계

```python
# 집계 가중치 산출 로직
weights = [n_samples / total_samples for n_samples in node_samples]
# 결과: edge-node-1(60.0%) / edge-node-2(24.9%) / edge-node-3(15.1%)
```
**설계 의도**: 현실적인 인프라 환경에서는 노드마다 보유한 로그의 양이 다름. 데이터가 적은 소규모 지점의 모델이 전체 글로벌 모델을 왜곡하지 않도록 **데이터 볼륨 기반 가중치**를 적용함.

### ③ Privacy-Preserving: 원본 로그 비노출 설계

- **Privacy Principle**: 각 노드에서 학습된 Isolation Forest의 **파라미터(Tree 구조, Offset)**만 서버로 전송.
- **Security Value**: 개인정보보호법(PIPA) 준수가 필요한 WAF 로그 원본을 이동시키지 않고도, 다수 지점의 위협 지식을 통합할 수 있는 아키텍처 구현.

## 5. 트러블슈팅

| 구분 | 증상 | 원인 | 조치 |
| :--- | :--- | :--- | :--- |
| **속성 접근 오류** | `AttributeError: '_decision_path_lengths'` 발생 | sklearn 1.8.0 업데이트로 내부 계산 속성이 Private으로 변경됨 | `getattr`을 통한 안전한 속성 추출 및 모델 재구성(Reconstruction) 로직 추가 |
| **지표 왜곡** | 특정 데이터에서 Recall이 극단적으로 낮게 측정됨 | 학습 데이터 내 Sentinel 값이 실제 위협보다 더 큰 이상치로 간주됨 | 비지도 학습 점수 분포 분석으로 전환하여 데이터 품질 한계를 명시적으로 기록함 |
| **모델 불일치** | 글로벌 모델 집계 후 추론(predict) 결과 값 오류 | 가중 평균 시 `offset_` 파라미터가 정확히 동기화되지 않음 | `extract_parameters` 함수 내에 모든 계산 보조 지표를 포함하여 1:1 매핑 구현 |

## 6. 테스트 및 검증

- **데이터 진단 완료**: `benchmark.py`를 통해 데이터 정제 필요성 및 최적 contamination(0.05) 확인
- **연합 학습 성공**: 3개 노드 모델 집계 후 `Global Model Aggregation Complete` 로그 확인
- **검증 결과**: 원본 데이터 전송 없이도 450건의 전체 데이터를 대변하는 글로벌 모델 생성 (이상 탐지 비율 55.6% 확보)

## 7. Technical Insight — 데이터 품질과 프라이버시의 균형

이번 고도화 작업의 핵심은 **"모델의 성능보다 데이터의 정직함을 우선시한 것"**이다. 



1. **데이터 위생(Data Hygiene)**: `benchmark.py`를 통해 발견한 Sentinel 값의 문제는 추후 Data Cleaning 파이프라인의 필요성을 증명하는 중요한 근거가 되었다.
2. **기술적 집요함**: 라이브러리 버전 이슈로 모델이 깨지는 상황에서, 단순히 버전을 낮추는 대신 모델의 내부 구조를 뜯어보고 재구성하는 방식을 택해 **scikit-learn 모델의 내부 동작 원리**를 깊이 이해하게 되었다.

## 8. 스크린샷 첨부 가이드

| 우선순위 | 캡처 대상 | 파일명(참조) | 설명 |
| :---: | :--- | :--- | :--- |
| ⭐⭐⭐ | **벤치마크 분석 결과** | `/home/march/aws-devsecops-platform/docs/devlog/image/260504_benchmark_analysis.png` | 데이터 품질 한계 및 권장 파라미터 도출 근거 |
| ⭐⭐⭐ | **FedAvg 시뮬레이션 결과** | `/home/march/aws-devsecops-platform/docs/devlog/image/260504_fedavg_simulation.png` | 노드별 가중치 반영 및 글로벌 모델 생성 완료 화면 |
| ⭐⭐ | **코드 수정 사항 (sklearn 패치)** | `/home/march/aws-devsecops-platform/docs/devlog/image/260504_sklearn_patch_code.png` | `extract_parameters` 함수 내 Private 속성 처리 부분 |

## 9. 작업 완료 항목 (Checklist)

- [x] Nikto 기반 실제 공격 로그 수집 및 학습 적용
- [x] `benchmark.py`를 통한 데이터 품질 진단 및 파라미터 튜닝
- [x] `sklearn 1.8.0` 호환성 이슈 해결 및 모델 재구성 로직 성공
- [x] Weighted FedAvg (가중 평균 집계) 시뮬레이션 성공
- [x] 원본 로그 비노출(Privacy-Preserving) 설계 원칙 확인

## 10. 다음 계획 / TODO

- **Feature Engineering**: Shannon Entropy 피처를 도입하여 SQL Injection 탐지 정교화
- **Dashboard**: `performance_metrics.json` 데이터를 시각화하는 Streamlit 또는 Grafana 대시보드 검토
- **CI/CD 연동**: GitHub Actions에서 모델 성능 테스트 자동화 파이프라인 구축

---
