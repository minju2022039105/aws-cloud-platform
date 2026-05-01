import pandas as pd
import joblib
from sklearn.metrics import confusion_matrix
import matplotlib.pyplot as plt
import seaborn as sns

# 1. 모델/데이터 로드
model = joblib.load('/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl')
df = pd.read_csv('/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv')
# 2. 피처 생성 (학습 때와 동일하게!)
df['uri_length'] = df['request_uri'].apply(lambda x: len(str(x)))
df['special_chars'] = df['request_uri'].apply(lambda x: sum(1 for c in str(x) if not c.isalnum()))
df['risk_keyword'] = df['request_uri'].apply(lambda x: 1 if any(k in ['etc', 'passwd', 'admin'] for k in str(x).lower()) else 0)

X = df[['uri_length', 'special_chars', 'risk_keyword']]
preds = model.predict(X)
y_pred = (preds == -1).astype(int)

# 3. '실제 공격' 라벨링 기준 강화
# 실제 WAF 로그 분석 시 SQLiRuleSet에 걸린 놈들을 1로 가정하거나, 
# 특수문자가 3개 이상인 놈들을 공격으로 가정해 봅시다.
y_true = df['special_chars'].apply(lambda x: 1 if x >= 3 else 0)

# 4. 시각화
plt.figure(figsize=(8, 6))
cm = confusion_matrix(y_true, y_pred)
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues')
plt.title('Upgraded Security AI Detection')
plt.savefig('/home/march/aws-devsecops-platform/ai-security/results/detection_result.png')
print(f"🚨 탐지 건수: {sum(y_pred)}건")