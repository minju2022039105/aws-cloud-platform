  # S3, IAM, CloudWatch, Lambda는 유지 (비용 거의 0)

  재설계 로드맵

  Week 1: 기반 구축
    ├── S3에 모델 파일 업로드 (isolation_forest_model.pkl)        
    ├── Lambda@Edge 함수 작성 (analyze_anomalies.py 이식)
    └── CloudFront 배포 생성

  Week 2: 보안 로직 이식
    ├── CloudFront Functions으로 IP 차단 룰 구현
    ├── Lambda Preventer → S3 blocklist.json 업데이트 방식으로    
  변경
    └── API Gateway HTTP API 생성
  Week 3: 관찰 가능성
    ├── Lambda X-Ray 트레이싱 활성화
    ├── CloudWatch Dashboard 구성
    └── 비용 After 측정 (Cost Explorer)

  Week 4: 포트폴리오 정리
    ├── Before/After 아키텍처 다이어그램
    ├── 비용 절감 수치 계산서 작성
    └── GitHub README에 의사결정 근거 문서화


================================================================ 
1. 아키텍처 전환 방안

  현재 vs 목표 비용 구조                                             
  ┌────────────┬────────────┬─────────────────┬───────────────┐     │  구성요소  │    현재    │      대체       │ 월 비용 변화  │
  ├────────────┼────────────┼─────────────────┼───────────────┤   
  │ ALB        │ $16~18/월  │ API Gateway     │ $0 (100만 건  │   
  │            │            │ HTTP API        │ 무료)         │
  ├────────────┼────────────┼─────────────────┼───────────────┤   
  │ WAF        │ $5 +       │ CloudFront      │ $0.1/백만 건  │   
  │            │ 요청당     │ Functions       │               │   
  ├────────────┼────────────┼─────────────────┼───────────────┤   
  │ EC2        │ $8~9/월    │ Lambda (128MB)  │ $0 (100만 건  │   
  │ t3.micro   │            │                 │ 무료)         │   
  ├────────────┼────────────┼─────────────────┼───────────────┤   
  │ EIP        │ $3.6/월    │ 불필요          │ $0            │   
  ├────────────┼────────────┼─────────────────┼───────────────┤   
  │ 합계       │ ~$35       │                 │ ~$1~2         │   
  └────────────┴────────────┴─────────────────┴───────────────┘   

  ---
  신규 아키텍처: CloudFront + Lambda

  사용자
    ↓
  CloudFront (엣지 캐싱 + 지역 차단)
    ↓  ← CloudFront Functions: IP 차단 룰 (JS, 경량)
    ↓  ← Lambda@Edge: Isolation Forest 이상 탐지 (Python, 무거운  
  로직)
  API Gateway (HTTP API)
    ↓
  Lambda (보안 분석 결과 처리 + S3 저장)
    ↓
  S3 + CloudWatch (로그 / 알림)

  선택 기준:
  - CloudFront Functions: IP 차단, Geo-block, 헤더 검증 → 1ms     
  이하, 요청당 $0.1/백만
  - Lambda@Edge: Isolation Forest 모델 실행 → 최대 30초,
  128~1024MB 선택
  - API Gateway HTTP API: REST API보다 70% 저렴, WAF 연동 불필요  

  핵심 이식 작업 3가지:

  # ① CloudFront Functions (JS) — IP 차단 룰
  function handler(event) {
      var request = event.request;
      var clientIP = event.viewer.ip;
      var blocklist = ["1.2.3.4", "5.6.7.8"];  # S3에서 주기적으로
   갱신

      if (blocklist.includes(clientIP)) {
          return { statusCode: 403, statusDescription: "Forbidden"
   };
      }
      return request;
  }

  # ② Lambda@Edge — Isolation Forest 이식
  # 기존 EC2의 analyze_anomalies.py를 Lambda 핸들러로 감싸기만    
  하면 됨
  import json, boto3, joblib, numpy as np
  from io import BytesIO

  s3 = boto3.client('s3')

  def lambda_handler(event, context):
      # 모델을 /tmp에 캐싱 (Lambda 컨테이너 재사용 시 로드 생략)  
      if not hasattr(lambda_handler, 'model'):
          obj = s3.get_object(Bucket='your-bucket',
  Key='models/isolation_forest_model.pkl')
          lambda_handler.model =
  joblib.load(BytesIO(obj['Body'].read()))

      uri = event['Records'][0]['cf']['request']['uri']
      features = extract_features(uri)  # 기존 함수 그대로        
      pred = lambda_handler.model.predict([features])

      if pred[0] == -1:  # 이상 탐지
          return {'status': '403', 'statusDescription': 'Blocked'}

      return event['Records'][0]['cf']['request']

  # ③ IP 차단 목록 자동 갱신 (기존 Lambda Preventer 역할 유지)    
  # EventBridge Scheduler → Lambda → S3의 blocklist.json 업데이트 
  # CloudFront Functions은 S3에서 읽어서 캐싱

  ---
  2. 포트폴리오에서 강조할 역량

  DevSecOps 주니어 채용 시 면접관이 실제로 보는 것:

  ① 비즈니스 마인드 (가장 희소한 역량)

  ▎ "왜 이 리소스를 선택했는가"를 비용 근거로 설명할 수 있는가    

  ❌ 약한 서술: "서버리스로 전환했습니다"
  ✅ 강한 서술: "ALB는 트래픽 0건에도 시간당 $0.008이 과금되는    
                구조적 낭비였습니다. 실제 트래픽 패턴(일 평균     
  200건)을
                분석했을 때 Lambda가 월 $0.04, ALB가 $17임을      
  확인하고
                전환을 결정했습니다."

  ② 보안 비타협 설계

  ▎ 비용을 줄이면서 보안 수준을 떨어뜨리지 않았음을 증명

  - WAF Managed Rules 제거 → CloudFront Functions으로 동일 룰 직접
   구현했다는 것
  - ALB 제거 → API Gateway의 throttling + IAM 인증으로 대체했다는 
  것

  ③ 관찰 가능성(Observability) 설계

  ▎ 서버리스는 디버깅이 어렵다는 인식이 있음. Lambda X-Ray +      
  ▎ CloudWatch Structured Logging을 붙이면 "운영 가능한
  ▎ 시스템"임을 증명

  포트폴리오 제목 제안:

  ▎ "월 $35 → $1.5: 보안 성능을 유지하며 고정 비용 96% 절감한     
  ▎ WAF-less 서버리스 보안 파이프라인 설계"

  이 제목 하나에 FinOps + 서버리스 + 보안 설계 판단력 세 가지가   
  들어갑니다.

  ---
  3. 실행 로드맵

  인프라 내리기 전 (오늘, 1~2시간)

  # 반드시 캡처해야 할 데이터

  # 1. 현재 비용 증거 (Before 수치)
  aws ce get-cost-and-usage \
    --time-period Start=2025-04-01,End=2025-05-05 \
    --granularity MONTHLY \
    --group-by Type=DIMENSION,Key=SERVICE \
    --metrics BlendedCost > cost_before.json

  # 2. 현재 아키텍처 상태 스냅샷
  terraform show -json > architecture_snapshot.json

  # 3. WAF 차단 통계 (보안 효과 수치화)
  aws wafv2 get-sampled-requests \
    --web-acl-arn $(terraform output -raw waf_web_acl_arn) \      
    --rule-metric-name devsecopsWAF \
    --scope REGIONAL \
    --time-window StartTime=$(date -d '7 days ago'
  +%s),EndTime=$(date +%s) \
    --max-items 100 > waf_samples_before.json

  # 4. ALB 액세스 로그에서 실제 트래픽 패턴 추출
  aws logs get-log-events \
    --log-group-name /aws/vpc/devsecops-flow-logs \
    --limit 500 > traffic_pattern.json

  인프라 내리기 (Day 1)

  # 삭제 순서 중요 (의존성 역순)
  # 1. WAF 연결 해제 먼저
  terraform destroy -target=aws_wafv2_web_acl_association.main    

  # 2. 나머지 한 번에
  terraform destroy \
    -target=module.alb \
    -target=module.security \
    -target=aws_instance.security_node \
    -target=aws_eip.analysis_node_eip


  ---
  핵심 한 줄: 지금 캡처할 "Before 데이터"가 나중에 포트폴리오의   
  절반입니다. 내리기 전 비용 스크린샷과 WAF 통계를 반드시
  저장하세요.