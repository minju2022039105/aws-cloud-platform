 ---
  AWS DevSecOps Platform — 폴더/파일 역할 및 아키텍처 분석

  ---
  전체 실행 흐름 개요 (먼저 읽으세요)

  [Terraform 배포]
        ↓
  [CloudFront + WAF] ← CloudFront Function(ip_block.js) +
  WAF Rules
        ↓ 요청 수신
  [API Gateway] ← Lambda@Edge(실시간 AI 추론) 선행 차단
        ↓ 로그
  [WAF Logs → S3] → Athena 테이블
        ↓ (EventBridge 주기 실행)
  [SecurityAnalyzer Lambda] → Athena 쿼리 → Isolation
  Forest 판단
        ↓ 이상 감지
  [SecurityPreventer Lambda] → WAF IP Set 갱신 + SNS 알림
        ↓                                                  
  [CloudWatch Metrics] → Grafana 대시보드

  ---
  [infra/]

  역할: 프로젝트 전체 AWS 리소스를 선언하는 Terraform IaC
  루트. 네트워크, 보안, Lambda, WAF, CloudFront, 모니터링,
  예산 등 모든 인프라의 단일 진실 공급원(Single Source of
  Truth).

  카테고리: 배포(deploy)

  핵심 파일 및 생성 리소스:

  파일: provider.tf
  생성하는 AWS 리소스: S3 백엔드(tfstate), DynamoDB 락     
    테이블, AWS 프로바이더 설정
  흐름에서의 위치: 가장 먼저 실행 — 상태 저장소 설정       
  ────────────────────────────────────────
  파일: main.tf
  생성하는 AWS 리소스: KMS 키(공유), SNS 토픽(보안 알림),  
    EventBridge 규칙(WAF/Config 이벤트)
  흐름에서의 위치: 공통 리소스 + 모듈 호출
  ────────────────────────────────────────
  파일: lambda.tf
  생성하는 AWS 리소스: SecurityAnalyzer Lambda,
    SecurityPreventer Lambda, S3 이벤트 트리거, Lambda ZIP 
  흐름에서의 위치: Lambda 배포의 핵심
  ────────────────────────────────────────
  파일: apigateway.tf
  생성하는 AWS 리소스: REST API v1, CloudWatch 로깅, ACM   
  TLS
    인증서, Route53, WAF 연결
  흐름에서의 위치: 퍼블릭 엔드포인트
  ────────────────────────────────────────
  파일: cloudtrail.tf
  생성하는 AWS 리소스: CloudTrail(멀티리전), S3 감사 버킷, 
    VPC Flow Logs, IAM Access Analyzer
  흐름에서의 위치: 감사/컴플라이언스
  ────────────────────────────────────────
  파일: config.tf
  생성하는 AWS 리소스: AWS Config, 11개 ISMS 규칙,
  GuardDuty
  흐름에서의 위치: 컴플라이언스 자동화
  ────────────────────────────────────────
  파일: budget.tf
  생성하는 AWS 리소스: Budget 알람($10/월 80% 임계값)      
  흐름에서의 위치: 비용 거버넌스
  ────────────────────────────────────────
  파일: edge_security.tf
  생성하는 AWS 리소스: CloudFront 배포,
    Lambda@Edge(origin-request), CloudFront WAF, S3 모델   
    저장소
  흐름에서의 위치: AI 실시간 추론 경로
  ────────────────────────────────────────
  파일: traffic_generator.tf
  생성하는 AWS 리소스: EventBridge 6시간 크론,
    NormalTrafficGenerator Lambda
  흐름에서의 위치: 훈련 데이터 수집 자동화

  modules/vpc/main.tf 생성 리소스:
  - VPC(10.0.0.0/16), 퍼블릭 서브넷 2개, IGW, 기본 SG      
  - IAM 역할 3개: EC2 AI 역할, Lambda 블로커 역할, GitHub  
  Actions OIDC 역할(Access Key 없이 CI/CD)

  modules/waf/main.tf 생성 리소스:
  - WAF Web ACL (REGIONAL) — 우선순위 0~5:
    - 0: Geo-block (KR 제외 전체 차단)
    - 1: AI 탐지 IP Set 블록 (Preventer Lambda가 갱신)     
    - 2~5: AWS 관리형 규칙 + IP 평판 목록

  cloudfront_functions/ip_block.js:
  - CloudFront Viewer Request 단계에서 실행
  (Lambda@Edge보다 더 앞단)
  - WAF와 별개로 CloudFront 레벨 IP 차단 → 빠른 응답, 비용 
  절감

  연결되는 구성: lambda/, ai/models/,
  monitoring/cloudwatch/, .github/workflows/

  운영 필수 여부: 전체 필수 — 이 폴더가 없으면 인프라      
  자체가 없음

  비고: provider.tf의 S3 백엔드 버킷명
  minju-devsecops-tfstate-virginia은 하드코딩되어 있어 다른
   계정에서 재사용 시 수정 필요

  ---
  [lambda/]

  역할: AWS Lambda 함수 4개의 실제 실행 코드. 보안
  자동화(탐지→차단→알림)의 핵심 로직과 훈련 데이터 수집    
  자동화를 담당.

  카테고리: 추론(inference) + 보안(security) + 배포(deploy)

  ---
  lambda/analyzer/ — SecurityAnalyzer

  역할: WAF 로그에서 이상 트래픽을 탐지하는 "탐지 엔진".   
  Athena로 S3의 WAF 로그를 쿼리하고 Isolation Forest       
  스코어로 이상 IP를 판별.

  핵심 파일: lambda_security_analyzer.py

  실행 트리거:
  - S3 이벤트(WAF 로그 신규 파일 업로드 시)
  - 또는 EventBridge 주기 실행

  실행 로직 흐름:
  S3에 WAF 로그 파일 생성
        ↓
  Athena 쿼리: aiops_results 테이블, anomaly=1 필터        
        ↓
  IP별 이상 점수 집계
        ↓
  임계값 초과 IP → SecurityPreventer Lambda 직접 호출(boto3
   invoke)

  연결되는 구성: infra/lambda.tf(배포),
  lambda/preventer/(호출), monitoring/cloudwatch/(Athena   
  DDL), WAF 로그 S3 버킷

  운영 필수 여부: 필수

  ---
  lambda/preventer/ — SecurityPreventer

  역할: Analyzer로부터 이상 IP를 받아 WAF IP Set에 자동    
  등록하고 알림을 발송하는 "차단 실행기".

  핵심 파일: lambda_security_preventer.py

  실행 트리거: SecurityAnalyzer Lambda가 직접 invoke       
  (이벤트 드리븐 체인)

  실행 로직 흐름:
  Analyzer Lambda로부터 이상 IP 수신
        ↓
  wafv2.get_ip_set() → 현재 IP Set 조회
        ↓
  IP/32 추가 → wafv2.update_ip_set() 호출
        ↓
  CloudWatch 커스텀 메트릭 기록(blocked_ips 카운터)        
        ↓
  SNS 토픽으로 이메일 알림 발송

  연결되는 구성: infra/modules/waf/(WAF IP Set ARN),       
  infra/main.tf(SNS 토픽), CloudWatch

  운영 필수 여부: 필수

  ---
  lambda/edge_security/ — Lambda@Edge

  역할: CloudFront origin-request 단계에서 실행되는 실시간 
  AI 추론기. 요청이 오리진(API Gateway)에 도달하기 전에    
  Isolation Forest로 스코어링해 즉시 차단.

  핵심 파일: handler.py

  실행 트리거: CloudFront origin-request 이벤트 (모든      
  요청마다 실행)

  실행 로직 흐름:
  CloudFront 요청 수신
        ↓
  S3에서 모델 파일 다운로드 → /tmp 캐시 (cold start 시만)  
        ↓
  요청 특성 추출: country_code, rule_code, uri_len,        
  uri_entropy
        ↓
  Isolation Forest 스코어 계산 (순수 Python 구현, sklearn  
  미사용)
        ↓
  스코어 < -0.5 → 403 즉시 반환
  스코어 ≥ -0.5 → 오리진으로 정상 전달
  오류 발생 → fail-open(정상 전달, 오탐 방지)

  중요 특이사항: Lambda@Edge는 us-east-1에서만 배포        
  가능하며, sklearn 같은 외부 패키지를 사용할 수 없어      
  Isolation Forest를 순수 Python으로 재구현.
  ai/inference/export_model.py가 트리 구조를 JSON으로      
  직렬화하고 이를 활용.

  연결되는 구성: infra/edge_security.tf(배포),
  ai/inference/export_model.py(모델 JSON 생성), S3 모델    
  저장소

  운영 필수 여부: 필수 (WAF의 AI 차단 레이어)

  ---
  lambda/traffic_generator/ — NormalTrafficGenerator       

  역할: 정상 트래픽 패턴을 주기적으로 API Gateway에 전송해 
  WAF 로그에 정상 샘플을 누적. AI 모델 재훈련용 데이터 수집
   자동화.

  핵심 파일: handler.py

  실행 트리거: EventBridge 6시간 크론
  (infra/traffic_generator.tf)

  실행 로직 흐름:
  EventBridge 6시간마다 트리거
        ↓
  시간대별 가중치 계산:
    - 09~18시: 1.0x (업무 시간)
    - 18~22시: 0.6x (저녁)
    - 00~06시: 0.2x (새벽)
        ↓
  300개 요청 × 가중치 = 실제 전송 수
  경로 랜덤화: /api/v1/users, /health 등
  User-Agent 랜덤화
        ↓
  urllib로 실제 API Gateway 엔드포인트 요청
        ↓
  요청 결과 WAF 로그 → S3 → Athena → AI 훈련 데이터        

  연결되는 구성: infra/traffic_generator.tf(스케줄),       
  scripts/generate_normal_traffic.py(로컬 버전), WAF 로그  
  S3

  운영 필수 여부: 운영 시 권장 (없으면 정상 트래픽 샘플이  
  누적되지 않아 AI 재훈련 어려움)

  ---
  [ai/]

  역할: Isolation Forest 기반 이상 트래픽 탐지 모델의 전체 
  ML 파이프라인. 데이터 준비 → 학습 → 평가 → Lambda@Edge   
  배포 형태로 내보내기까지 포함.

  카테고리: 학습(train) + 추론(inference)

  ---
  ai/data/

  역할: 모델 훈련 및 평가에 사용되는 데이터셋.

  파일: final_preprocessed_waf_data.csv
  생성 주체: scripts/generate_normal_traffic.py + 수동 공격

    패턴
  내용: 1,750 샘플 (정상 1,350 + 공격 400)
  사용 목적: 훈련/평가 입력

  운영 필수 여부: 훈련 시 필수. 배포 후에는 불필요(모델만  
  필요)

  ---
  ai/models/

  역할: 훈련 완료된 모델 artifact 저장소.

  파일: isolation_forest_model.pkl
  생성 주체: ai/training/train_model.py
  내용: sklearn Isolation Forest 객체
  사용 목적: 로컬 추론/평가용
  ────────────────────────────────────────
  파일: scaler.pkl
  생성 주체: ai/training/train_model.py
  내용: StandardScaler fitted 객체
  사용 목적: 특성 정규화

  중요: 이 .pkl 파일은 로컬 추론 전용. Lambda@Edge에는     
  sklearn 사용 불가 → export_model.py가 JSON으로 변환해 S3 
  업로드.

  운영 필수 여부: 로컬 개발/평가에 필수. Lambda@Edge       
  런타임에는 불필요

  ---
  ai/results/

  역할: 모델 평가 결과물 저장소. 재현 가능성 확보 및 성능  
  추적.

  파일: performance_metrics.json
  생성 주체: ai/inference/eval_model.py
  내용: contamination 스윕 결과, IQR 안정성, 추천값(0.05)  
  ────────────────────────────────────────
  파일: detection_result.png
  생성 주체: ai/inference/eval_visual.py
  내용: entropy vs URI 길이 산점도
  ────────────────────────────────────────
  파일: analysis_report.txt
  생성 주체: ai/inference/analyze_anomalies.py
  내용: 이상 탐지 리포트

  운영 필수 여부: 실험/문서화 목적. 운영 시 직접 참조      
  불필요

  ---
  ai/training/

  역할: 모델 학습 및 하이퍼파라미터 실험.

  파일: train_model.py
  역할: 핵심 — contamination=0.25, n_estimators=200, 5특성 
    학습
  운영 여부: 재훈련 시 실행
  ────────────────────────────────────────
  파일: federated_learning.py
  역할: 다중 노드 Weighted FedAvg 집계 (데이터 주권 보존)  
  운영 여부: 실험적 — 현재 단일 노드 운영이면 미사용       
  ────────────────────────────────────────
  파일: benchmark.py
  역할: contamination [0.05~0.30] 스윕 실험
  운영 여부: 실험용

  훈련 특성(5개): country_code, rule_code, uri_len,        
  uri_entropy, rule_entropy

  연결 흐름:
  ai/data/final_preprocessed_waf_data.csv
        ↓ train_model.py
  ai/models/isolation_forest_model.pkl + scaler.pkl        
        ↓ export_model.py
  S3 버킷 (모델 JSON)
        ↓
  lambda/edge_security/handler.py (실시간 추론)

  운영 필수 여부: train_model.py는 재훈련 시 필수.
  federated_learning.py, benchmark.py는 실험용

  ---
  ai/inference/

  역할: 훈련된 모델의 검증, 평가, 시각화, Lambda용
  내보내기.

  ┌──────────────────┬───────────────────┬────────────┐    
  │       파일       │       역할        │ 운영 여부  │    
  ├──────────────────┼───────────────────┼────────────┤    
  │                  │ 핵심 — pkl → JSON │ 배포 파이  │    
  │ export_model.py  │  직렬화 → S3      │ 프라인에   │    
  │                  │ 업로드            │ 필수       │    
  ├──────────────────┼───────────────────┼────────────┤    
  │                  │ 모델 스키마 검증  │ 배포 전    │    
  │ check_model.py   │ (feature names    │ 검증에     │    
  │                  │ 확인)             │ 유용       │    
  ├──────────────────┼───────────────────┼────────────┤    
  │ analyze_anomalie │ 실제 데이터로     │ 운영       │    
  │ s.py             │ 이상 탐지 + Conta │ 모니터링   │    
  │                  │ minationSentinel  │ 보조       │    
  ├──────────────────┼───────────────────┼────────────┤    
  │ eval_model.py    │ Precision/Recall/ │ 재훈련 후  │    
  │                  │ F1 평가           │ 성능 검증  │    
  ├──────────────────┼───────────────────┼────────────┤    
  │ eval_visual.py   │ 산점도 시각화     │ 실험/보고  │    
  │                  │ 생성              │ 용         │    
  └──────────────────┴───────────────────┴────────────┘    

  운영 필수 여부: export_model.py는 배포 필수. 나머지는    
  평가/실험용

  ---
  [monitoring/]

  역할: 운영 중 시스템 상태를 가시화하는 관측
  가능성(Observability) 레이어.

  카테고리: 모니터링(monitoring)

  ---
  monitoring/prometheus-demo/

  핵심 파일: monitor.py

  역할: Prometheus exporter를 로컬에서 시뮬레이션. 실제    
  운영 지표가 아닌 데모/개발 목적.

  실행 흐름:
  python monitor.py 실행 → :8000 HTTP 서버 기동
        ↓
  210초 시나리오 시뮬레이션:
    0s~30s:  NORMAL (정상 트래픽 지표)
    30s~90s: PREDICT (이상 탐지 중)
    90s~150s: ATTACK (공격 트래픽 증가)
    150s~210s: STABILIZE (차단 후 안정화)
        ↓
  Prometheus → Grafana (로컬 대시보드)

  운영 필수 여부: 개발/데모 전용. 실제 운영에서는
  CloudWatch → Grafana Cloud 구조 사용

  ---
  monitoring/cloudwatch/

  역할: Athena DDL(테이블 정의)과 Grafana 대시보드 JSON    
  설정 저장.

  ┌─────────────────────────────┬──────────────────────┐   
  │       파일 추정 내용        │         역할         │   
  ├─────────────────────────────┼──────────────────────┤   
  │                             │ WAF 로그 S3 → Athena │   
  │ Athena DDL SQL              │  쿼리 가능하게       │   
  │                             │ 스키마 정의          │   
  ├─────────────────────────────┼──────────────────────┤   
  │ Grafana 대시보드 JSON       │ CloudWatch/Athena    │   
  │                             │ 데이터 시각화 설정   │   
  ├─────────────────────────────┼──────────────────────┤   
  │ grafana-athena-policy.json  │ Grafana Cloud에      │   
  │ (infra/에 위치)             │ 부여할 IAM 정책      │   
  │                             │ (Athena + S3 read)   │   
  └─────────────────────────────┴──────────────────────┘   

  CloudWatch/Athena/Grafana 데이터 흐름:
  WAF → S3 로그 버킷
        ↓ Athena (monitoring/cloudwatch/ DDL)
        ↓ SQL 쿼리
  CloudWatch 메트릭 (Preventer Lambda가 put_metric_data)   
        ↓
  Grafana Cloud (grafana-athena-policy.json 권한으로 연결) 
        ↓
  대시보드: 차단 IP 수, 이상 탐지율, 요청량 추이

  운영 필수 여부: Athena DDL은 필수(없으면 Analyzer Lambda 
  쿼리 불가). Grafana JSON은 권장

  ---
  [scripts/]

  역할: 로컬 개발 및 테스트 목적의 트래픽 생성 스크립트.   
  Lambda traffic_generator의 로컬 버전.

  카테고리: 학습(train) 데이터 수집

  파일: generate_logs.py
  역할: 실제 API Gateway에 80% 정상 + 20% 공격 패턴 전송   
  운영 여부: 개발/테스트용
  ────────────────────────────────────────
  파일: generate_normal_traffic.py
  역할: 1,350개 정상 트래픽 샘플 생성 → CSV
  운영 여부: 훈련 데이터 생성 시 사용

  traffic_generator가 프로젝트에서 하는 역할 (전체 맥락):  

  [운영 자동화 경로]
  traffic_generator Lambda (6시간마다)
        ↓ 실제 HTTP 요청
  API Gateway → WAF → S3 로그
        ↓
  정상 트래픽 패턴이 WAF 로그에 축적
        ↓
  Analyzer가 정상 vs 이상 비교 기준 확보
        ↓
  AI 모델 주기적 재훈련 (미래 자동화 예정)

  [개발/로컬 경로]
  scripts/generate_normal_traffic.py
        ↓ CSV 직접 생성
  ai/data/final_preprocessed_waf_data.csv
        ↓
  ai/training/train_model.py (초기 훈련)

  즉, traffic_generator는 운영 중 AI 모델이 지속적으로 정상
   기준을 갱신할 수 있도록 실제 트래픽 데이터를 자동       
  공급하는 피드백 루프의 시작점.

  운영 필수 여부: scripts/는 개발용.
  lambda/traffic_generator/는 운영 권장

  ---
  [tfsec/]

  역할: Terraform 코드의 보안 취약점 정적 분석 결과물      
  저장소.

  카테고리: 보안(security)

  파일: tfsec-result.json
  생성 주체: tfsec CLI 또는 CI/CD 파이프라인
  내용: 초기 스캔 결과 — HIGH/MEDIUM 취약점 목록
  운영 여부: 참조용
  ────────────────────────────────────────
  파일: tfsec-result.csv
  생성 주체: tfsec-result.json → 변환
  내용: 스프레드시트 분석용 CSV
  운영 여부: 참조용

  실행 시점: terraform plan/apply 전 .github/workflows/에서
   자동 실행 (또는 수동)

  연결되는 구성: infra/ 전체 tf 파일, .github/workflows/,  
  .trivyignore(컨테이너 스캔 예외 설정)

  운영 필수 여부: 파일 자체는 결과물(artifact). tfsec 실행 
  자체는 CI/CD에서 필수

  ---
  [tests/]

  역할: 현재 비어 있음. 테스트 코드 없음.

  카테고리: 해당 없음 (미구현)

  운영 필수 여부: 현재 불필요. 아래 개선 섹션 참조.        

  ---
  [.github/workflows/]

  역할: GitHub Actions CI/CD 파이프라인. OIDC 인증으로 AWS 
  Access Key 없이 Terraform 배포.

  카테고리: 배포(deploy) + 보안(security)

  실행 흐름:
  PR/Push to main
        ↓
  1. tfsec 정적 분석 (infra/ 스캔)
  2. terraform fmt/validate
  3. terraform plan
        ↓ (main 머지 시)
  4. terraform apply
        ↓
  GitHub Actions OIDC → AWS STS AssumeRoleWithWebIdentity  
  (Access Key 없이 임시 자격증명)

  연결되는 구성: infra/modules/vpc/main.tf(OIDC IAM 역할), 
  tfsec/(결과 업로드), 전체 infra/

  운영 필수 여부: 필수

  ---
  실행 흐름 종합 정리

  1. AI 모델 학습 → 저장 → 추론 → 결과 분석

  [데이터 수집]
  scripts/generate_normal_traffic.py (로컬)
  또는 lambda/traffic_generator/handler.py (운영 자동화)   
        ↓
  ai/data/final_preprocessed_waf_data.csv

  [훈련]
  ai/training/train_model.py
        ↓
  ai/models/isolation_forest_model.pkl + scaler.pkl        

  [평가]
  ai/inference/eval_model.py →
  ai/results/performance_metrics.json
  ai/inference/eval_visual.py →
  ai/results/detection_result.png

  [Lambda 배포용 내보내기]
  ai/inference/export_model.py
        ↓
  S3://모델버킷/model.json

  [실시간 추론]
  lambda/edge_security/handler.py
  (CloudFront origin-request 마다 S3에서 model.json 로드 → 
  스코어링)

  [배치 추론]
  lambda/analyzer/lambda_security_analyzer.py
  (Athena 쿼리 결과 → Isolation Forest 판단)

  2. Terraform → Lambda → WAF → Monitoring

  infra/modules/waf/main.tf → WAF Web ACL + IP Set 생성    
  infra/lambda.tf → SecurityAnalyzer + Preventer Lambda    
  배포
  infra/edge_security.tf → Lambda@Edge + CloudFront WAF    
  배포
        ↓
  [실시간]
  Lambda@Edge → CloudFront WAF 직접 차단
        ↓
  [배치]
  S3(WAF 로그) → Analyzer Lambda → Preventer Lambda        
  → WAF IP Set 갱신 (infra/modules/waf/의 IP Set 동적      
  업데이트)
  → CloudWatch put_metric_data
  → SNS → 이메일 알림 (infra/main.tf의 SNS 토픽)

  3. CloudWatch / Athena / Grafana 데이터 흐름

  WAF → S3 로그 버킷 (infra/modules/waf/main.tf의 S3 버킷) 
        ↓ (Athena DDL: monitoring/cloudwatch/)
  Athena 테이블 (aiops_results)
        ↓ (Analyzer Lambda가 쿼리)
  탐지 결과 → CloudWatch 커스텀 메트릭 (Preventer Lambda)  
        ↓
  Grafana Cloud (infra/grafana-athena-policy.json 권한)    
  → Athena 데이터소스: WAF 로그 시계열 쿼리
  → CloudWatch 데이터소스: 차단 IP 카운터 시각화

  4. 운영 필수 vs 실험용 파일

  ┌───────────────────────────┬──────────┬────────────┐    
  │         파일/폴더         │   분류   │    이유    │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ infra/ 전체               │ 운영     │ 인프라     │    
  │                           │ 필수     │ 자체       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ lambda/analyzer/,         │ 운영     │ SOAR       │    
  │ lambda/preventer/         │ 필수     │ 자동화     │    
  │                           │          │ 핵심       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ lambda/edge_security/     │ 운영     │ 실시간 AI  │    
  │                           │ 필수     │ 차단       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ lambda/traffic_generator/ │ 운영     │ AI 피드백  │    
  │                           │ 권장     │ 루프       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ ai/training/train_model.p │ 재훈련   │ 모델 갱신  │    
  │ y                         │ 시 필수  │            │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ ai/inference/export_model │ 배포 시  │ Lambda용   │    
  │ .py                       │ 필수     │ 모델 변환  │    
  ├───────────────────────────┼──────────┼────────────┤    
  │                           │ 로컬     │ Lambda     │    
  │ ai/models/*.pkl           │ 개발     │ 런타임엔   │    
  │                           │ 필수     │ 미사용     │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ monitoring/prometheus-dem │ 실험용   │ 데모 전용  │    
  │ o/                        │          │            │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ ai/training/federated_lea │          │ 단일 노드  │    
  │ rning.py                  │ 실험용   │ 운영 시    │    
  │                           │          │ 미사용     │    
  ├───────────────────────────┼──────────┼────────────┤    
  │                           │          │ 하이퍼파라 │    
  │ ai/training/benchmark.py  │ 실험용   │ 미터 탐색  │    
  │                           │          │ 완료       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ ai/inference/eval_*.py    │ 개발/검  │ 재훈련 후  │    
  │                           │ 증용     │ 성능 확인  │    
  ├───────────────────────────┼──────────┼────────────┤    
  │                           │          │ 로컬       │    
  │ scripts/                  │ 개발용   │ 데이터     │    
  │                           │          │ 생성       │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ tfsec/*.json              │ 참조용   │ 스캔 결과  │    
  │                           │          │ artifact   │    
  ├───────────────────────────┼──────────┼────────────┤    
  │ tests/                    │ 미구현   │ 비어 있음  │    
  └───────────────────────────┴──────────┴────────────┘    

  ---
  현재 프로젝트 구조 개선 포인트 (아키텍처 관점)

  1. tests/ 폴더가 비어 있음 — 가장 큰 리스크

  Lambda 함수 3개(Analyzer, Preventer, traffic_generator)에
   테스트가 전혀 없습니다. 특히
  lambda_security_preventer.py는 실제 WAF IP Set을 수정하는
   사이드이펙트가 있어, 의도치 않은 IP 차단이나 IP Set 포맷
   오류 시 인프라 장애로 이어질 수 있습니다.

  권장: moto 라이브러리를 이용한 WAF/CloudWatch mock 단위  
  테스트 추가. CI 파이프라인에 pytest 스텝 추가.

  ---
  2. 모델 버전 관리 체계 부재

  ai/models/isolation_forest_model.pkl과 S3의 model.json이 
  버전 없이 덮어쓰기됩니다. 재훈련 후 성능이 나쁜 모델이   
  배포되면 롤백 방법이 없습니다.

  권장: S3 오브젝트 버저닝 활성화 + model_v{timestamp}.json
   형태로 네이밍. Lambda@Edge 환경 변수로 활성 모델 버전   
  관리.

  ---
  3. Lambda@Edge cold start에서 S3 모델 다운로드 지연      

  handler.py가 cold start 시 S3에서 model.json을
  다운로드합니다. Lambda@Edge는 us-east-1에서 실행되지만   
  CloudFront 엣지 로케이션 전파 후 첫 요청에서 수백ms      
  지연이 발생할 수 있습니다.

  권장: Lambda@Edge 대신 CloudFront Functions(JS)으로 단순 
  룰 기반 차단, 또는 Lambda@Edge에서 /tmp 캐시 TTL을       
  명시적으로 관리.

  ---
  4. federated_learning.py가 현재 아키텍처와 단절

  federated_learning.py는 다중 노드를 가정하지만 현재      
  데이터 수집→훈련→배포 파이프라인에 연결되어 있지
  않습니다. 사용하지 않는 코드는 유지보수 부담이 됩니다.   

  권장: 단일 노드 운영 중이라면 experimental/ 폴더로       
  분리하거나, 실제 다중 노드 아키텍처 계획이 있다면        
  파이프라인에 연결.

  ---
  5. 모델 재훈련 자동화 파이프라인 미완성

  현재 흐름: traffic_generator(자동) → WAF 로그 축적(자동) 
  → 재훈련(수동) → export_model.py(수동) → S3 업로드(수동) 

  재훈련 이후 단계가 수동입니다. 로그가 쌓여도 모델이 자동 
  갱신되지 않으면 개념 드리프트(concept drift)에 대응하기  
  어렵습니다.

  권장: EventBridge 주간 크론 → Step Functions:
  1. train_model.py 실행 (ECS Fargate 또는 Lambda)
  2. eval_model.py로 성능 검증
  3. 임계값 초과 시 export_model.py → S3
  4. Lambda@Edge 재배포 (Terraform 또는 AWS SDK)

  ---
  6. monitoring/prometheus-demo/가 실제 운영 모니터링과    
  분리

  Prometheus 데모는 로컬 시뮬레이션이고, 실제 운영 지표는  
  CloudWatch → Grafana Cloud로 흐릅니다. 이 두 경로가 같은 
  monitoring/ 폴더에 혼재해 혼란을 줄 수 있습니다.

  권장: monitoring/prometheus-demo/ →
  experiments/prometheus-demo/로 이동. 실제 운영 모니터링  
  설정(Grafana JSON, Athena DDL)만 monitoring/에 유지.     

  ---
  7. tfsec 결과물이 git에 커밋됨

  tfsec-result.json이 정적 파일로 저장되어 있어 시간이     
  지나면 인프라와 불일치합니다. CI에서 매번 재생성하는데도 
  과거 결과물이 남아 있으면 오해를 유발합니다.

  권장: tfsec/ 폴더를 .gitignore에 추가하고 CI 아티팩트로만