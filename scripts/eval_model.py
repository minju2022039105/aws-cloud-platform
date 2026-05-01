import pandas as pd
import joblib
from sklearn.metrics import classification_report, confusion_matrix

# 1. 저장된 모델과 데이터 불러오기
model = joblib.load('isolation_forest_model.pkl')
df = pd.read_csv('/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv')

# 2. 데이터 전처리 (학습 때와 동일하게)
df['uri_length'] = df['request_uri'].apply(lambda x: len(str(x)))
X = df[['uri_length']]

# 3. 모델 예측 (-1은 이상치, 1은 정상)
preds = model.predict(X)

# 4. 성능 평가를 위한 임시 라벨 생성 
# (실제 프로젝트에서는 Nikto 로그임을 감안하여 특정 패턴을 '공격'으로 간주하고 비교합니다)
# 여기서는 간단히 모델이 탐지한 비율을 출력합니다.
n_outliers = (preds == -1).sum()
print(f"전체 데이터 개수: {len(df)}")
print(f"탐지된 이상 징후(공격) 개수: {n_outliers}")
print(f"탐지율: {(n_outliers/len(df))*100:.2f}%")

# 5. 상세 리포트 출력
# 실제 라벨(y_true)이 있다면 아래 코드로 정확한 점수가 나옵니다.
print("\n[ 상세 분석 리포트 ]")
print("비정상적인 URI 길이 및 패턴을 기반으로 탐지된 결과입니다.")