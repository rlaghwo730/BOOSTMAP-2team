-- =========================================================
-- bureau.csv 고속 적재용 스크립트 (LOAD DATA INFILE)
-- =========================================================

DROP TABLE IF EXISTS bureau;

CREATE TABLE bureau (
  `SK_ID_CURR` BIGINT,
  `SK_ID_BUREAU` BIGINT,
  `CREDIT_ACTIVE` VARCHAR(30),
  `CREDIT_CURRENCY` VARCHAR(30),
  `DAYS_CREDIT` BIGINT,
  `CREDIT_DAY_OVERDUE` BIGINT,
  `DAYS_CREDIT_ENDDATE` DOUBLE,
  `DAYS_ENDDATE_FACT` DOUBLE,
  `AMT_CREDIT_MAX_OVERDUE` DOUBLE,
  `CNT_CREDIT_PROLONG` BIGINT,
  `AMT_CREDIT_SUM` DOUBLE,
  `AMT_CREDIT_SUM_DEBT` DOUBLE,
  `AMT_CREDIT_SUM_LIMIT` DOUBLE,
  `AMT_CREDIT_SUM_OVERDUE` DOUBLE,
  `CREDIT_TYPE` VARCHAR(60),
  `DAYS_CREDIT_UPDATE` BIGINT,
  `AMT_ANNUITY` DOUBLE
);

-- 아래 경로를 실제 bureau.csv 위치로 맞춰주세요 (역슬래시 대신 슬래시 사용)
LOAD DATA LOCAL INFILE 'C:/Users/user/test_2026/credit_scoring/bureau.csv'
INTO TABLE bureau
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- 검증 (Kaggle 원본 기준 1,716,428행이 정상)
SELECT COUNT(*) FROM bureau;
