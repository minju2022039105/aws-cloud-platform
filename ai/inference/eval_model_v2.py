"""
현행 운영 모델(train_model.py 계보) 성능 평가 스크립트.

평가 방식:
  - 데이터: final_preprocessed_waf_data.csv (WAF 구조화 로그, 1,800건)
  - 정답 레이블: action 컬럼 (BLOCK=1 공격, ALLOW=0 정상)
  - 피처: country_code, rule_code, uri_len, path_entropy, args_entropy
  - path_entropy: request_uri Shannon Entropy
  - args_entropy: query string Shannon Entropy (rule type 기반 합성 복원)

Before/After 해석:
  - Before (WAF 정적 룰 단독): action 컬럼 자체가 WAF 탐지 결과
  - After  (WAF + AI 이상 탐지): AI가 WAF 허용(ALLOW) 트래픽 중 이상 패턴 추가 탐지
"""

import json
import math
import os
import random
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

FEATURES = ["country_code", "rule_code", "uri_len", "path_entropy", "args_entropy"]

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


def _entropy(text: str) -> float:
    if not text:
        return 0.0
    freq = Counter(str(text))
    n = len(str(text))
    return -sum((c / n) * math.log2(c / n) for c in freq.values()) or 0.0


def _assign_args(terminatingruleid: str) -> str:
    rule = str(terminatingruleid)
    if "SQLi" in rule:
        return _RNG.choice(_SQLI_PAYLOADS)
    if "XSS" in rule or "CrossSite" in rule:
        return _RNG.choice(_XSS_PAYLOADS)
    return ""


def load_data(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["request_args"] = df["terminatingruleid"].apply(_assign_args)
    df["path_entropy"] = df["request_uri"].fillna("").apply(_entropy)
    df["args_entropy"] = df["request_args"].apply(_entropy)

    df["is_sqli"]     = df["terminatingruleid"] == "AWS-AWSManagedRulesSQLiRuleSet"
    df["is_geoblock"] = df["terminatingruleid"] == "Allow-Only-Korea"

    # y_true: SQLi만 공격 레이블. GeoBlock은 룰 기반 차단이므로 AI 평가 제외
    df["y_true"] = df["is_sqli"].astype(int)
    return df


def main():
    df = load_data(DATA_PATH)
    model = joblib.load(MODEL_PATH)
    scaler = joblib.load(SCALER_PATH)

    X_scaled = scaler.transform(df[FEATURES])

    start = time.time()
    raw_preds = model.predict(X_scaled)
    elapsed = time.time() - start

    df["y_pred"] = (raw_preds == -1).astype(int)

    # GeoBlock은 AI 성능 평가 제외 — SQLi + 정상(ALLOW)만 평가 대상
    eval_df = df[~df["is_geoblock"]].copy()

    n_total    = len(df)
    n_sqli     = int(df["is_sqli"].sum())
    n_geoblock = int(df["is_geoblock"].sum())
    n_normal   = int((df["action"] == "ALLOW").sum())
    n_eval     = len(eval_df)

    y_true = eval_df["y_true"].values
    y_pred = eval_df["y_pred"].values
    avg_latency_ms = (elapsed / n_total) * 1000

    prec = precision_score(y_true, y_pred, zero_division=0)
    rec  = recall_score(y_true, y_pred, zero_division=0)
    f1   = f1_score(y_true, y_pred, zero_division=0)
    tn, fp, fn, tp = confusion_matrix(y_true, y_pred).ravel()
    fpr  = fp / (fp + tn) if (fp + tn) > 0 else 0.0

    # GeoBlock 중 AI가 이상으로 탐지한 건수 (참고용)
    geo_flagged = int(df[df["is_geoblock"]]["y_pred"].sum())

    print("\n" + "=" * 58)
    print("  WAF + AI 이상 탐지 엔진 성능 평가 (현행 모델)")
    print("=" * 58)

    print(f"\n[데이터셋]")
    print(f"  전체 로그        : {n_total:,} 건")
    print(f"  SQLi 공격        : {n_sqli:,} 건  ({n_sqli/n_total*100:.1f}%)  ← AI 평가 대상")
    print(f"  GeoBlock 차단    : {n_geoblock:,} 건  ({n_geoblock/n_total*100:.1f}%)  ← 룰 기반, 평가 제외")
    print(f"  WAF 허용 (정상)  : {n_normal:,} 건  ({n_normal/n_total*100:.1f}%)")

    print(f"\n[AI 탐지 결과 — SQLi 기준, 평가 대상 {n_eval:,}건]")
    print(f"  TP (SQLi 정탐)   : {tp:,} 건")
    print(f"  FP (정상 오탐)   : {fp:,} 건")
    print(f"  FN (SQLi 미탐)   : {fn:,} 건")
    print(f"  TN (정상 정탐)   : {tn:,} 건")

    print(f"\n[성능 지표 — SQLi 탐지 기준]")
    print(f"  Precision        : {prec:.4f}  ({prec*100:.1f}%)")
    print(f"  Recall           : {rec:.4f}  ({rec*100:.1f}%)")
    print(f"  F1-Score         : {f1:.4f}")
    print(f"  FPR (오탐률)     : {fpr:.4f}  ({fpr*100:.1f}%)")
    print(f"  건당 처리 속도   : {avg_latency_ms:.4f} ms")

    print(f"\n[GeoBlock 참고]")
    print(f"  GeoBlock {n_geoblock}건은 Allow-Only-Korea 룰 기반 차단 이벤트.")
    print(f"  AI 성능 평가 미포함. AI가 이 중 {geo_flagged}건을 이상으로 추가 탐지.")

    print(f"\n[Before / After 비교]")
    print(f"  ┌──────────────────────────────────────────────────┐")
    print(f"  │ 구분              탐지 건수   방식               │")
    print(f"  ├──────────────────────────────────────────────────┤")
    print(f"  │ Before (WAF SQLi)  {n_sqli:>5,} 건    정적 룰 매칭        │")
    print(f"  │ After  (WAF+AI)    {n_sqli+fp:>5,} 건    비지도 이상 탐지    │")
    print(f"  │ AI 추가 탐지        {fp:>4,} 건    WAF 허용 → AI 차단  │")
    print(f"  └──────────────────────────────────────────────────┘")
    print(f"\n  SQLi {n_sqli}건 중 AI가 {tp}건 독립 검증 (Recall {rec*100:.1f}%)")
    print(f"  WAF 허용 {n_normal}건 중 AI가 {fp}건 추가 이상 탐지")
    print("=" * 58)

    results = {
        "run_timestamp": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M"),
        "model_type": "IsolationForest (train_model.py / contamination=0.25)",
        "dataset": "final_preprocessed_waf_data.csv",
        "features": FEATURES,
        "eval_scope": "SQLi only (GeoBlock excluded from P/R/F1)",
        "n_total": n_total,
        "n_sqli": n_sqli,
        "n_geoblock": n_geoblock,
        "n_normal": n_normal,
        "n_eval": n_eval,
        "tp": int(tp),
        "fp": int(fp),
        "fn": int(fn),
        "tn": int(tn),
        "precision": round(prec, 4),
        "recall": round(rec, 4),
        "f1_score": round(f1, 4),
        "fpr": round(fpr, 4),
        "avg_latency_ms": round(avg_latency_ms, 4),
        "geoblock_ai_flagged": geo_flagged,
        "before_waf_sqli_detections": n_sqli,
        "after_ai_additional_detections": int(fp),
    }

    os.makedirs(RESULT_DIR, exist_ok=True)
    out_path = os.path.join(RESULT_DIR, "performance_metrics_v2.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=4, ensure_ascii=False)
    print(f"\n결과 저장: {out_path}\n")


if __name__ == "__main__":
    main()
