"""
합성 정상 트래픽 생성 스크립트.

기존 공격 데이터(450건)에 혼합할 정상 트래픽을 생성한다.
인코딩 체계:
  country_code: KR=0, NL=1, US=2, unknown=99
  rule_code:    SQLi=0, Allow-Only-Korea(BLOCK)=1, Default_Action(ALLOW)=2, unknown=999
"""

import csv
import math
import random
from collections import Counter

# ─── 설정 ─────────────────────────────────────────────────────────
OUTPUT_PATH = "ai/data/normal_traffic.csv"
N_SAMPLES = 1350  # 공격 450건 기준 3:1 → contamination ≈ 0.25

# ─── 정상 URI 풀 (낮은 엔트로피, 예측 가능한 구조) ──────────────────
NORMAL_URIS = [
    "/",
    "/index.html",
    "/login",
    "/logout",
    "/dashboard",
    "/profile",
    "/about",
    "/contact",
    "/cart",
    "/checkout",
    "/favicon.ico",
    "/robots.txt",
    "/sitemap.xml",
    "/api/users",
    "/api/users/profile",
    "/api/products",
    "/api/products/list",
    "/api/orders",
    "/api/health",
    "/api/v1/users",
    "/api/v1/products",
    "/search?q=shoes",
    "/search?q=clothes",
    "/search?q=phone",
    "/products/1",
    "/products/2",
    "/products/3",
    "/static/css/main.css",
    "/static/js/app.js",
    "/static/images/logo.png",
]

# KR IP 대역 (KT / SK / LG U+)
KR_IP_PREFIXES = [
    (1, 208),   # KT
    (1, 209),
    (27, 96),   # SK Broadband
    (27, 100),
    (14, 32),   # SK
    (14, 40),
    (58, 120),  # LG U+
    (58, 122),
    (125, 128), # KT
    (125, 130),
]


def _random_kr_ip() -> str:
    a, b = random.choice(KR_IP_PREFIXES)
    return f"{a}.{b}.{random.randint(0, 255)}.{random.randint(1, 254)}"


def _random_event_time() -> str:
    mm = random.randint(0, 59)
    ss = random.randint(0, 59)
    ms = random.randint(0, 9)
    return f"{mm:02d}:{ss:02d}.{ms}"


def _entropy(text: str) -> float:
    if not text:
        return 0.0
    freq = Counter(text)
    n = len(text)
    return -sum((c / n) * math.log2(c / n) for c in freq.values())


def generate(n: int = N_SAMPLES, output: str = OUTPUT_PATH) -> None:
    rows = []
    for _ in range(n):
        uri = random.choice(NORMAL_URIS)
        rows.append({
            "event_time":       _random_event_time(),
            "source_ip":        _random_kr_ip(),
            "source_country":   "KR",
            "request_uri":      uri,
            "terminatingruleid":"Default_Action",
            "action":           "ALLOW",
            "country_code":     0,      # KR
            "rule_code":        2,      # Default_Action (ALLOW)
            "uri_len":          len(uri),
        })

    fieldnames = [
        "event_time", "source_ip", "source_country", "request_uri",
        "terminatingruleid", "action", "country_code", "rule_code", "uri_len",
    ]

    with open(output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    # 간단한 엔트로피 분포 확인
    entropies = [_entropy(r["request_uri"]) for r in rows]
    avg_e = sum(entropies) / len(entropies)
    print(f"생성 완료: {n}건 → {output}")
    print(f"  URI 엔트로피 평균: {avg_e:.3f}  (정상 기대값: 3.0~3.5)")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=N_SAMPLES, help="생성 건수 (기본 1350)")
    parser.add_argument("--output", type=str, default=OUTPUT_PATH)
    args = parser.parse_args()

    generate(args.n, args.output)
