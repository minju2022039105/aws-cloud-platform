import pandas as pd
import joblib
import matplotlib.pyplot as plt
import seaborn as sns
import re
import os
import math
from collections import Counter
from datetime import datetime

# 1. 경로 설정
MODEL_PATH = '/home/march/aws-devsecops-platform/ai/models/isolation_forest_model.pkl'
DATA_PATH = '/home/march/aws-devsecops-platform/ai/data/URI별 이상 징후 분석 (Target Analysis).csv'
SAVE_PATH = '/home/march/aws-devsecops-platform/ai/results/detection_result.png'

# 2. 피처 추출 함수 (엔트로피 포함)
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
df = pd.read_csv(DATA_PATH)
model = joblib.load(MODEL_PATH)

# 4. 피처 생성 및 데이터 통합
X = pd.DataFrame(df['request_uri'].apply(extract_features).tolist(), columns=model.feature_names_in_)
df = pd.concat([df, X], axis=1)

# 5. 예측 수행
df['prediction'] = model.predict(X)
anomalies_count = len(df[df['prediction'] == -1])

# 🌟 실행 시간 설정 (2026-05-01 16:03 형식)
run_time = datetime.now().strftime('%Y-%m-%d %H:%M')

# 6. 산점도 시각화
plt.figure(figsize=(12, 8))
sns.scatterplot(
    data=df, 
    x='uri_length', 
    y='uri_entropy', 
    hue='prediction', 
    palette={1: '#3498db', -1: '#e74c3c'}, 
    alpha=0.7, 
    s=80
)

# 제목에 실시간 정보 반영 (신뢰도 상승 포인트)
plt.title(f'AI Detection Distribution: Entropy vs Length\n[ Anomalies: {anomalies_count} | Generated: {run_time} ]', fontsize=14)
plt.xlabel('URI Length')
plt.ylabel('URI Entropy (Randomness)')
plt.grid(True, linestyle='--', alpha=0.5)

# 7. 이미지 저장
os.makedirs(os.path.dirname(SAVE_PATH), exist_ok=True)
plt.savefig(SAVE_PATH)

print(f"✅ 시각화 완료: {SAVE_PATH} ({run_time})")