-- =========================================================
-- B_비금융(기존 활용) 전처리 SQL 재현 (MySQL 8.0 이상)
-- 파이썬 전처리 결과를 SQL로 재현해 동일 결과가 나오는지 검증하는 스크립트.
-- 기준 파일: model_B_nonfinancial_final.csv
--
-- 입력 : application_train (307,511행)
-- 출력 : model_B_final  (SK_ID_CURR / TARGET 제외 32개 컬럼)
-- 검산 : 307,511행 / 307,511 고유ID / 연체 24,825
--
-- [최종 B군 32개]
--   연속·플래그 4개 : AGE, AGE_BAND(EDA 전용·모델 미투입), YEARS_EMPLOYED, DAYS_EMPLOYED_ANOM
--   OCCUPATION 원핫 18개 (기준 Laborers 제외)
--   INCOME 원핫      4개 (기준 Pensioner 제외)
--   ORGANIZATION 원핫 7개 (기준 XNA 제외)
--   → AGE_BAND를 빼면 모델 투입 31개 (PPT 슬라이드 7 기준과 일치)
--
-- ※ FLAG_OWN_REALTY_BIN은 재계산 최종본에 없어 제외함(제외 사유 미확인).
--    되살리려면 아래 주석 처리된 줄만 켜면 됨.
-- 팀 공통 구조: 1.결측 → 2.이상치(표시만) → 3.파생 → 4.로그(B군 해당없음) → 5.원핫 → 6.LEFT JOIN
-- =========================================================


-- ---------------------------------------------------------
-- [사전 검산] 이상치 마커 인원 → 55,374 나와야 함
-- DAYS_EMPLOYED = 365243 (약 1,000년) 은 오류가 아니라
-- '근로소득 없음'을 뜻하는 자리표시자. 전원이 연금수급자/미취업자.
-- ---------------------------------------------------------

SELECT COUNT(*) AS anom_expect_55374
FROM application_train
WHERE DAYS_EMPLOYED = 365243;


-- ---------------------------------------------------------
-- [전체 통합 쿼리] → model_B_final
-- ---------------------------------------------------------

DROP TABLE IF EXISTS model_B_final;

CREATE TABLE model_B_final AS
WITH base AS (   -- 1. 결측 채우기
    -- B군 실제 결측은 OCCUPATION_TYPE(31.35%)뿐.
    -- 삭제·대치 대신 'Unknown' 범주로 보존 — "직업 미기재"라는 상태 자체가 신호이기 때문.
    -- (Unknown 집단 연체율 6.51% vs 전체 평균 8.07%)
    SELECT
        SK_ID_CURR, TARGET,
        DAYS_BIRTH, DAYS_EMPLOYED,
        COALESCE(OCCUPATION_TYPE, 'Unknown') AS OCCUPATION_TYPE,
        NAME_INCOME_TYPE, ORGANIZATION_TYPE, FLAG_OWN_REALTY
    FROM application_train
),
derived AS (     -- 2. 이상치 표시 + 3. 파생 + 범주 통합
    SELECT
        SK_ID_CURR, TARGET,

        -- 3. 파생: 분모가 상수 365.25라 NULLIF 방어 불필요
        --    (NULLIF는 분모가 변수인 비율 파생 = A군 쪽에서만 필요)
        ROUND(-DAYS_BIRTH / 365.25, 2)                     AS AGE,
        FLOOR((-DAYS_BIRTH / 365.25) / 10) * 10            AS AGE_BAND,  -- EDA 전용, 모델 제외

        -- 2. 이상치: 삭제하지 않고 플래그로 분리, 근속연수는 0
        --    DAYS_EMPLOYED_ANOM=1 · ORGANIZATION_TYPE='XNA' · NAME_INCOME_TYPE='Pensioner'
        --    셋이 정확히 같은 55,374명을 가리키는 완전중복 →
        --    ANOM 하나만 남기고 XNA·Pensioner는 원핫 기준범주로 처리해 자연 제거
        CASE WHEN DAYS_EMPLOYED = 365243 THEN 1 ELSE 0 END AS DAYS_EMPLOYED_ANOM,
        CASE WHEN DAYS_EMPLOYED = 365243 THEN 0
             ELSE ROUND(-DAYS_EMPLOYED / 365.25, 2) END    AS YEARS_EMPLOYED,

        -- CASE WHEN FLAG_OWN_REALTY = 'Y' THEN 1 ELSE 0 END AS FLAG_OWN_REALTY_BIN,  -- 최종본 제외

        OCCUPATION_TYPE,

        -- 소득유형 희소범주 통합 (0.5% 미만: Unemployed 22 · Student 18 · Businessman 10 · Maternity leave 5)
        CASE WHEN NAME_INCOME_TYPE IN ('Working','Commercial associate','Pensioner','State servant')
             THEN NAME_INCOME_TYPE ELSE 'Other' END        AS INCOME_TYPE_G,

        -- 근무기관 58종 → 8종 접두어 그룹화
        -- 8그룹 합 = 307,511 확인함
        -- (Business Entity 84,529 / Self-employed 38,412 / Other 78,973 / Trade 14,315
        --  / Industry 14,311 / Medicine 11,193 / Government 10,404 / XNA 55,374)
        CASE
          WHEN ORGANIZATION_TYPE = 'XNA'                 THEN 'XNA'
          WHEN ORGANIZATION_TYPE LIKE 'Business Entity%' THEN 'Business Entity'
          WHEN ORGANIZATION_TYPE = 'Self-employed'       THEN 'Self-employed'
          WHEN ORGANIZATION_TYPE LIKE 'Trade:%'          THEN 'Trade'
          WHEN ORGANIZATION_TYPE LIKE 'Industry:%'       THEN 'Industry'
          WHEN ORGANIZATION_TYPE = 'Medicine'            THEN 'Medicine'
          WHEN ORGANIZATION_TYPE = 'Government'          THEN 'Government'
          ELSE 'Other'
        END                                              AS ORG_TYPE_G
    FROM base
)
-- 5. 원핫 인코딩 — 기준범주는 더미를 만들지 않음 (파이썬 drop_first 대응)
--    기준은 각 그룹 최대 집단. 원핫으로 쪼갠 변수는 개념그룹 단위로 통째로 다룸
--    (일부만 선택하면 기준범주가 모호해지고, 이 원칙이 뒤의 그룹기여도까지 이어짐)
SELECT
    SK_ID_CURR, TARGET,
    AGE, AGE_BAND, YEARS_EMPLOYED, DAYS_EMPLOYED_ANOM,

    -- OCCUPATION 원핫 (기준 Laborers 55,186 제외, 18개)
    CASE WHEN OCCUPATION_TYPE='Accountants'           THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Accountants`,
    CASE WHEN OCCUPATION_TYPE='Cleaning staff'        THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Cleaning staff`,
    CASE WHEN OCCUPATION_TYPE='Cooking staff'         THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Cooking staff`,
    CASE WHEN OCCUPATION_TYPE='Core staff'            THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Core staff`,
    CASE WHEN OCCUPATION_TYPE='Drivers'               THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Drivers`,
    CASE WHEN OCCUPATION_TYPE='HR staff'              THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_HR staff`,
    CASE WHEN OCCUPATION_TYPE='High skill tech staff' THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_High skill tech staff`,
    CASE WHEN OCCUPATION_TYPE='IT staff'              THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_IT staff`,
    CASE WHEN OCCUPATION_TYPE='Low-skill Laborers'    THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Low-skill Laborers`,
    CASE WHEN OCCUPATION_TYPE='Managers'              THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Managers`,
    CASE WHEN OCCUPATION_TYPE='Medicine staff'        THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Medicine staff`,
    CASE WHEN OCCUPATION_TYPE='Private service staff' THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Private service staff`,
    CASE WHEN OCCUPATION_TYPE='Realty agents'         THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Realty agents`,
    CASE WHEN OCCUPATION_TYPE='Sales staff'           THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Sales staff`,
    CASE WHEN OCCUPATION_TYPE='Secretaries'           THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Secretaries`,
    CASE WHEN OCCUPATION_TYPE='Security staff'        THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Security staff`,
    CASE WHEN OCCUPATION_TYPE='Unknown'               THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Unknown`,
    CASE WHEN OCCUPATION_TYPE='Waiters/barmen staff'  THEN 1 ELSE 0 END AS `OCCUPATION_TYPE_C_Waiters/barmen staff`,

    -- INCOME 원핫 (기준 Pensioner 55,362 제외, 4개)
    CASE WHEN INCOME_TYPE_G='Commercial associate'    THEN 1 ELSE 0 END AS `NAME_INCOME_TYPE_G_Commercial associate`,
    CASE WHEN INCOME_TYPE_G='Other'                   THEN 1 ELSE 0 END AS `NAME_INCOME_TYPE_G_Other`,
    CASE WHEN INCOME_TYPE_G='State servant'           THEN 1 ELSE 0 END AS `NAME_INCOME_TYPE_G_State servant`,
    CASE WHEN INCOME_TYPE_G='Working'                 THEN 1 ELSE 0 END AS `NAME_INCOME_TYPE_G_Working`,

    -- ORGANIZATION 원핫 (기준 XNA 55,374 제외, 7개)
    CASE WHEN ORG_TYPE_G='Business Entity'            THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Business Entity`,
    CASE WHEN ORG_TYPE_G='Government'                 THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Government`,
    CASE WHEN ORG_TYPE_G='Industry'                   THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Industry`,
    CASE WHEN ORG_TYPE_G='Medicine'                   THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Medicine`,
    CASE WHEN ORG_TYPE_G='Other'                      THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Other`,
    CASE WHEN ORG_TYPE_G='Self-employed'              THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Self-employed`,
    CASE WHEN ORG_TYPE_G='Trade'                      THEN 1 ELSE 0 END AS `ORGANIZATION_TYPE_G_Trade`
FROM derived;


-- ---------------------------------------------------------
-- 검산 — 파이썬 결과와 일치 확인
-- 세 검산이 다 맞으면 파이썬 전처리를 SQL로 정확히 재현한 것
-- ---------------------------------------------------------

-- 기본 검산
SELECT COUNT(*)                   AS n_rows,     -- 307,511
       COUNT(DISTINCT SK_ID_CURR) AS n_ids,      -- 307,511
       SUM(TARGET)                AS n_default   -- 24,825
FROM model_B_final;

-- 이상치 마커 인원 (다중공선성 근거)
SELECT SUM(DAYS_EMPLOYED_ANOM) AS anom_cnt FROM model_B_final;   -- 55,374

-- 더미 합계가 파이썬과 일치하는지 (샘플)
SELECT
  SUM(`OCCUPATION_TYPE_C_Unknown`)           AS occ_unknown,  -- 96,391
  SUM(`NAME_INCOME_TYPE_G_Working`)          AS inc_working,  -- 158,774
  SUM(`ORGANIZATION_TYPE_G_Business Entity`) AS org_be        -- 84,529
FROM model_B_final;
