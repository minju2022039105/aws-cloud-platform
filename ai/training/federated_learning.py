"""
Weighted FedAvg(Federated Averaging) for Isolation Forest.

개발 배경:
  졸업작품 당시 데이터 수집의 물리적 제약(각 기관의 보안 정책상 원본 로그 공유 불가)으로
  인해 중앙 집중형 학습이 불가능했던 경험을 바탕으로 설계.
  이 구조는 원본 데이터를 공유하지 않고도 여러 보안 노드의 탐지 지식을 통합한다.

핵심 개선 (단순 FedAvg → Weighted FedAvg):
  단순 평균: 모든 노드의 기여도가 동일 → 데이터 5건짜리 노드와 500건짜리가 동등 취급
  가중 평균: 데이터 볼륨이 클수록 더 많이 기여 → 과소 대표 방지

참고 논문: McMahan et al., "Communication-Efficient Learning of Deep Networks
           from Decentralized Data", AISTATS 2017
"""

from __future__ import annotations

import numpy as np
from sklearn.ensemble import IsolationForest
from typing import List


# ─── Step 1: 로컬 노드 — 파라미터 추출 ──────────────────────────
def extract_parameters(model: IsolationForest, node_id: str, n_samples: int) -> dict:
    """
    학습된 로컬 모델에서 원본 데이터 없이 파라미터만 추출.
    n_samples는 Weighted FedAvg의 가중치 계산에만 사용되며,
    원본 데이터 복원에 사용될 수 없음 (Data Sovereignty 보장).

    서버로 전송되는 정보:
      - estimators_:          결정 트리 구조 (분기 규칙)
      - estimators_features_: 각 트리의 피처 인덱스
      - offset_:              이상 판단 임계값
      - n_samples:            학습 샘플 수 (가중치 계산용, 원본 복원 불가)

    서버로 전송되지 않는 정보:
      - 원본 WAF 로그 (IP 주소, URI, 타임스탬프 등)
    """
    return {
        "node_id": node_id,
        "n_samples": n_samples,
        "estimators": model.estimators_,
        "estimators_features": model.estimators_features_,
        "offset": float(model.offset_),
        "n_features_in": model.n_features_in_,
        "max_samples": getattr(model, "_max_samples", model.max_samples_),
        "decision_path_lengths": getattr(model, "_decision_path_lengths", None),
        "avg_path_length_per_tree": getattr(model, "_average_path_length_per_tree", None),
    }


# ─── Step 2: 중앙 서버 — Weighted FedAvg 집계 ───────────────────
def weighted_fedavg(local_params: List[dict]) -> IsolationForest:
    """
    데이터 볼륨 기반 가중 평균 FedAvg.

    단순 FedAvg와의 차이:
      단순: offset_global = mean([offset_A, offset_B, offset_C])
      가중: offset_global = (offset_A * n_A + offset_B * n_B + ...) / (n_A + n_B + ...)

    가중치 적용 대상:
      1. Offset 가중 평균: 데이터가 많은 노드의 이상 판단 기준이 더 큰 영향력
      2. 트리 비례 선택: 데이터 볼륨에 비례하여 각 노드의 트리 선택
         → 5건 데이터 노드의 트리 100개보다 500건 노드의 트리 100개가 더 신뢰할 수 있음

    Args:
        local_params: extract_parameters() 결과 리스트

    Returns:
        가중 통합된 글로벌 IsolationForest 모델
    """
    if not local_params:
        raise ValueError("최소 1개 이상의 로컬 모델 파라미터가 필요합니다.")

    n_features = local_params[0]["n_features_in"]
    _validate_compatibility(local_params, n_features)

    total_samples = sum(p["n_samples"] for p in local_params)
    weights = [p["n_samples"] / total_samples for p in local_params]

    global_model = IsolationForest(n_estimators=0, contamination="auto")

    # ── 트리 비례 선택 — per-tree 속성도 함께 수집 ─────────────────
    # 각 노드의 가중치에 비례하여 트리 선택 (데이터 많은 노드 우대)
    # sklearn 1.8+: _decision_path_lengths, _average_path_length_per_tree 도 per-tree 값이므로
    # 선택된 트리와 1:1로 대응하여 글로벌 모델에 전달해야 함
    all_estimators = []
    all_features = []
    all_dpl = []   # _decision_path_lengths per selected tree
    all_aplt = []  # _average_path_length_per_tree per selected tree

    node_ids = []
    for params, weight in zip(local_params, weights):
        n_trees_to_take = max(1, round(len(params["estimators"]) * weight * len(local_params)))
        indices = np.random.choice(
            len(params["estimators"]),
            size=min(n_trees_to_take, len(params["estimators"])),
            replace=False
        )
        dpl = params.get("decision_path_lengths")
        aplt = params.get("avg_path_length_per_tree")
        for idx in indices:
            all_estimators.append(params["estimators"][idx])
            all_features.append(params["estimators_features"][idx])
            if dpl is not None:
                all_dpl.append(dpl[idx])
            if aplt is not None:
                all_aplt.append(aplt[idx])
        node_ids.append(params["node_id"])

    global_model.estimators_ = all_estimators
    global_model.estimators_features_ = all_features

    # ── Offset 가중 평균 ────────────────────────────────────────
    weighted_offset = sum(
        p["offset"] * w for p, w in zip(local_params, weights)
    )
    global_model.offset_ = float(weighted_offset)
    global_model.n_features_in_ = n_features
    # sklearn sets these in fit(); manually set when assembling without fit()
    global_model._max_features = n_features
    _ms = local_params[0]["max_samples"]
    global_model._max_samples = _ms
    global_model.max_samples_ = _ms
    if all_dpl:
        global_model._decision_path_lengths = all_dpl
    if all_aplt:
        global_model._average_path_length_per_tree = all_aplt
    global_model.n_estimators = len(all_estimators)

    # ── 집계 결과 출력 ──────────────────────────────────────────
    print("\n[Weighted FedAvg 집계 결과]")
    print(f"  {'노드 ID':<20} {'샘플 수':>8} {'가중치':>8} {'트리 기여':>10}")
    print("  " + "─" * 50)
    for params, weight in zip(local_params, weights):
        n_contributed = max(1, round(len(params["estimators"]) * weight * len(local_params)))
        print(f"  {params['node_id']:<20} {params['n_samples']:>8} {weight:>7.1%} "
              f"{min(n_contributed, len(params['estimators'])):>10}개")
    print("  " + "─" * 50)
    print(f"  총 샘플: {total_samples} | 글로벌 트리: {global_model.n_estimators}개 "
          f"| 글로벌 offset: {global_model.offset_:.6f}")

    return global_model


def _validate_compatibility(local_params: List[dict], expected_features: int) -> None:
    """노드 간 피처 스키마 불일치 방지."""
    for p in local_params:
        if p["n_features_in"] != expected_features:
            raise ValueError(
                f"노드 '{p['node_id']}'의 피처 수({p['n_features_in']})가 "
                f"기준({expected_features})과 다릅니다. "
                "모든 노드는 동일한 피처 스키마를 공유해야 합니다."
            )


# ─── Step 3: 단순 vs 가중 FedAvg 비교 시뮬레이션 ─────────────────
if __name__ == "__main__":
    import os
    import sys
    sys.path.insert(0, os.path.dirname(__file__))
    from train_model import add_entropy_features, DATA_PATH
    import pandas as pd
    from sklearn.preprocessing import StandardScaler

    np.random.seed(42)

    print("=" * 65)
    print("Weighted FedAvg 시뮬레이션")
    print("졸작 당시 상황 재현: 노드마다 보유 데이터 크기가 다른 불균형 환경")
    print("=" * 65)

    df = pd.read_csv(DATA_PATH)
    df = add_entropy_features(df)
    features = ["country_code", "rule_code", "uri_len", "uri_entropy", "rule_entropy"]

    scaler = StandardScaler()
    X_all = scaler.fit_transform(df[features])

    # 불균형 분할: [60%, 25%, 15%] — 실제 기관 간 데이터 보유량 차이를 시뮬레이션
    n = len(X_all)
    splits = [
        ("edge-node-1 (주요 IDC)", X_all[:int(n * 0.60)]),
        ("edge-node-2 (지사 서버)", X_all[int(n * 0.60):int(n * 0.85)]),
        ("edge-node-3 (소규모 지점)", X_all[int(n * 0.85):]),
    ]

    local_params = []
    for node_id, X_node in splits:
        n_samples = len(X_node)
        node_model = IsolationForest(
            n_estimators=100,
            max_samples=max(16, int(n_samples * 0.6)),
            contamination=0.15,
            random_state=42,
        )
        node_model.fit(X_node)
        params = extract_parameters(node_model, node_id=node_id, n_samples=n_samples)
        local_params.append(params)
        print(f"\n[로컬 학습] {node_id} | 샘플 {n_samples}건 | offset={node_model.offset_:.4f}")

    print("\n" + "─" * 65)
    global_model = weighted_fedavg(local_params)

    preds = global_model.predict(X_all)
    n_anomaly = int((preds == -1).sum())
    print(f"\n[글로벌 모델 성능]")
    print(f"  전체 {len(X_all)}건 추론 → 이상 탐지: {n_anomaly}건 ({n_anomaly/len(X_all)*100:.1f}%)")
    print(f"\n  ✅ 원본 WAF 로그는 각 노드 밖으로 이동하지 않음")
    print(f"  ✅ 소규모 지점(15% 데이터)의 과대 표현 방지 (가중치 적용)")
