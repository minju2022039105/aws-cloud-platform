import math
import time
import json
import os
import joblib
import numpy as np
import pandas as pd
from collections import Counter as CharCounter
from datetime import datetime
from prometheus_client import start_http_server, Counter, Gauge, Histogram
import boto3

_BASE = os.path.dirname(os.path.abspath(__file__))
os.chdir(_BASE)

# S3 설정 (함수 바깥에 선언)
S3_BUCKET_NAME = "aws-waf-logs-minju-0417-project"
s3_client = boto3.client('s3', region_name='us-east-1')

def upload_to_s3(data_dict):
    try:
        now = datetime.now()
        # Athena 파티셔닝 구조에 맞게 경로 설정 
        file_path = f"results/year={now.year}/month={now.strftime('%m')}/day={now.strftime('%d')}/aiops_{now.strftime('%H%M%S_%f')}.json"
        
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=file_path,
            Body=json.dumps(data_dict),
            ContentType='application/json'
        )
        print(f"🚀 S3 Upload Success: {file_path}")
    except Exception as e:
        print(f"❌ S3 Upload Fail: {e}")

# ==============================
# Lambda 설정
# ==============================
lambda_client = boto3.client('lambda', region_name='us-east-1')

def invoke_preventer(ip, risk, level):
    """실제 차단을 수행하는 Lambda 함수 호출"""
    if level < 1: # 차단 레벨이 0이면 호출 안 함
        return
        
    try:
        payload = {
            "ip": ip,
            "reason": f"AI Risk: {risk}%",
            "mitigation_level": level
        }
        lambda_client.invoke(
            FunctionName="SecurityPreventer", # 람다 이름이 다르면 수정하세요!
            InvocationType='Event', # 비동기 호출 (분석 흐름 방해 금지)
            Payload=json.dumps(payload)
        )
        print(f"🛡️ [SOAR] Preventer Lambda Invoked for IP: {ip} (Level: {level})")
    except Exception as e:
        print(f"❌ [SOAR] Lambda Invoke Fail: {e}")
# ==============================
# 0) 설정
# ==============================
CSV_PATH = os.path.join(_BASE, "../../ai/data/final_preprocessed_waf_data.csv")
MODEL_PATH = os.path.join(_BASE, "../../ai/models/isolation_forest_model.pkl")
SCALER_PATH = os.path.join(_BASE, "../../ai/models/scaler.pkl")
FEATURES = ["country_code", "rule_code", "uri_len", "uri_entropy"]


def _rule_entropy(rule_code) -> float:
    b = bin(int(rule_code))
    freq = CharCounter(b)
    n = len(b)
    return -sum((cnt / n) * math.log2(cnt / n) for cnt in freq.values())

# 촬영용 타임라인(총 210초 ≈ 3분30초)
SCENARIO = [
    ("NORMAL", 50),
    ("PREDICT", 40),
    ("PREMITIGATE", 40),
    ("ATTACK_ATTEMPT", 40),
    ("STABILIZE", 40),
]
PRED_THRESHOLD = 70          # 예측 위험도 임계치
LEAD_SECONDS = 60            # "1분 선행" 연출

# 공격 패턴(시뮬레이션): 특정 rule/country/uri_len 폭증
ATTACK_RULES = [9001, 9002, 9100, 9200]
ATTACK_COUNTRIES = [643, 156, 364, 410]   # 예시: RU/CN/IR/KR 같은 코드라고 '가정' (실제 의미는 발표에서 일반화 표현 권장)

TICK_SEC = 0.5

# ==============================
# 1) Prometheus Exporter
# ==============================
start_http_server(8000)

# 예측/관측
PRED_RISK = Gauge("aiops_predicted_risk", "Predicted risk score (0-100)")
OBS_RISK = Gauge("aiops_observed_risk", "Observed risk score (0-100)")
PRED_LEAD = Gauge("aiops_prediction_lead_seconds", "Prediction lead time (seconds)")

# 사전방어
PREMIT_STATUS = Gauge("aiops_premitigation_status", "Pre-mitigation enabled (0/1)")
MIT_LEVEL = Gauge("aiops_mitigation_level", "Mitigation level (0-3)")

# 결과 지표
ANOMALY_STATUS = Gauge("aiops_anomaly_status", "Observed anomaly status (0/1)")
ATTACK_ATTEMPT = Counter("aiops_attack_attempt_total", "Attack attempts total")
PREMIT_TRIGGER = Counter("aiops_premitigation_trigger_total", "Pre-mitigation triggers total")
BLOCKED = Counter("aiops_block_total", "Blocked requests total")
PASSED = Counter("aiops_pass_total", "Passed requests total")

# AI 재학습 결과 시각화용 메트릭
# RAW_SCORE: Isolation Forest decision_function 원점수 (양수=정상, 음수=이상)
RAW_SCORE = Gauge("aiops_raw_score", "Isolation Forest decision score (positive=normal, negative=anomaly)")
# ANOMALY_THRESHOLD: 탐지 경계값 (전체 점수의 5th percentile). Grafana 참조선으로 사용
ANOMALY_THRESHOLD = Gauge("aiops_anomaly_threshold", "Decision boundary score (5th percentile of training scores)")
# SCORE_HIST: 점수 분포 — 버킷은 실측 IQR(0.07) 기준으로 0.05 간격 설계
SCORE_HIST = Histogram(
    "aiops_score_distribution",
    "Isolation Forest score distribution",
    buckets=[-0.30, -0.20, -0.15, -0.10, -0.05, 0.00, 0.05, 0.10, 0.15, 0.20, 0.30],
)

# ==============================
# 2) 데이터 로드 + 재학습 모델 로드
# ==============================
df = pd.read_csv(CSV_PATH)
df["uri_entropy"] = df["rule_code"].apply(_rule_entropy)

missing = [c for c in FEATURES if c not in df.columns]
if missing:
    raise ValueError(f"CSV에 필요한 컬럼이 없습니다: {missing}. 필요한 컬럼: {FEATURES}")

X = df[FEATURES].copy()

model = joblib.load(MODEL_PATH)
scaler = joblib.load(SCALER_PATH)
X_scaled = scaler.transform(X)

scores_all = model.decision_function(X_scaled)
THRESHOLD = np.percentile(scores_all, 5)
MIN_S = float(scores_all.min())
MAX_S = float(scores_all.max())

# 모델 로드 시점에 경계값을 Prometheus에 고정값으로 등록
# Grafana에서 이 값을 참조선(threshold line)으로 그려서 정상/이상 구간을 구분함
ANOMALY_THRESHOLD.set(float(THRESHOLD))

def risk_from_score(score: float) -> float:
    """decision_function 점수 -> 0~100 위험도"""
    score = float(score)
    if score >= THRESHOLD:
        # 정상 구간 (0~70)
        denom = (MAX_S - THRESHOLD) if (MAX_S - THRESHOLD) != 0 else 1.0
        norm = (score - THRESHOLD) / denom
        return round((1 - norm) * 70, 2)
    else:
        # 이상 구간 (70~100)
        denom = (THRESHOLD - MIN_S) if (THRESHOLD - MIN_S) != 0 else 1.0
        norm = (score - MIN_S) / denom
        return round(100 - (norm * 30), 2)

# ==============================
# 3) 타임라인 유틸
# ==============================
scenario_start = time.time()
premit_on = False
premit_triggered_once = False

def current_mode(t_sec: float) -> str:
    acc = 0
    for m, dur in SCENARIO:
        acc += dur
        if t_sec < acc:
            return m
    return SCENARIO[-1][0]

def mitigation_level_for(t_sec: float) -> int:
    # PREMITIGATE(90~130) 구간 40초를 1→2→3으로 상승
    # t_sec 기준: NORMAL 0~50, PREDICT 50~90, PREMITIGATE 90~130
    if t_sec < 90:
        return 0
    if t_sec < 90 + (40 * 0.33):
        return 1
    if t_sec < 90 + (40 * 0.66):
        return 2
    return 3

# ==============================
# 4) 메인 루프 (실제 점수 + 시나리오 연출)
# ==============================
print(f"✅ Hybrid demo started | dynamic_threshold={THRESHOLD:.4f}")

while True:
    t = time.time() - scenario_start
    mode = current_mode(t)

    # 기본 샘플: 실제 CSV에서 1건
    sample = df.sample(1).copy()

    # ---------- 시나리오 기반 '공격 재현' ----------
    # PREDICT: 아직 공격은 아니지만 징후(피처 약간 튐)
    # PREMITIGATE: 사전방어 on, 공격 패턴 더 강하게
    # ATTACK_ATTEMPT: 공격 패턴 매우 강하게(실제 공격 시도 재현)
    if mode == "PREDICT":
        sample.loc[:, "uri_len"] = sample["uri_len"].astype(int) + np.random.randint(200, 600)
        sample.loc[:, "uri_entropy"] = np.random.uniform(3.5, 4.2)

    elif mode == "PREMITIGATE":
        sample.loc[:, "uri_len"] = sample["uri_len"].astype(int) + np.random.randint(800, 1800)
        sample.loc[:, "rule_code"] = np.random.choice(ATTACK_RULES)
        sample.loc[:, "country_code"] = np.random.choice(ATTACK_COUNTRIES)
        sample.loc[:, "uri_entropy"] = np.random.uniform(4.2, 5.0)

    elif mode == "ATTACK_ATTEMPT":
        sample.loc[:, "uri_len"] = sample["uri_len"].astype(int) + np.random.randint(1500, 4000)
        sample.loc[:, "rule_code"] = np.random.choice(ATTACK_RULES)
        sample.loc[:, "country_code"] = np.random.choice(ATTACK_COUNTRIES)
        sample.loc[:, "uri_entropy"] = np.random.uniform(4.5, 5.5)
        ATTACK_ATTEMPT.inc(np.random.randint(3, 8))

    # ---------- 실측(Observed) 점수 계산 ----------
    X_in = scaler.transform(sample[FEATURES])
    raw_score = float(model.decision_function(X_in)[0])
    obs_risk = risk_from_score(raw_score)

    # ---------- 예측(Predicted) 위험도 연출 ----------
    # 예측은 "실측보다 먼저/더 크게" 보이게: mode에 따라 가중치
    if mode == "NORMAL":
        pred_risk = max(0, min(100, obs_risk + np.random.randint(0, 10)))
    elif mode == "PREDICT":
        pred_risk = max(0, min(100, obs_risk + np.random.randint(25, 45)))
    elif mode in ("PREMITIGATE", "ATTACK_ATTEMPT"):
        pred_risk = max(0, min(100, obs_risk + np.random.randint(30, 55)))
    else:  # STABILIZE
        # 안정화: 예측도 같이 내려가게
        pred_risk = max(0, min(100, obs_risk + np.random.randint(5, 15)))

    # ---------- 사전방어 로직 ----------
    # 예측 임계치 넘으면 premit ON (한 번 트리거 카운트)
    if pred_risk >= PRED_THRESHOLD:
        if not premit_on:
            premit_on = True
            if not premit_triggered_once:
                PREMIT_TRIGGER.inc()
                premit_triggered_once = True
    # STABILIZE 후반에는 해제
    if mode == "STABILIZE" and t > 170 + 20:
        premit_on = False

    level = mitigation_level_for(t) if premit_on else 0

    # ---------- "선제 방어로 피해 억제" 연출 ----------
    # ATTACK_ATTEMPT에서는 공격이 와도 obs가 100까지 안 가도록 소폭 캡(현실감+스토리)
    if mode == "ATTACK_ATTEMPT" and premit_on and level == 3:
        obs_risk = min(obs_risk, 75.0)

    anomaly = 1 if mode == "ATTACK_ATTEMPT" else 0

    # ---------- 트래픽/차단 카운터(임팩트용) ----------
    if mode == "NORMAL":
        PASSED.inc(np.random.randint(60, 110))
        BLOCKED.inc(np.random.randint(0, 3))
    elif mode == "PREDICT":
        PASSED.inc(np.random.randint(50, 90))
        BLOCKED.inc(np.random.randint(5, 15))
    elif mode == "PREMITIGATE":
        # 사전방어로 차단 증가 + 통과 감소
        BLOCKED.inc(np.random.randint(30, 60) * max(1, level))
        PASSED.inc(np.random.randint(25, 55))
    elif mode == "ATTACK_ATTEMPT":
        # 공격 시도: 차단 폭증, 통과 억제
        BLOCKED.inc(np.random.randint(120, 220))
        PASSED.inc(np.random.randint(10, 25))
    else:  # STABILIZE
        PASSED.inc(np.random.randint(60, 110))
        BLOCKED.inc(np.random.randint(0, 8))

    # ---------- 메트릭 반영 ----------
    PRED_RISK.set(float(pred_risk))
    OBS_RISK.set(float(obs_risk))
    PRED_LEAD.set(float(LEAD_SECONDS))

    PREMIT_STATUS.set(1 if premit_on else 0)
    MIT_LEVEL.set(float(level))
    ANOMALY_STATUS.set(float(anomaly))

    # AI 재학습 결과 시각화: raw_score를 Gauge와 Histogram 양쪽에 기록
    # Gauge → 현재 점수 실시간 추이 (Time series 패널)
    # Histogram → 점수 분포 누적 (Heatmap/Bar 패널, ANOMALY_THRESHOLD 기준으로 정상/이상 경계 확인)
    RAW_SCORE.set(float(raw_score))
    SCORE_HIST.observe(float(raw_score))

    # ===S3에 올릴 데이터들 만들기!!!! ===
    # CSV 샘플에서 IP 가져오기 (컬럼명이 'source_ip'라고 가정, 없으면 'unknown' 처리)
    latest_ip = sample['source_ip'].values[0] if 'source_ip' in sample.columns else "33.100.231.47"

    log_entry = {
        "event_time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "mode": mode,
        "ip": latest_ip,
        "pred_risk": float(pred_risk),
        "obs_risk": float(obs_risk),
        "premit_on": 1 if premit_on else 0,
        "mitigation_level": int(level),
        "anomaly": int(anomaly),
        "raw_score": float(raw_score)
    }
    
    # S3 업로드 함수 호출
    upload_to_s3(log_entry)

    # ⭐️ [핵심 추가] 실제 차단 명령 하달
    invoke_preventer(latest_ip, pred_risk, level)
    # ===============================================

    print(f"[{mode}] pred={pred_risk:.0f}% obs={obs_risk:.0f}% premit={1 if premit_on else 0} level={level} raw={raw_score:.4f}")

    time.sleep(TICK_SEC)

