-- =============================================================
-- AWS WAF 원본 로그 Athena 테이블 DDL
-- 버킷:   aws-waf-logs-minju-0417-project
-- 계정:   095035153545
-- 리전:   us-east-1
-- WebACL: devsecops-waf
-- =============================================================
-- [실행 전 확인]
-- 1. Athena 콘솔에서 데이터베이스: monitoring_db 선택
-- 2. Query result location 설정:
--    s3://aws-waf-logs-minju-0417-project/athena-results/
-- =============================================================

CREATE EXTERNAL TABLE IF NOT EXISTS monitoring_db.waf_access_logs (
  timestamp           BIGINT,
  formatversion       INT,
  webaclid            STRING,
  terminatingruleid   STRING,
  terminatingruletype STRING,
  action              STRING,
  httpsourcename      STRING,
  httpsourceid        STRING,
  httprequest STRUCT<
    clientip   : STRING,
    country    : STRING,
    uri        : STRING,
    args       : STRING,
    httpmethod : STRING,
    httpversion: STRING,
    headers    : ARRAY<STRUCT<name:STRING, value:STRING>>
  >,
  rulegrouplist ARRAY<STRUCT<
    rulegroupid : STRING,
    terminatingrule : STRUCT<ruleid:STRING, action:STRING>,
    nonterminatingmatchingrules : ARRAY<STRUCT<ruleid:STRING, action:STRING>>
  >>,
  labels ARRAY<STRUCT<name:STRING>>
)
PARTITIONED BY (
  year  STRING,
  month STRING,
  day   STRING,
  hour  STRING
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://aws-waf-logs-minju-0417-project/AWSLogs/095035153545/WAFLogs/us-east-1/devsecops-waf/'
TBLPROPERTIES (
  'has_encrypted_data' = 'true',
  'projection.enabled' = 'true',
  'projection.year.type'  = 'enum',
  'projection.year.values' = '2026',
  'projection.month.type' = 'enum',
  'projection.month.values' = '01,02,03,04,05,06,07,08,09,10,11,12',
  'projection.day.type'   = 'integer',
  'projection.day.range'  = '01,31',
  'projection.day.digits' = '2',
  'projection.hour.type'  = 'integer',
  'projection.hour.range' = '00,23',
  'projection.hour.digits' = '2',
  'storage.location.template' =
    's3://aws-waf-logs-minju-0417-project/AWSLogs/095035153545/WAFLogs/us-east-1/devsecops-waf/${year}/${month}/${day}/${hour}/'
);


-- =============================================================
-- Grafana Athena 쿼리 모음
-- =============================================================

-- [쿼리 1] WAF 룰별 차단 건수 (Bar chart)
-- Grafana 변수: $__timeFilter → Athena에서는 timestamp 직접 필터로 대체
SELECT
  terminatingruleid                   AS rule,
  COUNT(*)                            AS block_count
FROM monitoring_db.waf_access_logs
WHERE action = 'BLOCK'
  AND year = '2026'
  AND month = '05'
GROUP BY terminatingruleid
ORDER BY block_count DESC;


-- [쿼리 2] 공격 유형 분포 (Pie chart)
SELECT
  CASE
    WHEN terminatingruleid LIKE '%SQLi%'               THEN 'SQLi'
    WHEN terminatingruleid LIKE '%XSS%'                THEN 'XSS'
    WHEN terminatingruleid LIKE '%CommonRule%'          THEN 'CommonRuleSet'
    WHEN terminatingruleid = 'GeoBlock-Non-KR'          THEN 'GeoBlock'
    WHEN terminatingruleid = 'AI-RealTime-Block-Rule'   THEN 'AI Block'
    WHEN terminatingruleid LIKE '%ReputationList%'      THEN 'IP Reputation'
    ELSE 'Other'
  END AS attack_type,
  COUNT(*) AS cnt
FROM monitoring_db.waf_access_logs
WHERE action = 'BLOCK'
  AND year = '2026'
  AND month = '05'
GROUP BY 1
ORDER BY cnt DESC;


-- [쿼리 3] 국가별 차단 건수 (Geomap / Bar chart)
SELECT
  httprequest.country AS country,
  COUNT(*)            AS block_count
FROM monitoring_db.waf_access_logs
WHERE action = 'BLOCK'
  AND year = '2026'
  AND month = '05'
GROUP BY httprequest.country
ORDER BY block_count DESC
LIMIT 30;


-- [쿼리 4] 시간대별 차단 추이 (Time series)
-- timestamp는 밀리초 단위 epoch → 시간대로 변환
SELECT
  date_trunc('hour',
    from_unixtime(timestamp / 1000)
  )                   AS block_hour,
  terminatingruleid   AS rule,
  COUNT(*)            AS cnt
FROM monitoring_db.waf_access_logs
WHERE action = 'BLOCK'
  AND year = '2026'
  AND month = '05'
GROUP BY 1, 2
ORDER BY block_hour;


-- [쿼리 5] 공격 IP 상위 10개 (Table 패널)
SELECT
  httprequest.clientip AS client_ip,
  httprequest.country  AS country,
  terminatingruleid    AS rule,
  COUNT(*)             AS hit_count
FROM monitoring_db.waf_access_logs
WHERE action = 'BLOCK'
  AND year = '2026'
  AND month = '05'
GROUP BY 1, 2, 3
ORDER BY hit_count DESC
LIMIT 10;

