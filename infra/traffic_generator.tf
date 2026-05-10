# =====================================================================
# traffic_generator.tf — 정상 트래픽 자동 생성 (ML 학습 데이터 수집용)
# EventBridge 6시간마다 Lambda 호출 → ALB에 정상 요청 → WAF ALLOW 로그 적재
# =====================================================================

data "archive_file" "traffic_generator_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/traffic_generator"
  output_path = "${path.root}/../lambda/traffic_generator.zip"
}

resource "aws_iam_role" "traffic_generator_role" {
  name = "traffic-generator-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "traffic_generator_basic" {
  role       = aws_iam_role.traffic_generator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "traffic_generator" {
  filename         = data.archive_file.traffic_generator_zip.output_path
  function_name    = "NormalTrafficGenerator"
  role             = aws_iam_role.traffic_generator_role.arn
  handler          = "handler.handler"
  runtime          = "python3.11"
  timeout          = 300  # 300건 × 최대 0.2초 = 최대 60초, 여유있게 5분

  source_code_hash = data.archive_file.traffic_generator_zip.output_base64sha256

  environment {
    variables = {
      ALB_ENDPOINT   = "http://minju-alb-733893612.us-east-1.elb.amazonaws.com"
      REQUEST_COUNT  = "300"
    }
  }

  tags = { Purpose = "ml-data-collection", Project = "devsecops-platform" }
}

# 6시간마다 실행 (하루 4회 → 약 1,200건/일 → 7일이면 ~8,400건)
resource "aws_cloudwatch_event_rule" "traffic_generator_schedule" {
  name                = "normal-traffic-generator-schedule"
  description         = "6시간마다 정상 트래픽 생성하여 WAF ALLOW 로그 적재"
  schedule_expression = "rate(6 hours)"
}

resource "aws_cloudwatch_event_target" "traffic_generator_target" {
  rule      = aws_cloudwatch_event_rule.traffic_generator_schedule.name
  target_id = "TrafficGeneratorLambda"
  arn       = aws_lambda_function.traffic_generator.arn
}

resource "aws_lambda_permission" "allow_eventbridge_traffic_gen" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.traffic_generator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.traffic_generator_schedule.arn
}
