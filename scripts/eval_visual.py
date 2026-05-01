import pandas as pd
import joblib
import matplotlib.pyplot as plt
import seaborn as sns
import re
import os

# 1. 경로 설정
MODEL_PATH = '/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl'
DATA_PATH = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
SAVE_PATH = '/home/march/aws-devsecops-platform/ai-security/results/detection_result.png'

# 2. 데이터 및 모델 로드
df = pd.read_csv(DATA_PATH)
model = joblib.load(MODEL_PATH)
target_col = 'request_uri'

# 3. 피처 추출 함수
def extract_features(uri):
    uri = str(uri)
    return [
        len(uri), 
        len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)), 
        sum(1 for word in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../'] if word in uri.lower())
    ]

# 4. 피처 데이터프레임 생성 및 모델 입력 이름 맞춤
features_list = df[target_col].apply(extract_features).tolist()
X = pd.DataFrame(features_list, columns=model.feature_names_in_)

# 🌟 핵심: 추출된 피처들을 원본 df에 다시 합쳐줌 (그래프에서 쓰기 위함)
df = pd.concat([df, X], axis=1)

# 5. 예측 수행 및 결과 추가
df['prediction'] = model.predict(X)
anomalies_count = len(df[df['prediction'] == -1])

# 6. 산점도 시각화
plt.figure(figsize=(12, 7))
sns.scatterplot(
    data=df, 
    x='uri_length', 
    y='special_chars', 
    hue='prediction', 
    palette={1: '#3498db', -1: '#e74c3c'}, 
    alpha=0.7,
    s=60
)

plt.title(f'Security AI Detection Result (Anomalies: {anomalies_count})')
plt.xlabel('URI Length')
plt.ylabel('Special Characters Count')
plt.grid(True, linestyle='--', alpha=0.5)

# 이미지 저장
os.makedirs(os.path.dirname(SAVE_PATH), exist_ok=True)
plt.savefig(SAVE_PATH)

print(f"🚨 탐지 건수: {anomalies_count}건")
print(f"✅ 시각화 완료: {SAVE_PATH}")
