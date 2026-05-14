import pandas as pd
import numpy as np
import joblib
import re
import os
import math
from collections import Counter
from datetime import datetime

# ─── 경로 설정 ──────────────────────────────────────────────────────
MODEL_PATH  = '/home/march/aws-devsecops-platform/ai/models/isolation_forest_model.pkl'
SCALER_PATH = '/home/march/aws-devsecops-platform/ai/models/scaler.pkl'
DATA_PATH   = '/home/march/aws-devsecops-platform/ai/data/URI별 이상 징후 분석 (Target Analysis).csv'
RESULT_DIR  = '/home/march/aws-devsecops-platform/ai/results'


# ─── Shannon Entropy 함수 (기존 호환 + 강화) ────────────────────────
def calculate_entropy(s) -> float:
    """
    Shannon Entropy: H(X) = -Σ p(xᵢ) * log₂ p(xᵢ)

    보안 탐지 기준값:
      정상 URI:              ≈ 2.5 ~ 3.5
      SQL Injection:         ≈ 3.8 ~ 4.2
      Base64/URL 인코딩:     ≈ 4.5 ~ 5.5
      무작위 크래킹:          ≈ 5.0+
    """
    if not s or (isinstance(s, float) and math.isnan(s)):
        return 0.0
    s = str(s)
    n = len(s)
    freq = Counter(s)
    return -sum((c / n) * math.log2(c / n) for c in freq.values())


def calculate_class_entropy(s) -> float:
    """
    문자 클래스 분포 엔트로피 — URL 인코딩/Base64 페이로드 탐지 강화.

    단순 문자 빈도 엔트로피와 달리, 알파벳·숫자·특수문자·공백의
    클래스별 비율을 측정. 인코딩된 공격 페이로드는 특수문자 비율이
    비정상적으로 높거나 낮아 이 지표에서 두드러짐.
    """
    if not s or (isinstance(s, float) and math.isnan(s)):
        return 0.0
    s = str(s)
    total = len(s)
    classes = {
        "alpha":   sum(1 for c in s if c.isalpha()),
        "digit":   sum(1 for c in s if c.isdigit()),
        "special": sum(1 for c in s if not c.isalnum() and c not in (" ", "\t")),
        "space":   sum(1 for c in s if c in (" ", "\t")),
    }
    probs = [v / total for v in classes.values() if v > 0]
    if not probs:
        return 0.0
    return -sum(p * math.log2(p) for p in probs)


# ─── Contamination Sentinel ──────────────────────────────────────────
class ContaminationSentinel:
    """
    IsolationForest contamination 이탈 방지 필터.

    훈련 시 설정한 contamination과 실제 배치의 이상 예측 비율이
    크게 벗어날 경우 (데이터 분포 변화, 정상 트래픽만 유입 등)
    decision_function 점수를 이용해 임계값을 재조정한다.

    Parameters
    ----------
    expected    : 훈련 시 설정한 contamination 값
    tolerance   : 허용 오차 (실제율이 이 범위 내면 재조정 생략)
    min_c / max_c : 재조정 시 contamination 클램핑 범위
    """

    def __init__(
        self,
        expected: float = 0.15,
        tolerance: float = 0.10,
        min_c: float = 0.01,
        max_c: float = 0.40,
    ):
        self.expected  = expected
        self.tolerance = tolerance
        self.min_c     = min_c
        self.max_c     = max_c

    def filter(self, model, X: np.ndarray, raw_preds: np.ndarray):
        """
        Returns
        -------
        preds  : 최종 예측 배열 (-1=이상, 1=정상)
        report : Sentinel 진단 딕셔너리
        """
        n           = len(raw_preds)
        actual_rate = float((raw_preds == -1).sum()) / n

        report = {
            "expected_contamination": self.expected,
            "actual_anomaly_rate":    round(actual_rate, 4),
            "sentinel_triggered":     False,
            "action":                 "pass_through",
        }

        if abs(actual_rate - self.expected) <= self.tolerance:
            return raw_preds.copy(), report

        # 허용 범위 초과 → decision_function 점수로 재임계화
        report["sentinel_triggered"] = True
        scores    = model.decision_function(X)
        clamped   = max(self.min_c, min(self.max_c, actual_rate))
        threshold = np.percentile(scores, clamped * 100)
        adjusted  = np.where(scores < threshold, -1, 1).astype(int)

        report.update({
            "action":                "re_threshold",
            "clamped_contamination": round(clamped, 4),
            "adjusted_anomaly_rate": round(float((adjusted == -1).sum()) / n, 4),
            "threshold_score":       round(float(threshold), 6),
        })
        return adjusted, report


# ─── 피처 추출 (기존 4개 피처 — 모델 입력 호환 유지) ─────────────────
def extract_features(uri) -> list:
    uri = str(uri)
    return [
        len(uri),
        len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)),
        sum(1 for w in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../']
            if w in uri.lower()),
        calculate_entropy(uri),
    ]


# ─── 위협 분류 (엔트로피 + 클래스 엔트로피 활용) ─────────────────────
def classify_threat(row) -> str:
    uri   = str(row.get("request_uri", "")).lower()
    ent   = row.get("uri_entropy", 0.0)
    c_ent = row.get("class_entropy", 0.0)

    if 'script' in uri or '%3c' in uri:
        return 'XSS Attempt'
    if 'admin' in uri or 'login' in uri:
        return 'Admin Access Try'
    if '../' in uri or 'etc' in uri:
        return 'Path Traversal'
    # 고엔트로피 → 인코딩된 페이로드 (Base64, URL 이중 인코딩)
    if ent > 4.5 or c_ent > 1.8:
        return 'Encoded Payload Attack'
    return 'Advanced Obfuscated Attack'


# ─── 메인 분석 파이프라인 ────────────────────────────────────────────
def main():
    df    = pd.read_csv(DATA_PATH)
    model = joblib.load(MODEL_PATH)

    target_col = 'request_uri'

    # 기존 4-피처 모델 입력 (하위 호환)
    try:
        col_names = list(model.feature_names_in_)
    except AttributeError:
        col_names = ["uri_len", "special_chars", "keyword_count", "uri_entropy"]

    X_df = pd.DataFrame(
        df[target_col].apply(extract_features).tolist(),
        columns=col_names,
    )
    X_np = X_df.values

    raw_preds = model.predict(X_np)

    # Sentinel 필터 적용
    sentinel = ContaminationSentinel(expected=0.15, tolerance=0.10)
    preds, s_report = sentinel.filter(model, X_np, raw_preds)

    print("\n[Sentinel 진단]")
    for k, v in s_report.items():
        print(f"  {k}: {v}")

    # 추가 엔트로피 피처 (분석/분류용 — 모델 입력 아님)
    df["uri_entropy"]   = df[target_col].apply(calculate_entropy)
    df["class_entropy"] = df[target_col].apply(calculate_class_entropy)
    df["prediction"]    = preds

    anomalies = df[df["prediction"] == -1].copy()
    anomalies["type"] = anomalies.apply(classify_threat, axis=1)

    # 리포트 생성
    run_time = datetime.now().strftime('%Y-%m-%d %H:%M')
    report   = "=" * 65 + "\n"
    report  += f"AI Security Threat Analysis Report ({run_time})\n"
    report  += f"Sentinel: {s_report['action']} | "
    report  += f"Anomaly rate: {s_report['actual_anomaly_rate']:.1%}\n"
    report  += "=" * 65 + "\n"
    report  += anomalies[[target_col, "uri_entropy", "class_entropy", "type"]].to_string(index=False)
    report  += "\n" + "=" * 65

    print(report)
    os.makedirs(RESULT_DIR, exist_ok=True)
    with open(os.path.join(RESULT_DIR, 'analysis_report.txt'), 'w', encoding='utf-8') as f:
        f.write(report)
    print(f"\n분석 리포트 저장 완료: {RESULT_DIR}/analysis_report.txt")


if __name__ == "__main__":
    main()
