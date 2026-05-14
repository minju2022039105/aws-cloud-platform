"""
로컬 노드용 Isolation Forest 학습 스크립트.

개발 배경:
  졸업작품 당시 원본 WAF 로그 확보의 어려움으로 인해 학습 데이터가 충분하지 않았고,
  이로 인해 모델이 소수 공격 패턴에 과적합되어 일반화 성능 검증에 실패했다.
  이번 고도화에서는 두 가지 방향으로 이 문제를 해결한다.

  1. Shannon Entropy 피처:
     적은 샘플에서 통계적 분포(mean/std)는 불안정하지만,
     문자열의 정보 구조(엔트로피)는 샘플 수에 덜 의존적이다.
     → 데이터가 적어도 공격 패턴의 '비정상적인 정보 밀도'를 포착 가능.

  2. 소량 데이터 과적합 방지 파라미터 설계:
     max_samples, max_features, n_estimators를 데이터 크기에 연동하여
     모델이 훈련 데이터를 암기하지 않고 구조를 학습하도록 강제.
"""

import math
import os
import joblib
import numpy as np
import pandas as pd
from collections import Counter
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler

# ─── 경로 설정 ──────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(BASE_DIR, "../../ai/data/final_preprocessed_waf_data.csv")
MODEL_OUT = os.path.join(BASE_DIR, "../../ai/models/isolation_forest_model.pkl")
SCALER_OUT = os.path.join(BASE_DIR, "../../ai/models/scaler.pkl")

# ─── 하이퍼파라미터 ──────────────────────────────────────────────
# contamination=0.25 설정 근거:
#   혼합 재학습 데이터(공격 400건 + 정상 1350건 = 1800건) 기준
#   실제 공격 비율 400/1800 ≈ 22.2% → 0.25로 올림 (소량 오차 여유)
CONTAMINATION = 0.25
RANDOM_STATE = 42

# 소량 데이터 과적합 방지: n_estimators를 충분히 크게 설정
# - 트리가 많을수록 개별 트리의 분산이 평균화되어 특정 샘플 암기 방지
# - FedAvg 병합 후에도 각 노드 기여분이 유의미하도록 200 유지
N_ESTIMATORS = 200


# ─── Shannon Entropy 피처 ────────────────────────────────────────
def calculate_entropy(text: str) -> float:
    """
    Shannon Entropy(정보 엔트로피) 계산.

    소량 데이터에서 이 피처가 효과적인 이유:
      통계적 피처(평균, 표준편차)는 샘플이 적으면 추정값 자체가 불안정하다.
      반면 엔트로피는 단일 문자열의 내재적 정보 구조를 측정하므로,
      샘플 크기와 무관하게 공격 URI의 '비정상적인 문자 분포'를 포착한다.

    보안 탐지 관점:
      - 정상 URI (/api/users/profile):         entropy ≈ 3.0 ~ 3.5
      - SQL Injection (?id=1' UNION SELECT):   entropy ≈ 3.8 ~ 4.2
      - Base64/URL 인코딩된 페이로드:           entropy ≈ 4.5 ~ 5.5
      - 무작위 크래킹 시도:                     entropy ≈ 5.0+

    수식: H(X) = -Σ p(x_i) * log₂ p(x_i)
    """
    if not text:
        return 0.0
    freq = Counter(text)
    n = len(text)
    return -sum((c / n) * math.log2(c / n) for c in freq.values())


def rule_code_entropy(rule_code: int) -> float:
    """
    rule_code를 이진 문자열로 변환 후 엔트로피 계산.
    동일 rule_code 반복 = 스캔 공격 징후 (엔트로피 낮음).
    """
    return calculate_entropy(bin(int(rule_code)))


def add_entropy_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    데이터프레임에 Shannon Entropy 기반 피처 2개 추가.
    uri 컬럼이 없을 때는 rule_code 기반 대체 엔트로피 사용.
    """
    df = df.copy()

    if "uri" in df.columns:
        df["uri_entropy"] = df["uri"].fillna("").apply(calculate_entropy)
    else:
        # 실제 URI 없을 때: rule_code의 엔트로피로 대체
        # 프로덕션에서는 WAF 로그에서 원본 URI를 파싱해 사용 권장
        df["uri_entropy"] = df["rule_code"].apply(rule_code_entropy)

    df["rule_entropy"] = df["rule_code"].apply(rule_code_entropy)
    return df


# ─── 소량 데이터 과적합 방지 파라미터 계산 ───────────────────────
def _safe_hyperparams(n_samples: int) -> dict:
    """
    데이터 크기에 따라 과적합 방지 파라미터를 동적으로 결정.

    핵심 원리:
      [max_samples]
        기본값(256 또는 n_samples)을 데이터의 60%로 제한.
        → 각 트리가 전체 데이터를 보지 못하게 강제 (Bagging 효과 극대화).
        → 소량 데이터에서 특정 샘플이 모든 트리에 등장하는 암기 현상 방지.

      [max_features]
        전체 피처의 60-80%만 각 트리에 노출.
        → 피처 다양성 확보 → 개별 트리의 분산 감소.
        → Random Subspace Method와 동일한 원리.

      [n_estimators]
        트리 수를 늘릴수록 개별 트리의 노이즈가 평균화됨.
        소량 데이터일수록 더 많은 트리가 필요.
    """
    # 60% 서브샘플링: 전체를 보면 암기, 너무 적으면 underfitting
    max_samples = max(16, int(n_samples * 0.6))

    # 피처 서브샘플링: 피처 수에 비례하여 조정
    max_features = 0.7  # 70% of features per tree

    # 소량 데이터일수록 트리를 더 많이 (분산 평균화)
    n_estimators = N_ESTIMATORS + max(0, (100 - n_samples) * 2)

    return {
        "max_samples": max_samples,
        "max_features": max_features,
        "n_estimators": min(n_estimators, 500),  # 상한선
    }


def _check_score_stability(model: IsolationForest, X: np.ndarray) -> None:
    """
    과적합 징후 진단: 이상 점수 분포의 분리도를 확인.

    건강한 모델: 정상/이상 점수 분포가 명확히 구분됨.
    과적합 모델: 거의 모든 점수가 경계값에 몰림 (학습 데이터 암기 신호).
    """
    scores = model.decision_function(X)
    q25, q75 = np.percentile(scores, [25, 75])
    iqr = q75 - q25

    print(f"\n[점수 분포 안정성 진단]")
    print(f"  Q25={q25:.4f}, Q75={q75:.4f}, IQR={iqr:.4f}")

    if iqr < 0.05:
        print("  ⚠️  경고: IQR이 매우 좁음 → 과적합 또는 피처 정보력 부족 의심")
        print("       → max_samples 축소, 피처 재검토 권장")
    else:
        print("  ✅ 점수 분포 정상: 모델이 정상/이상을 구분하고 있음")


# ─── 학습 파이프라인 ─────────────────────────────────────────────
def train(data_path: str = DATA_PATH, node_id: str = "local") -> tuple:
    df = pd.read_csv(data_path)
    df = add_entropy_features(df)

    features = ["country_code", "rule_code", "uri_len", "uri_entropy"]
    missing = [f for f in features if f not in df.columns]
    if missing:
        raise ValueError(f"피처 누락: {missing}")

    X = df[features].copy()
    n_samples = len(X)

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    hp = _safe_hyperparams(n_samples)

    print(f"\n[{node_id}] 학습 시작 | 샘플 수: {n_samples}")
    print(f"  하이퍼파라미터: n_estimators={hp['n_estimators']}, "
          f"max_samples={hp['max_samples']} ({hp['max_samples']/n_samples*100:.0f}%), "
          f"max_features={hp['max_features']}")

    model = IsolationForest(
        n_estimators=hp["n_estimators"],
        max_samples=hp["max_samples"],
        max_features=hp["max_features"],
        contamination=CONTAMINATION,
        random_state=RANDOM_STATE,
    )
    model.fit(X_scaled)

    _check_score_stability(model, X_scaled)

    preds = model.predict(X_scaled)
    n_anomaly = int((preds == -1).sum())
    print(f"  이상 탐지: {n_anomaly}/{n_samples} ({n_anomaly/n_samples*100:.1f}%)")

    os.makedirs(os.path.dirname(MODEL_OUT), exist_ok=True)
    joblib.dump(model, MODEL_OUT)
    joblib.dump(scaler, SCALER_OUT)
    print(f"  모델 저장: {MODEL_OUT}")

    return model, scaler, n_samples


if __name__ == "__main__":
    train()
