import os
import json
import boto3
import time
import datetime

athena = boto3.client("athena")
lambda_client = boto3.client("lambda")

# 환경 변수 로드
ATHENA_DB = os.getenv("ATHENA_DB", "monitoring_db")
ATHENA_TABLE = os.getenv("ATHENA_TABLE", "aiops_results")
ATHENA_OUTPUT = os.getenv("ATHENA_OUTPUT")
PREVENTER_FN = os.getenv("PREVENTER_FN")

def run_query(query):
    print(f"Executing query: {query}")
    response = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={"Database": ATHENA_DB},
        ResultConfiguration={"OutputLocation": ATHENA_OUTPUT}
    )
    qid = response["QueryExecutionId"]

    while True:
        status = athena.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]
        if state in ["SUCCEEDED", "FAILED", "CANCELLED"]:
            if state != "SUCCEEDED":
                # 실패 시 이유를 로그에 남깁니다.
                reason = status["QueryExecution"]["Status"].get("StateChangeReason", "Unknown")
                print(f"❌ Athena Query Failed: {reason}")
                raise RuntimeError(f"Athena query failed: {state} - {reason}")
            break
        time.sleep(1)
    
    return athena.get_query_results(QueryExecutionId=qid)

def handler(event, context):
    # 1. 현재 날짜 기준 파티션 추출 (성능 및 안정성 최적화)
    now = datetime.datetime.now()
    year = now.strftime("%Y")
    month = now.strftime("%m")
    day = now.strftime("%d")

    # 2. 쿼리 수정: 민주님 테이블 컬럼(anomaly, ip)에 맞게 변경
    # anomaly가 1인 공격 사례가 있는지 최근 파티션에서 조회합니다.
    query = f"""
    SELECT ip, COUNT(*) AS cnt
    FROM {ATHENA_DB}.{ATHENA_TABLE}
    WHERE anomaly = 1 
      AND year = '{year}' 
      AND month = '{month}' 
      AND day = '{day}'
    GROUP BY ip
    ORDER BY cnt DESC
    LIMIT 1
    """

    try:
        results = run_query(query)
        rows = results["ResultSet"]["Rows"]
        
        # 데이터가 없으면 종료
        if len(rows) < 2:
            print("No anomaly detected in the recent logs.")
            return {"status": "no_data"}

        # 가장 많이 발견된 공격 IP 추출
        target_ip = rows[1]["Data"][0]["VarCharValue"]
        attack_count = rows[1]["Data"][1]["VarCharValue"]
        
        print(f"⚠️ Anomaly Detected! Target IP: {target_ip}, Count: {attack_count}")

        # 3. Preventer 람다 호출
        payload = {
            "ip": target_ip,
            "count": attack_count,
            "message": "AI-based Anomaly Detected"
        }

        lambda_client.invoke(
            FunctionName=PREVENTER_FN,
            InvocationType="Event",
            Payload=json.dumps(payload).encode("utf-8")
        )

        return {"status": "analyzed", "attack_ip": target_ip}

    except Exception as e:
        print(f"Error during analysis: {str(e)}")
        return {"status": "error", "message": str(e)}