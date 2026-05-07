"""
Lambda@Edge (Origin Request) — Isolation Forest 이상 탐지

학습 피처 (train_model.py와 동일한 순서):
    [country_code, rule_code, uri_len, uri_entropy, rule_entropy]

CloudFront 환경에서의 피처 매핑:
    country_code : CloudFront-Viewer-Country 헤더 → 학습 데이터 ordinal 코드
    rule_code    : WAF 제거로 항상 0 (SQLiRuleSet 코드 = 가장 흔한 학습값)
    uri_len      : len(request['uri'])
    uri_entropy  : Shannon entropy of URI
    rule_entropy : entropy of bin(rule_code) → rule_code=0이므로 상수

주의: Lambda@Edge는 환경변수 미지원 → 상수로 선언
"""
import json
import math
import os
from collections import Counter

import boto3

_S3_BUCKET = "devsecops-edge-models-095035153545"
_S3_KEY    = "models/iforest_model.json"
_TMP_PATH  = "/tmp/iforest_model.json"
_THRESHOLD = -0.1   # [-1, 0] 범위. -0.1은 보수적 설정. 운영 후 조정 필요.

_MODEL = None  # 컨테이너 재사용 시 S3 재다운로드 생략


# ── 모델 로드 ────────────────────────────────────────────────────────

def _load_model() -> dict:
    global _MODEL
    if _MODEL is not None:
        return _MODEL
    if os.path.exists(_TMP_PATH):
        with open(_TMP_PATH) as f:
            _MODEL = json.load(f)
        return _MODEL
    boto3.client("s3", region_name="us-east-1").download_file(
        _S3_BUCKET, _S3_KEY, _TMP_PATH
    )
    with open(_TMP_PATH) as f:
        _MODEL = json.load(f)
    return _MODEL


# ── StandardScaler (scikit-learn 없이) ──────────────────────────────

def _scale(model: dict, x: list) -> list:
    """(x - mean) / scale — train_model.py의 StandardScaler와 동일."""
    mean  = model["scaler_mean"]
    scale = model["scaler_scale"]
    return [(x[i] - mean[i]) / scale[i] for i in range(len(x))]


# ── Shannon Entropy ──────────────────────────────────────────────────

def _entropy(text: str) -> float:
    if not text:
        return 0.0
    freq = Counter(text)
    n = len(text)
    return -sum((c / n) * math.log2(c / n) for c in freq.values())


# ── Isolation Forest 순수 Python 추론 ───────────────────────────────

def _c(n: int) -> float:
    if n <= 1: return 0.0
    if n == 2: return 1.0
    return 2.0 * (math.log(n - 1) + 0.5772156649) - (2.0 * (n - 1) / n)


def _path_length(tree: dict, x: list) -> float:
    node, depth = 0, 0
    cl, cr = tree["children_left"], tree["children_right"]
    feat, thr, ns = tree["feature"], tree["threshold"], tree["n_node_samples"]
    while cl[node] != -1:
        node = cl[node] if x[feat[node]] <= thr[node] else cr[node]
        depth += 1
    return depth + _c(ns[node])


def _anomaly_score(model: dict, x_scaled: list) -> float:
    depths = [_path_length(t, x_scaled) for t in model["estimators"]]
    return -(2.0 ** (-sum(depths) / len(depths) / _c(model["max_samples"])))


# ── 피처 추출 ────────────────────────────────────────────────────────

def extract_features(request: dict, model: dict) -> list:
    """
    CloudFront Origin Request → [country_code, rule_code, uri_len, uri_entropy, rule_entropy]
    train_model.py의 FEATURES 순서와 반드시 일치.
    """
    uri = request.get("uri", "/")
    headers = request.get("headers", {})

    # CloudFront-Viewer-Country: "KR", "US", "NL" 등 ISO-2 코드
    cf_country = (headers.get("cloudfront-viewer-country") or [{"value": "XX"}])[0]["value"]
    country_map = model.get("country_map", {})
    # 학습 데이터에 없는 국가는 최대값+1 (미지의 국가 = 이상 신호)
    unknown_code = max(country_map.values(), default=0) + 1
    country_code = float(country_map.get(cf_country, unknown_code))

    rule_code    = 0.0          # WAF 제거 → 규칙 코드 없음. 학습 데이터 최빈값(0) 사용.
    uri_len      = float(len(uri))
    uri_entropy  = _entropy(uri)
    rule_entropy = _entropy(bin(int(rule_code)))

    return [country_code, rule_code, uri_len, uri_entropy, rule_entropy]


# ── 핸들러 ───────────────────────────────────────────────────────────

def lambda_handler(event, context):
    request   = event["Records"][0]["cf"]["request"]
    client_ip = request.get("clientIp", "-")
    uri       = request.get("uri", "/")

    try:
        model    = _load_model()
        features = extract_features(request, model)
        scaled   = _scale(model, features)
        score    = _anomaly_score(model, scaled)

        if score < _THRESHOLD:
            print(json.dumps({
                "action":   "BLOCK",
                "ip":       client_ip,
                "uri":      uri,
                "score":    round(score, 4),
                "features": features,
            }))
            return {
                "status":            "403",
                "statusDescription": "Forbidden",
                "headers": {
                    "content-type": [{"key": "Content-Type", "value": "application/json"}],
                    "x-blocked-by": [{"key": "X-Blocked-By",  "value": "devsecops-edge"}],
                },
                "body": json.dumps({"error": "Blocked by security policy"}),
            }

        print(json.dumps({"action": "ALLOW", "ip": client_ip, "uri": uri, "score": round(score, 4)}))

    except Exception as e:
        # Fail-open: 모델 장애 → 서비스 중단보다 통과 우선. 로그는 반드시 남김.
        print(json.dumps({"action": "FAIL_OPEN", "error": str(e), "ip": client_ip}))

    return request
