import pandas as pd
import joblib
from sklearn.ensemble import IsolationForest

# 1. 데이터 로드
data_path = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
df = pd.read_csv(data_path)

# 2. 피처 엔지니어링 (공격 패턴 추출)
# 1) URI 길이
df['uri_length'] = df['request_uri'].apply(lambda x: len(str(x)))
# 2) 특수문자 개수 (공격 구문은 특수문자가 많음)
df['special_chars'] = df['request_uri'].apply(lambda x: sum(1 for c in str(x) if not c.isalnum()))
# 3) 위험 키워드 포함 여부 (1: 포함, 0: 미포함)
risk_keywords = ['etc', 'passwd', 'admin', 'select', 'union', 'drop', 'scripts']
df['risk_keyword'] = df['request_uri'].apply(lambda x: 1 if any(k in str(x).lower() for k in risk_keywords) else 0)

# 학습에 사용할 다차원 피처 (길이뿐만 아니라 패턴까지!)
X_train = df[['uri_length', 'special_chars', 'risk_keyword']]

# 3. 모델 생성 (contamination을 0.15 정도로 설정)
model = IsolationForest(contamination=0.15, random_state=42)
model.fit(X_train)

# 4. 모델 저장
model_path = '/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl'
joblib.dump(model, model_path)
print(f"✨ 다차원 보안 피처 모델 학습 완료! 저장 경로: {model_path}")