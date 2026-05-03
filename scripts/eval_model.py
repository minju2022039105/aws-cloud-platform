import pandas as pd
import joblib
import re
import math
import json
import os
import time
from datetime import datetime
from collections import Counter
from sklearn.metrics import precision_score, recall_score, f1_score

# 1. 경로 설정
MODEL_PATH = '/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl'
DATA_PATH = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
RESULT_DIR = '/home/march/aws-devsecops-platform/ai-security/results'

# 2. 피처 추출 함수 (기존 로직 유지)
def calculate_entropy(s):
    if not s or pd.isna(s): return 0
    s = str(s)
    prob = [n_x / len(s) for n_x in Counter(s).values()]
    return -sum(p * math.log2(p) for p in prob)

def extract_features(uri):
    uri = str(uri)
    return [
        len(uri), 
        len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)),
        sum(1 for word in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../'] if word in uri.lower()),
        calculate_entropy(uri)
    ]

# 3. 데이터 및 모델 로드
model = joblib.load(MODEL_PATH)
df = pd.read_csv(DATA_PATH)

# 4. [중요] Nikto 기반 정답 라벨(Label) 자동 생성
# Nikto가 찔러보는 대표적인 공격 패턴들을 정답(1)으로 간주합니다.
def label_nikto_attack(uri):
    uri_l = str(uri).lower()
    attack_patterns = ['etc/passwd', 'bin/sh', 'script', 'union', 'select', '.pl', 'alert(', 'eval-stdin']
    if any(p in uri_l for p in attack_patterns) or len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri_l)) > 3:
        return 1 # 공격 (Nikto)
    return 0 # 정상

df['true_label'] = df['request_uri'].apply(label_nikto_attack)

# 5. 모델 예측 및 성능 측정
start_time = time.time()
features = df['request_uri'].apply(extract_features).tolist()
X = pd.DataFrame(features, columns=model.feature_names_in_)
preds = model.predict(X)
end_time = time.time()

# 6. 지표 계산 (Isolation Forest: -1은 이상치 -> 1로 변환)
y_pred = [1 if p == -1 else 0 for p in preds]
y_true = df['true_label']

precision = precision_score(y_true, y_pred)
recall = recall_score(y_true, y_pred)
f1 = f1_score(y_true, y_pred)

# 7. 결과 구성
run_timestamp = datetime.now().strftime('%Y-%m-%d %H:%M')
metrics = {
    "run_timestamp": run_timestamp,
    "total_logs": int(len(df)),
    "detected_anomalies": int((preds == -1).sum()),
    "precision": round(precision, 4),
    "recall": round(recall, 4),
    "f1_score": round(f1, 4),
    "avg_latency_per_log_ms": round(((end_time - start_time) / len(df)) * 1000, 4),
    "model_type": "Isolation Forest"
}

# 8. 저장 및 출력
print("\n" + "="*50)
print(f"🎯 Phase 1 최종 성능 평가 ({run_timestamp})")
print("="*50)
print(f"✅ 정밀도(Precision): {metrics['precision']}")
print(f"✅ 재현율(Recall): {metrics['recall']}")
print(f"✅ F1-Score: {metrics['f1_score']}")
print(f"✅ 건당 처리 속도: {metrics['avg_latency_per_log_ms']}ms")
print("="*50)

os.makedirs(RESULT_DIR, exist_ok=True)
with open(os.path.join(RESULT_DIR, 'performance_metrics.json'), 'w') as f:
    json.dump(metrics, f, indent=4)