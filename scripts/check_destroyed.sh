#!/bin/bash

REGION="us-east-1"
ACCOUNT_ID="095035153545"
PROJECT="devsecops"
PASS=0
FAIL=0

green() { echo -e "\e[32m[삭제됨]  $1\e[0m"; PASS=$((PASS+1)); }
red()   { echo -e "\e[31m[잔존중]  $1\e[0m"; FAIL=$((FAIL+1)); }

echo "=============================="
echo " 리소스 삭제 확인"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="
echo ""

# Lambda 함수
echo "[ Lambda ]"
for fn in devsecops-edge-security devsecops-analyzer devsecops-traffic-generator devsecops-preventer; do
  result=$(aws lambda get-function --function-name "$fn" --region "$REGION" 2>&1)
  if echo "$result" | grep -q "ResourceNotFoundException"; then
    green "$fn"
  else
    red "$fn"
  fi
done

echo ""
echo "[ CloudFront ]"
CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?contains(Origins.Items[0].DomainName,'execute-api') || contains(to_string(Aliases.Items),'minju-devsec')].Id" --output text 2>/dev/null)
if [ -z "$CF" ] || [ "$CF" = "None" ]; then
  green "CloudFront Distribution"
else
  red "CloudFront Distribution (ID: $CF)"
fi

echo ""
echo "[ API Gateway ]"
APIGW=$(aws apigateway get-rest-apis --region "$REGION" --query "items[?name=='${PROJECT}-api'].id" --output text 2>/dev/null)
if [ -z "$APIGW" ]; then
  green "API Gateway (${PROJECT}-api)"
else
  red "API Gateway (ID: $APIGW)"
fi

echo ""
echo "[ WAF ]"
REGIONAL_WAF=$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" \
  --query "WebACLs[?contains(Name,'devsecops')].Name" --output text 2>/dev/null)
CF_WAF=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region "$REGION" \
  --query "WebACLs[?contains(Name,'devsecops')].Name" --output text 2>/dev/null)
[ -z "$REGIONAL_WAF" ] && green "WAF Regional" || red "WAF Regional ($REGIONAL_WAF)"
[ -z "$CF_WAF" ]       && green "WAF CloudFront" || red "WAF CloudFront ($CF_WAF)"

echo ""
echo "[ GuardDuty ]"
DETECTOR=$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null)
if [ -z "$DETECTOR" ] || [ "$DETECTOR" = "None" ]; then
  green "GuardDuty Detector"
else
  STATUS=$(aws guardduty get-detector --detector-id "$DETECTOR" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null)
  red "GuardDuty Detector ($STATUS)"
fi

echo ""
echo "[ CloudTrail ]"
TRAIL=$(aws cloudtrail describe-trails --region "$REGION" \
  --query "trailList[?contains(Name,'devsecops')].Name" --output text 2>/dev/null)
[ -z "$TRAIL" ] && green "CloudTrail" || red "CloudTrail ($TRAIL)"

echo ""
echo "[ AWS Config ]"
RECORDER=$(aws configservice describe-configuration-recorders --region "$REGION" \
  --query "ConfigurationRecorders[?contains(name,'devsecops')].name" --output text 2>/dev/null)
[ -z "$RECORDER" ] && green "Config Recorder" || red "Config Recorder ($RECORDER)"

echo ""
echo "[ KMS 키 ]"
# pending deletion 상태인지 확인
KMS_KEYS=$(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null)
ACTIVE_DEVSECOPS_KEYS=0
for key in $KMS_KEYS; do
  desc=$(aws kms describe-key --key-id "$key" --region "$REGION" \
    --query 'KeyMetadata.Description' --output text 2>/dev/null)
  state=$(aws kms describe-key --key-id "$key" --region "$REGION" \
    --query 'KeyMetadata.KeyState' --output text 2>/dev/null)
  if echo "$desc" | grep -qi "devsecops\|Shared KMS\|WAF"; then
    if [ "$state" = "PendingDeletion" ]; then
      green "KMS: $desc (PendingDeletion — 7일 후 완전 삭제)"
    else
      red "KMS: $desc (상태: $state)"
      ACTIVE_DEVSECOPS_KEYS=$((ACTIVE_DEVSECOPS_KEYS+1))
    fi
  fi
done
[ "$ACTIVE_DEVSECOPS_KEYS" -eq 0 ] && true || true  # 위에서 이미 출력

echo ""
echo "[ S3 버킷 ]"
for bucket in "aws-waf-logs-minju-0417-project" "devsecops-model-store-${ACCOUNT_ID}"; do
  exists=$(aws s3api head-bucket --bucket "$bucket" 2>&1)
  if echo "$exists" | grep -q "404\|NoSuchBucket\|Not Found"; then
    green "S3: $bucket"
  else
    OBJ_COUNT=$(aws s3 ls "s3://$bucket" --recursive --summarize 2>/dev/null | grep "Total Objects" | awk '{print $3}')
    red "S3: $bucket (객체 ${OBJ_COUNT:-?}개 잔존)"
  fi
done

echo ""
echo "[ VPC ]"
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*devsecops*" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null)
[ -z "$VPC" ] && green "VPC" || red "VPC ($VPC)"

echo ""
echo "[ ACM 인증서 ]"
CERT=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'minju-devsec')].DomainName" \
  --output text 2>/dev/null)
[ -z "$CERT" ] && green "ACM 인증서" || red "ACM 인증서 ($CERT)"

echo ""
echo "[ SNS ]"
SNS=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn,'devsecops')].TopicArn" --output text 2>/dev/null)
[ -z "$SNS" ] && green "SNS Topic" || red "SNS Topic"

echo ""
echo "=============================="
echo " 결과: 삭제됨 ${PASS}개 / 잔존중 ${FAIL}개"
echo "=============================="
