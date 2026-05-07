#!/usr/bin/env python3
import json
import sys
import math
import boto3
import joblib
import os

# 1. 설정 (민주 님의 취향과 현재 환경 반영)
S3_BUCKET = "minju-sec-core" 
S3_KEY    = "models/iforest_model.json"
# 모델 파일의 실제 절대 경로
DEFAULT_PKL_PATH = "/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl"

def export(pkl_path: str) -> dict:
    if not os.path.exists(pkl_path):
        print(f"❌ 에러: 모델 파일을 찾을 수 없습니다: {pkl_path}")
        sys.exit(1)

    model = joblib.load(pkl_path)
    
    # ⚠️ 중요: 모델이 기대하는 피처 수 확인
    n_features = model.n_features_in_
    print(f"✅ 모델 분석: 학습된 피처 개수 = {n_features}개")

    # 멘토 피드백 반영: Lambda@Edge용 경량화 로직
    estimators = []
    for est in model.estimators_:
        tree = est.tree_
        estimators.append({
            "children_left":  tree.children_left.tolist(),
            "children_right": tree.children_right.tolist(),
            "feature":         tree.feature.tolist(),
            "threshold":       tree.threshold.tolist(),
            "n_node_samples": tree.n_node_samples.tolist(),
        })

    return {
        "max_samples": int(model.max_samples_),
        "offset":      float(model.offset_),
        "n_features":  n_features,
        "estimators":  estimators,
        # 여기에 scaler 값(mean, scale)을 추가할 수 있습니다.
    }

def verify(model_data: dict, original_pkl_path: str) -> None:
    import numpy as np
    original = joblib.load(original_pkl_path)
    n_features = model_data["n_features"]
    X_test = np.random.rand(10, n_features) # 실제 피처 수에 맞게 테스트 데이터 생성

    orig_scores = original.score_samples(X_test)

    def c(n):
        if n <= 1: return 0.0
        if n == 2: return 1.0
        return 2.0 * (math.log(n - 1) + 0.5772156649) - (2.0 * (n - 1) / n)

    def path_len(tree, x):
        node, depth = 0, 0
        cl, cr = tree["children_left"], tree["children_right"]
        feat, thr = tree["feature"], tree["threshold"]
        ns = tree["n_node_samples"]
        while cl[node] != -1:
            node = cl[node] if x[feat[node]] <= thr[node] else cr[node]
            depth += 1
        return depth + c(ns[node])

    conv_scores = []
    for x in X_test.tolist():
        depths = [path_len(t, x) for t in model_data["estimators"]]
        score = -(2.0 ** (-sum(depths) / len(depths) / c(model_data["max_samples"])))
        conv_scores.append(score)

    max_diff = max(abs(a - b) for a, b in zip(orig_scores, conv_scores))
    print(f"✅ 검증 완료: 최대 오차 {max_diff:.6f}")

if __name__ == "__main__":
    # 인자가 없으면 기본 절대 경로 사용
    pkl_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PKL_PATH

    print(f"🚀 변환 시작: {pkl_path}")
    model_data = export(pkl_path)

    local_path = "iforest_model.json"
    with open(local_path, "w") as f:
        json.dump(model_data, f)

    # S3 업로드 및 버킷 자동 생성 로직
    s3 = boto3.client("s3", region_name="us-east-1")
    try:
        s3.head_bucket(Bucket=S3_BUCKET)
    except:
        print(f"📦 버킷이 없어 새로 만듭니다: {S3_BUCKET}")
        s3.create_bucket(Bucket=S3_BUCKET)

    print(f"☁️ S3 업로드 중: s3://{S3_BUCKET}/{S3_KEY}")
    s3.upload_file(local_path, S3_BUCKET, S3_KEY)
    print("🎉 모든 작업 성공! 이제 테라폼을 실행할 준비가 되었습니다.")