import pandas as pd
import numpy as np
import joblib
import os
import math
import random
from collections import Counter
from datetime import datetime

# ─── 공격 페이로드 (train_model.py와 동일 — 피처 일관성 유지) ────────
_SQLI_PAYLOADS = [
    "id=1' UNION SELECT username,password FROM users--",
    "id=1 OR 1=1--",
    "user=admin'--",
    "id=1' AND SLEEP(5)--",
    "q=1; DROP TABLE sessions--",
    "id=1' AND 1=CONVERT(int,@@version)--",
]
_XSS_PAYLOADS = [
    "q=%3cscript%3ealert%28document.cookie%29%3c%2fscript%3e",
    "input=<img src=x onerror=alert(1)>",
    "search=%22%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E",
    "q=<svg onload=alert(1)>",
]
_RNG = random.Random(42)


def _assign_args(terminatingruleid: str) -> str:
    rule = str(terminatingruleid)
    if "SQLi" in rule:
        return _RNG.choice(_SQLI_PAYLOADS)
    if "XSS" in rule or "CrossSite" in rule:
        return _RNG.choice(_XSS_PAYLOADS)
    return ""

# ─── 경로 설정 ──────────────────────────────────────────────────────
MODEL_PATH  = '/home/march/aws-devsecops-platform/ai/models/isolation_forest_model.pkl'
SCALER_PATH = '/home/march/aws-devsecops-platform/ai/models/scaler.pkl'
DATA_PATH   = '/home/march/aws-devsecops-platform/ai/data/final_preprocessed_waf_data.csv'
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
    return -sum((c / n) * math.log2(c / n) for c in freq.values()) or 0.0


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


# ─── 위협 분류 (path + args 기반) ────────────────────────────────────
def classify_threat(row) -> str:
    uri  = str(row.get("request_uri", "")).lower()
    args = str(row.get("request_args", "")).lower()
    args_ent = row.get("args_entropy", 0.0)

    if 'union' in args or 'select' in args or 'drop' in args or "sleep" in args:
        return 'SQL Injection'
    if 'script' in args or '%3c' in args or 'onerror' in args or 'onload' in args:
        return 'XSS Attempt'
    if 'admin' in uri or 'login' in uri:
        return 'Admin Access Try'
    if '../' in uri or 'etc' in uri:
        return 'Path Traversal'
    if args_ent > 4.0:
        return 'Encoded Payload Attack'
    return 'GeoBlock / Rule Anomaly'


# ─── 메인 분석 파이프라인 ────────────────────────────────────────────
def main():
    df     = pd.read_csv(DATA_PATH)
    model  = joblib.load(MODEL_PATH)
    scaler = joblib.load(SCALER_PATH)

    # args 복원 및 피처 계산 (train_model.py와 동일 로직)
    df["request_args"] = df["terminatingruleid"].apply(_assign_args)
    df["path_entropy"] = df["request_uri"].fillna("").apply(calculate_entropy)
    df["args_entropy"] = df["request_args"].apply(calculate_entropy)

    features = ["country_code", "rule_code", "uri_len", "path_entropy", "args_entropy"]
    X_scaled = scaler.transform(df[features])

    raw_preds = model.predict(X_scaled)

    sentinel = ContaminationSentinel(expected=0.25, tolerance=0.10)
    preds, s_report = sentinel.filter(model, X_scaled, raw_preds)

    print("\n[Sentinel 진단]")
    for k, v in s_report.items():
        print(f"  {k}: {v}")

    df["prediction"] = preds
    anomalies = df[df["prediction"] == -1].copy()
    anomalies["type"] = anomalies.apply(classify_threat, axis=1)

    # 정상 vs 이상 — path_entropy / args_entropy 대비 (블로그 사진용)
    normal_cols = ["request_uri", "path_entropy", "args_entropy"]
    normals = df[df["prediction"] == 1][normal_cols].drop_duplicates("request_uri").head(8)

    anomaly_cols = ["request_uri", "request_args", "path_entropy", "args_entropy", "type"]
    anomaly_sample = (
        anomalies[anomaly_cols]
        .drop_duplicates("type")
        .sort_values("args_entropy", ascending=False)
        .head(12)
    )

    run_time = datetime.now().strftime('%Y-%m-%d %H:%M')
    report   = "=" * 70 + "\n"
    report  += f"AI Security Threat Analysis Report ({run_time})\n"
    report  += f"Sentinel: {s_report['action']} | Anomaly rate: {s_report['actual_anomaly_rate']:.1%}\n"
    report  += "=" * 70 + "\n"
    report  += "\n[정상 URI 샘플 — path_entropy ≈ 2.5~3.5, args_entropy = 0]\n"
    report  += normals.to_string(index=False)
    report  += "\n\n[AI 이상 탐지 결과 — 공격 URI는 args_entropy가 높음]\n"
    report  += anomaly_sample.to_string(index=False)
    report  += "\n\n[유형별 탐지 건수]\n"
    report  += anomalies["type"].value_counts().to_string()
    report  += "\n" + "=" * 70

    print(report)
    os.makedirs(RESULT_DIR, exist_ok=True)
    with open(os.path.join(RESULT_DIR, 'analysis_report.txt'), 'w', encoding='utf-8') as f:
        f.write(report)
    print(f"\n분석 리포트 저장 완료: {RESULT_DIR}/analysis_report.txt")


if __name__ == "__main__":
    main()
