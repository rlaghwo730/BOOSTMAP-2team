-- =========================================================
-- A · B · C 통합 + 최종 검산 (MySQL 8.0 이상)
-- 선행: 01_financial_preprocessing.sql → model_A_final
--       02_nonfinancial_b_preprocessing.sql → model_B_final
--       03_nonfinancial_c_preprocessing.sql → model_C_final
--
-- 공통 검산값 (PPT 슬라이드 10) : 307,511 / 307,511 / 24,825
-- =========================================================


-- ---------------------------------------------------------
-- [통합] SK_ID_CURR 기준 LEFT JOIN
-- B·C군은 전 행을 보존하므로 키 손실 없음.
-- AGE_BAND는 EDA 전용이라 모델 투입 데이터에서는 제외.
-- ---------------------------------------------------------

DROP TABLE IF EXISTS model_dataset_final;

CREATE TABLE model_dataset_final AS
SELECT a.*, b.*, c.*
FROM model_A_final a
LEFT JOIN model_B_final b USING (SK_ID_CURR, TARGET)
LEFT JOIN model_C_final c USING (SK_ID_CURR, TARGET);

ALTER TABLE model_dataset_final DROP COLUMN AGE_BAND;


-- ---------------------------------------------------------
-- [검산 1] 세 군 각각 + 통합본 — 전부 307,511 / 307,511 / 24,825
-- ---------------------------------------------------------

SELECT 'A' AS 군, COUNT(*) AS 행수, COUNT(DISTINCT SK_ID_CURR) AS 고유ID, SUM(TARGET) AS 연체
FROM model_A_final
UNION ALL
SELECT 'B', COUNT(*), COUNT(DISTINCT SK_ID_CURR), SUM(TARGET) FROM model_B_final
UNION ALL
SELECT 'C', COUNT(*), COUNT(DISTINCT SK_ID_CURR), SUM(TARGET) FROM model_C_final
UNION ALL
SELECT '통합', COUNT(*), COUNT(DISTINCT SK_ID_CURR), SUM(TARGET) FROM model_dataset_final;


-- ---------------------------------------------------------
-- [검산 2] JOIN 손실 확인 — 셋 다 0이어야 정상
-- ---------------------------------------------------------

SELECT
  (SELECT COUNT(*) FROM model_dataset_final WHERE AGE IS NULL)          AS b군_미결합,
  (SELECT COUNT(*) FROM model_dataset_final WHERE FLAG_OWN_CAR IS NULL) AS c군_미결합,
  (SELECT COUNT(*) FROM model_A_final) - (SELECT COUNT(*) FROM model_dataset_final) AS 행수_차이;


-- ---------------------------------------------------------
-- [검산 3] 씬파일러 — LEFT JOIN을 쓴 이유 (PPT 슬라이드 6)
-- INNER JOIN이었다면 bureau 기록 없는 44,020명이 표본에서 사라졌을 것.
-- 이들의 연체율이 신용이력 보유 집단보다 높다는 것이 본 연구의 출발점.
-- ---------------------------------------------------------

SELECT
    BUREAU_NO_HISTORY_FLAG                       AS 씬파일러여부,
    COUNT(*)                                     AS 인원,          -- 1 → 44,020
    ROUND(AVG(TARGET) * 100, 2)                  AS 연체율_퍼센트  -- 1 → 10.12 / 0 → 7.73
FROM model_dataset_final
GROUP BY BUREAU_NO_HISTORY_FLAG;


-- ---------------------------------------------------------
-- [검산 4] 연령대별 부도율 (PPT 슬라이드 23 표와 대조)
-- 20대 45,137 / 11.45%   30대 82,367 / 9.59%   40대 76,581 / 7.64%
-- 50대 68,100 /  6.12%   60대+ 35,326 / 4.92%
-- ---------------------------------------------------------

SELECT
    CASE WHEN AGE >= 60 THEN '60대+'
         ELSE CONCAT(FLOOR(AGE / 10) * 10, '대') END AS 연령대,
    COUNT(*)                    AS 표본수,
    ROUND(AVG(TARGET) * 100, 2) AS 부도율_퍼센트
FROM model_dataset_final
GROUP BY 1
ORDER BY 1;
