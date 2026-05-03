import pandas as pd
import joblib
import re
import os
import math
from collections import Counter
from datetime import datetime

# 1. 경로 설정
MODEL_PATH = '/home/march/aws-devsecops-platform/ai-security/models/isolation_forest_model.pkl'
DATA_PATH = '/home/march/aws-devsecops-platform/Security-AIOps-IsolationForest/data/URI별 이상 징후 분석 (Target Analysis).csv'
RESULT_DIR = '/home/march/aws-devsecops-platform/ai-security/results'

# 2. Shannon Entropy 계산 함수
def calculate_entropy(s):
    if not s or pd.isna(s): return 0
    s = str(s)
    prob = [n_x / len(s) for n_x in Counter(s).values()]
    return -sum(p * math.log2(p) for p in prob)

# 3. 피처 추출 함수 (엔트로피 포함 4개 피처)
def extract_features(uri):
    uri = str(uri)
    return [
        len(uri), 
        len(re.findall(r'[<>{}\[\]\(\)\*&%$\!\?]', uri)),
        sum(1 for word in ['script', 'select', 'union', 'drop', 'admin', 'etc/passwd', '../'] if word in uri.lower()),
        calculate_entropy(uri)
    ]

# 데이터 및 모델 로드
df = pd.read_csv(DATA_PATH)
model = joblib.load(MODEL_PATH)
target_col = 'request_uri'

# 분석 실행
X = pd.DataFrame(df[target_col].apply(extract_features).tolist(), columns=model.feature_names_in_)
df['prediction'] = model.predict(X)
anomalies = df[df['prediction'] == -1].copy()

# 4. 위협 분류 로직 (엔트로피 기반 탐지 강조)
def classify_threat(uri):
    uri_l = str(uri).lower()
    # 명시적 키워드 기반 매칭
    if 'script' in uri_l or '%3c' in uri_l: return 'XSS Attempt'
    if 'admin' in uri_l or 'login' in uri_l: return 'Admin Access Try'
    if '../' in uri_l or 'etc' in uri_l: return 'Path Traversal'
    
    # 키워드는 없으나 엔트로피/복잡도 수치가 높아 모델이 잡아낸 경우
    return 'Advanced Obfuscated Attack'

anomalies['type'] = anomalies[target_col].apply(classify_threat)

# 5. 리포트 생성 및 저장 (현재 시간 포함)
run_time = datetime.now().strftime('%Y-%m-%d %H:%M')
report = "="*65 + "\n"
report += f"🔍 AI Security Threat Analysis Report ({run_time})\n"
report += "="*65 + "\n"
report += anomalies[[target_col, 'type']].to_string(index=False) + "\n"
report += "="*65

# 결과 출력 및 파일 저장
print(report)
os.makedirs(RESULT_DIR, exist_ok=True)
with open(os.path.join(RESULT_DIR, 'analysis_report.txt'), 'w', encoding='utf-8') as f:
    f.write(report)
    print(f"\n✅ 분석 리포트 저장 완료: {RESULT_DIR}/analysis_report.txt")