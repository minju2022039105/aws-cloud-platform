# [확인] 소스 코드 압축 경로 (절대 경로이므로 유지해도 무방)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/analyzer"
  output_path = "${path.root}/../lambda/analyzer.zip"
}

# 2. SecurityAnalyzer (분석가 람다)
resource "aws_lambda_function" "analyzer" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "SecurityAnalyzer"
  role    = module.network.lambda_blocker_role_arn
  handler = "lambda_security_analyzer.handler"  
  runtime       = "python3.11"
  timeout       = 30

  # ⭐️ 핵심: 파일 내용이 바뀌면 테라폼이 감지하여 재배포를 수행함
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      ATHENA_DB     = "monitoring_db"
      ATHENA_TABLE  = "aiops_results"
      ATHENA_OUTPUT = "s3://${var.s3_bucket_name}/athena-results/"
      PREVENTER_FN  = "SecurityPreventer"
    }
  }
}

# 3. SecurityPreventer (방어자 람다)
resource "aws_lambda_function" "preventer" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "SecurityPreventer"
  role = module.network.lambda_blocker_role_arn  
  handler       = "lambda_security_preventer.handler"
  runtime       = "python3.11"
  timeout       = 30 # 예방 로직 처리를 위해 넉넉히 설정

  # ⭐️ 핵심: Preventer도 코드 변경 시 즉시 반영되도록 설정
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# 4. S3 트리거 권한 (S3 -> Analyzer)
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyzer.function_name
  principal     = "s3.amazonaws.com"
  # 실제 S3 버킷의 ARN으로 연결
  source_arn = "arn:aws:s3:::${var.s3_bucket_name}"
}

# 5. S3 이벤트 알림 설정 (파일 생성 시 람다 호출)
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = var.s3_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.analyzer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "results/"
    filter_suffix       = ".json"
  }
  depends_on = [aws_lambda_permission.allow_s3]
}