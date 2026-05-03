import pandas as pd
import joblib
import re
import math
import os
from collections import Counter
from sklearn.ensemble import IsolationForest

# 1. 경로 설정 (민주님 환경 절대 경로)
DATA_PATH = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
MODEL_DIR = '/home/march/aws-devsecops-platform/ai-security/models'
MODEL_PATH = os.path.join(MODEL_DIR, 'isolation_forest_model.pkl')

# 2. 피처 추출 함수 고도화 (엔트로피 로직 동기화)
def calculate_entropy(s):
    if not s or pd.isna(s): return 0
    s = str(s)
    prob = [n_x / len(s) for n_x in Counter(s).values()]
    return -sum(p * math.log2(p) for p in prob)

def extract_features(uri):
    """기존 3개 피처에 엔트로피를 추가하여 4차원 모델로 구성"""
    uri = str(uri)
    return [
        len(uri),                                       # 1) URI 길이
        len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)), # 2) 특수문자 개수
        sum(1 for word in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../'] if word in uri.lower()), # 3) 위험 키워드
        calculate_entropy(uri)                          # 4) Shannon Entropy (신규 추가)
    ]

# 3. 데이터 로드
if not os.path.exists(DATA_PATH):
    print(f"❌ 데이터를 찾을 수 없습니다: {DATA_PATH}")
    exit()

df = pd.read_csv(DATA_PATH)

# 4. 4개 피처 기반 학습 데이터 생성
features_list = df['request_uri'].apply(extract_features).tolist()
X_train = pd.DataFrame(features_list, columns=['uri_length', 'special_chars', 'risk_keyword', 'uri_entropy'])

# 5. 모델 학습 (contamination=0.15 고정)
model = IsolationForest(n_estimators=100, contamination=0.15, random_state=42)
model.fit(X_train)

# 모델 객체에 피처 이름 정보 포함 (Inference 시 정합성 체크용)
model.feature_names_in_ = X_train.columns.tolist()

# 6. 모델 저장
os.makedirs(MODEL_DIR, exist_ok=True)
joblib.dump(model, MODEL_PATH)

print(f"✨ [학습 완료] 4개 피처 기반 모델이 생성되었습니다.")
print(f"📂 경로: {MODEL_PATH}")