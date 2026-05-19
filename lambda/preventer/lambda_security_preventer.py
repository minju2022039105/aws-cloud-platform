import os
import json
import boto3
from datetime import datetime

# 클라이언트 설정 (버지니아 리전 명시)
waf_client = boto3.client('wafv2', region_name='us-east-1')
cloudwatch = boto3.client('cloudwatch', region_name='us-east-1')

# 설정값 (민주님의 환경에 맞게 수정)
IP_SET_NAME = os.environ.get("IP_SET_NAME", "devsecops-ai-block-list")
IP_SET_ID   = os.environ.get("IP_SET_ID", "d061410e-3732-4d5e-8234-c9cc9e163b43") # 👈 아까 확인한 ID!
CW_NAMESPACE = "AIOps/Security"

def handler(event, context):
    print(f"📥 Received Event: {json.dumps(event)}")
    
    # monitor.py에서 보낸 데이터 추출
    attack_ip = event.get("ip")
    risk_score = event.get("reason", "Unknown")
    
    if not attack_ip or attack_ip == "unknown":
        return {"status": "skipped", "reason": "No valid IP"}

    try:
        # 1. 현재 IP Set의 최신 정보와 LockToken 가져오기
        get_res = waf_client.get_ip_set(
            Name=IP_SET_NAME,
            Id=IP_SET_ID,
            Scope='REGIONAL'
        )
        
        current_addresses = get_res['IPSet'].get('Addresses', [])
        lock_token = get_res['LockToken']
        
        # 2. 새로운 IP 추가 (중복 방지 및 CIDR /32 형식 맞춤)
        target_ip = f"{attack_ip}/32"
        if target_ip not in current_addresses:
            current_addresses.append(target_ip)
            
            # 3. WAF IP Set 업데이트 (진짜 차단 실행)
            waf_client.update_ip_set(
                Name=IP_SET_NAME,
                Id=IP_SET_ID,
                Scope='REGIONAL',
                Addresses=current_addresses,
                LockToken=lock_token
            )
            print(f"🛡️ [SUCCESS] IP {target_ip} blocked in WAF!")
        else:
            print(f"ℹ️ IP {target_ip} is already in block list.")

        # 4. CloudWatch 지표 기록 (기존 기능 유지)
        cloudwatch.put_metric_data(
            Namespace=CW_NAMESPACE,
            MetricData=[{
                "MetricName": "DefenseSignal",
                "Dimensions": [{"Name": "AttackIP", "Value": attack_ip}],
                "Timestamp": datetime.utcnow(),
                "Value": 1.0,
                "Unit": "Count"
            }]
        )

        return {"status": "prevented", "ip": attack_ip}

    except Exception as e:
        print(f"❌ [ERROR] Failed to update WAF: {str(e)}")
        return {"status": "error", "message": str(e)}