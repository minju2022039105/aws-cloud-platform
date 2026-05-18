"""
현행 운영 모델(train_model.py 계보) 성능 평가 스크립트.

평가 방식:
  - 데이터: final_preprocessed_waf_data.csv (WAF 구조화 로그, 1,750건)
  - 정답 레이블: action 컬럼 (BLOCK=1 공격, ALLOW=0 정상)
  - 피처: country_code, rule_code, uri_len, uri_entropy
  - uri_entropy: rule_code 이진 문자열 Shannon Entropy (train_model.py와 동일 로직)

Before/After 해석:
  - Before (WAF 정적 룰 단독): action 컬럼 자체가 WAF 탐지 결과
  - After  (WAF + AI 이상 탐지): AI가 WAF 허용(ALLOW) 트래픽 중 이상 패턴 추가 탐지
"""

import json
import math
import os
import time
from collections import Counter

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import confusion_matrix, f1_score, precision_score, recall_score

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(BASE_DIR, "../../ai/data/final_preprocessed_waf_data.csv")
MODEL_PATH = os.path.join(BASE_DIR, "../../ai/models/isolation_forest_model.pkl")
SCALER_PATH = os.path.join(BASE_DIR, "../../ai/models/scaler.pkl")
RESULT_DIR = os.path.join(BASE_DIR, "../../ai/results")

FEATURES = ["country_code", "rule_code", "uri_len", "uri_entropy"]


def _entropy(text: str) -> float:
    if not text:
        return 0.0
    freq = Counter(text)
    n = len(text)
    return -sum((c / n) * math.log2(c / n) for c in freq.values())


def rule_code_entropy(rule_code: int) -> float:
    """rule_code 이진 문자열의 Shannon Entropy — train_model.py와 동일 로직."""
    return _entropy(bin(int(rule_code)))


def load_data(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["uri_entropy"] = df["rule_code"].apply(rule_code_entropy)
    df["y_true"] = (df["action"] == "BLOCK").astype(int)
    return df


def main():
    df = load_data(DATA_PATH)
    model = joblib.load(MODEL_PATH)
    scaler = joblib.load(SCALER_PATH)

    X = df[FEATURES].copy()
    X_scaled = scaler.transform(X)
    y_true = df["y_true"].values

    start = time.time()
    raw_preds = model.predict(X_scaled)
    elapsed = time.time() - start

    # Isolation Forest: -1 = 이상치(공격), 1 = 정상
    y_pred = (raw_preds == -1).astype(int)

    n_total = len(df)
    n_attacks_waf = int(y_true.sum())
    n_normal_waf = n_total - n_attacks_waf
    n_ai_flagged = int(y_pred.sum())

    prec = precision_score(y_true, y_pred, zero_division=0)
    rec = recall_score(y_true, y_pred, zero_division=0)
    f1 = f1_score(y_true, y_pred, zero_division=0)

    tn, fp, fn, tp = confusion_matrix(y_true, y_pred).ravel()
    fpr = fp / (fp + tn) if (fp + tn) > 0 else 0.0
    avg_latency_ms = (elapsed / n_total) * 1000

    print("\n" + "=" * 58)
    print("  WAF + AI 이상 탐지 엔진 성능 평가 (현행 모델)")
    print("=" * 58)

    print(f"\n[데이터셋]")
    print(f"  전체 로그        : {n_total:,} 건")
    print(f"  WAF 차단 (공격)  : {n_attacks_waf:,} 건  ({n_attacks_waf/n_total*100:.1f}%)")
    print(f"  WAF 허용 (정상)  : {n_normal_waf:,} 건  ({n_normal_waf/n_total*100:.1f}%)")

    print(f"\n[AI 탐지 결과]")
    print(f"  AI 이상 플래그   : {n_ai_flagged:,} 건  ({n_ai_flagged/n_total*100:.1f}%)")
    print(f"  TP (공격 정탐)   : {tp:,} 건")
    print(f"  FP (정상 오탐)   : {fp:,} 건")
    print(f"  FN (공격 미탐)   : {fn:,} 건")
    print(f"  TN (정상 정탐)   : {tn:,} 건")

    print(f"\n[성능 지표]")
    print(f"  Precision        : {prec:.4f}  ({prec*100:.1f}%)")
    print(f"  Recall           : {rec:.4f}  ({rec*100:.1f}%)")
    print(f"  F1-Score         : {f1:.4f}")
    print(f"  FPR (오탐률)     : {fpr:.4f}  ({fpr*100:.1f}%)")
    print(f"  건당 처리 속도   : {avg_latency_ms:.4f} ms")

    print(f"\n[Before / After 비교]")
    print(f"  ┌──────────────────────────────────────────────────┐")
    print(f"  │ 구분              탐지 건수   방식               │")
    print(f"  ├──────────────────────────────────────────────────┤")
    print(f"  │ Before (WAF만)    {n_attacks_waf:>6,} 건    정적 룰 매칭        │")
    print(f"  │ After  (WAF+AI)   {n_ai_flagged:>6,} 건    비지도 이상 탐지    │")
    print(f"  │ AI 추가 탐지        {fp:>4,} 건    WAF 허용 → AI 차단  │")
    print(f"  └──────────────────────────────────────────────────┘")
    print(f"\n  WAF 차단 {n_attacks_waf}건 중 AI가 {tp}건 독립 검증 (Recall {rec*100:.1f}%)")
    print(f"  WAF 허용 {n_normal_waf}건 중 AI가 {fp}건 추가 이상 탐지")
    print("=" * 58)

    results = {
        "run_timestamp": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M"),
        "model_type": "IsolationForest (train_model.py / contamination=0.25)",
        "dataset": "final_preprocessed_waf_data.csv",
        "features": FEATURES,
        "label_source": "action column (BLOCK=1, ALLOW=0)",
        "n_total": n_total,
        "n_attacks_waf": n_attacks_waf,
        "n_normal_waf": n_normal_waf,
        "n_ai_flagged": n_ai_flagged,
        "tp": int(tp),
        "fp": int(fp),
        "fn": int(fn),
        "tn": int(tn),
        "precision": round(prec, 4),
        "recall": round(rec, 4),
        "f1_score": round(f1, 4),
        "fpr": round(fpr, 4),
        "avg_latency_ms": round(avg_latency_ms, 4),
        "before_waf_detections": n_attacks_waf,
        "after_ai_additional_detections": int(fp),
    }

    os.makedirs(RESULT_DIR, exist_ok=True)
    out_path = os.path.join(RESULT_DIR, "performance_metrics_v2.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=4, ensure_ascii=False)
    print(f"\n결과 저장: {out_path}\n")


if __name__ == "__main__":
    main()
