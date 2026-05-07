import urllib.request
import urllib.error
import random
import time
import os
import json

ALB_ENDPOINT = os.environ.get("ALB_ENDPOINT", "http://minju-alb-733893612.us-east-1.elb.amazonaws.com")
REQUEST_COUNT = int(os.environ.get("REQUEST_COUNT", "300"))

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
    "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0",
]

PATHS = [
    "/",
    "/index.html",
    "/about",
    "/contact",
    "/api/health",
    "/login",
    "/dashboard",
    "/products",
    "/search?q=security+tools",
    "/search?q=monitoring",
    "/api/v1/status",
    "/favicon.ico",
    "/robots.txt",
    "/api/logs",
    "/monitor",
    "/assets/main.css",
    "/api/v1/metrics",
    "/docs",
    "/help",
    "/profile",
]

# 시간대별 트래픽 가중치 (한국 시간 기준 낮에 많고 새벽에 적음)
def get_traffic_weight():
    import datetime
    hour = datetime.datetime.utcnow().hour + 9  # KST
    hour = hour % 24
    if 9 <= hour <= 18:   # 업무 시간
        return 1.0
    elif 19 <= hour <= 23: # 저녁
        return 0.6
    else:                  # 새벽
        return 0.2

def handler(event, context):
    weight = get_traffic_weight()
    count = int(REQUEST_COUNT * weight)
    results = {"success": 0, "failed": 0, "total": count}

    for _ in range(count):
        path = random.choice(PATHS)
        ua = random.choice(USER_AGENTS)
        req = urllib.request.Request(
            ALB_ENDPOINT + path,
            headers={
                "User-Agent": ua,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8",
                "Accept-Encoding": "gzip, deflate",
                "Connection": "keep-alive",
            }
        )
        try:
            urllib.request.urlopen(req, timeout=5)
            results["success"] += 1
        except urllib.error.HTTPError:
            results["success"] += 1  # WAF ALLOW 후 앱 레벨 오류는 정상 트래픽으로 간주
        except Exception:
            results["failed"] += 1

        time.sleep(random.uniform(0.05, 0.2))

    print(json.dumps(results))
    return results
