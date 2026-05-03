import requests
import time
import random

# 1. 설정
TARGET_URL = "http://minju-alb-783307637.us-east-1.elb.amazonaws.com"
NORMAL_PATHS = ["/", "/index.php", "/login", "/about", "/contact"]
ATTACK_PATTERNS = [
    "/?id=1' OR 1=1--",                # SQLi 변형
    "/?q=<script>alert('xss')</script>", # XSS 패턴
    "/etc/passwd",                     # Path Traversal
    "/%2e%2e%2f%2e%2e%2fetc/passwd",   # 인코딩된 Path Traversal
    "/admin/config.php",               # 관리자 페이지 접근 시도
    "/?data=" + "A"*50 + "!"*10        # 고엔트로피(복잡도) 데이터
]

def send_request(path, desc):
    url = f"{TARGET_URL}{path}"
    try:
        # User-Agent를 다양하게 섞어서 정상 트래픽처럼 보이게 함
        headers = {'User-Agent': random.choice(['Mozilla/5.0', 'iPhone', 'Googlebot'])}
        response = requests.get(url, headers=headers, timeout=5)
        print(f"[{desc}] Status: {response.status_code} | Path: {path}")
    except Exception as e:
        print(f"Error: {e}")

# 2. 실행 루프
print("🚀 로그 생성을 시작합니다... (Ctrl+C로 중지)")
try:
    while True:
        # 80% 확률로 정상 로그 생성
        if random.random() < 0.8:
            send_request(random.choice(NORMAL_PATHS), "NORMAL")
        # 20% 확률로 공격 로그 생성
        else:
            send_request(random.choice(ATTACK_PATTERNS), "ATTACK")
        
        # 1~3초 사이의 랜덤한 간격 (Low-and-Slow 공격 시뮬레이션)
        time.sleep(random.uniform(1, 3))
except KeyboardInterrupt:
    print("\n✅ 로그 생성 중지.")