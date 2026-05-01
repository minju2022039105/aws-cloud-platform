import pandas as pd
import joblib
import re
import os

# 민주님 환경에 맞춘 절대 경로 (가장 확실한 방법)
MODEL_PATH = '/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl'
DATA_PATH = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
RESULT_DIR = '/home/march/aws-devsecops-platform/ai-security/results'

# 데이터 로드
df = pd.read_csv(DATA_PATH)
model = joblib.load(MODEL_PATH)
target_col = 'request_uri'

def extract_features(uri):
    uri = str(uri)
    return [len(uri), len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)), sum(1 for word in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../'] if word in uri.lower())]

# 분석 실행
features_list = df[target_col].apply(extract_features).tolist()
X = pd.DataFrame(features_list, columns=model.feature_names_in_)
df['prediction'] = model.predict(X)

anomalies = df[df['prediction'] == -1].copy()

def classify_threat(uri):
    uri_l = str(uri).lower()
    if 'script' in uri_l or '%3c' in uri_l: return 'XSS Attempt'
    if 'admin' in uri_l or 'login' in uri_l: return 'Admin Access Try'
    if '../' in uri_l or 'etc' in uri_l: return 'Path Traversal'
    return 'Suspicious Pattern'

anomalies['type'] = anomalies[target_col].apply(classify_threat)

# 리포트 생성 (f-string 적용으로 오타 수정)
report = "="*65 + "\n"
report += f"🔍 보안 위협 상세 분석 (총 {len(anomalies)}건)\n"
report += "="*65 + "\n"
report += anomalies[[target_col, 'type']].to_string(index=False) + "\n"
report += "="*65

print(report)

# 파일 저장
os.makedirs(RESULT_DIR, exist_ok=True)
with open(os.path.join(RESULT_DIR, 'analysis_report.txt'), 'w', encoding='utf-8') as f:
    f.write(report)
