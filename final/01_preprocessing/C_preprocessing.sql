-- =========================================================
-- C_비금융(금융권 미사용·신규) 전처리 SQL 재현 (MySQL 8.0 이상)
-- 기준 파일: model_C_nonfinancial_new_final.csv
--
-- 입력 : application_train (307,511행)
-- 출력 : model_C_final
-- 검산 : 307,511행 / 307,511 고유ID / 연체 24,825
--
-- ※※ 이 파일은 '정정본'이다 — 모델링에 쓰인 CSV와 컬럼 수가 다름 ※※
--   model_C_nonfinancial_new_final.csv (M1~M4 모델링에 실제 투입된 파일) = 15개 컬럼.
--   기준범주 2개(Secondary/secondary special · House/apartment)가 제거되지 않은 상태이며,
--   이는 EDA 단계에서 설계행렬 랭크 확인으로 뒤늦게 발견됐다.
--
--   아래 SQL은 그 누락을 바로잡은 버전이라 13개 컬럼을 만든다.
--   즉 SQL 재현 검증이 파이썬 전처리의 오류를 잡아낸 결과물이며,
--   파이썬 최종 CSV와 일치하지 않는 것이 정상이다.
--
--   [모델 결과에 미치는 영향]
--   M1~M4는 15개 버전으로 학습됐고 재실행하지 않았다.
--   완전공선은 트리 모델(LightGBM·XGBoost·RF) 적합에 영향이 없고 AUC도 흔들리지 않으며,
--   로지스틱 계수 해석에만 제약이 남는다. 본 연구는 계수 대신 AUC와 변수중요도를
--   해석 근거로 삼았으므로 결론은 유지된다. (PPT 슬라이드 10 참조)
--
--   [A·B군과의 차이]
--   A군·B군은 파이썬 결과와 완전히 일치한다. C군만 정정이 들어갔다.
--
-- ※ 컬럼명에 공백·슬래시가 있어 인용부호가 필요함.
--   MySQL 기본 모드에서는 큰따옴표가 식별자가 아니라 문자열이므로 백틱(`)을 사용한다.
--   (원문은 큰따옴표였음 — ANSI_QUOTES 모드가 아니면 파싱 오류)
-- =========================================================


-- ---------------------------------------------------------
-- [변수 구성] 총 13개 (기준범주 제외 기준)
--   차량보유    1 : FLAG_OWN_CAR (Y/N → 1/0)
--   사회연결망  3 : OBS_30, DEF_30, 결측 플래그
--   학력        4 : 원핫 5개 중 기준범주 1개 제외
--   주거        5 : 원핫 6개 중 기준범주 1개 제외
--
-- [생성하지 않는 변수]
--   CNT_CHILDREN      — 그룹기여도 음수
--   FLAG_CONT_MOBILE  — 99.81%가 동일값, 변별력 없음
-- ---------------------------------------------------------

DROP TABLE IF EXISTS model_C_final;

CREATE TABLE model_C_final AS
SELECT
    SK_ID_CURR,
    TARGET,

    -- 1. 차량보유
    CASE WHEN FLAG_OWN_CAR = 'Y' THEN 1 ELSE 0 END      AS FLAG_OWN_CAR,

    -- 2. 사회연결망 — 결측을 삭제하지 않고 0 대체 + 플래그로 보존
    --    OBS_30 / DEF_30 두 컬럼이 '동시에' 결측이므로 AND 로 판정 (1,021명)
    COALESCE(OBS_30_CNT_SOCIAL_CIRCLE, 0)               AS OBS_30_CNT_SOCIAL_CIRCLE,
    COALESCE(DEF_30_CNT_SOCIAL_CIRCLE, 0)               AS DEF_30_CNT_SOCIAL_CIRCLE,
    CASE WHEN OBS_30_CNT_SOCIAL_CIRCLE IS NULL
          AND DEF_30_CNT_SOCIAL_CIRCLE IS NULL
         THEN 1 ELSE 0 END                              AS SOCIAL_CIRCLE_MISSING_FLAG,

    -- 3. 학력 원핫 — 기준범주 'Secondary / secondary special'(218,391명) 제외
    --    최빈범주를 기준으로 삼아야 나머지 계수의 표준오차가 안정적.
    --    소수범주(예: Academic degree 164명)를 기준으로 쓰면 신뢰구간이 크게 벌어짐.
    --    빠진 범주는 절편에 흡수되므로 정보 손실이 아니며, 계수가 "고졸 대비"로 읽혀 해석이 명확해짐.
    CASE WHEN NAME_EDUCATION_TYPE = 'Academic degree'    THEN 1 ELSE 0 END
        AS `NAME_EDUCATION_TYPE_C_Academic degree`,
    CASE WHEN NAME_EDUCATION_TYPE = 'Higher education'   THEN 1 ELSE 0 END
        AS `NAME_EDUCATION_TYPE_C_Higher education`,
    CASE WHEN NAME_EDUCATION_TYPE = 'Incomplete higher'  THEN 1 ELSE 0 END
        AS `NAME_EDUCATION_TYPE_C_Incomplete higher`,
    CASE WHEN NAME_EDUCATION_TYPE = 'Lower secondary'    THEN 1 ELSE 0 END
        AS `NAME_EDUCATION_TYPE_C_Lower secondary`,
    -- 최종 CSV(15개)와 맞추려면 아래 줄을 켤 것 ↓
    -- CASE WHEN NAME_EDUCATION_TYPE = 'Secondary / secondary special' THEN 1 ELSE 0 END
    --     AS `NAME_EDUCATION_TYPE_C_Secondary / secondary special`,

    -- 4. 주거 원핫 — 기준범주 'House / apartment'(272,868명) 제외
    CASE WHEN NAME_HOUSING_TYPE = 'Co-op apartment'      THEN 1 ELSE 0 END
        AS `NAME_HOUSING_TYPE_C_Co-op apartment`,
    CASE WHEN NAME_HOUSING_TYPE = 'Municipal apartment'  THEN 1 ELSE 0 END
        AS `NAME_HOUSING_TYPE_C_Municipal apartment`,
    CASE WHEN NAME_HOUSING_TYPE = 'Office apartment'     THEN 1 ELSE 0 END
        AS `NAME_HOUSING_TYPE_C_Office apartment`,
    CASE WHEN NAME_HOUSING_TYPE = 'Rented apartment'     THEN 1 ELSE 0 END
        AS `NAME_HOUSING_TYPE_C_Rented apartment`,
    CASE WHEN NAME_HOUSING_TYPE = 'With parents'         THEN 1 ELSE 0 END
        AS `NAME_HOUSING_TYPE_C_With parents`
    -- 최종 CSV(15개)와 맞추려면 아래 줄을 켤 것 ↓
    -- ,CASE WHEN NAME_HOUSING_TYPE = 'House / apartment' THEN 1 ELSE 0 END
    --     AS `NAME_HOUSING_TYPE_C_House / apartment`

FROM application_train
ORDER BY SK_ID_CURR;


-- ---------------------------------------------------------
-- 검증
-- ---------------------------------------------------------

-- 4-1. 행 수 · ID · 타깃
SELECT COUNT(*)                   AS 행수,        -- 307,511
       COUNT(DISTINCT SK_ID_CURR) AS 고유ID,      -- 307,511
       SUM(TARGET)                AS 연체건수     -- 24,825
FROM model_C_final;

-- 4-2. 학력 원핫 행 합 — row_sum=0 인 행이 존재해야 정상 (전부 1이면 기준범주 누락)
SELECT (`NAME_EDUCATION_TYPE_C_Academic degree`
      + `NAME_EDUCATION_TYPE_C_Higher education`
      + `NAME_EDUCATION_TYPE_C_Incomplete higher`
      + `NAME_EDUCATION_TYPE_C_Lower secondary`)  AS row_sum,
       COUNT(*)                                   -- 0 → 218,391 / 1 → 89,120
FROM model_C_final
GROUP BY 1 ORDER BY 1;

-- 4-3. 주거 원핫 행 합
SELECT (`NAME_HOUSING_TYPE_C_Co-op apartment`
      + `NAME_HOUSING_TYPE_C_Municipal apartment`
      + `NAME_HOUSING_TYPE_C_Office apartment`
      + `NAME_HOUSING_TYPE_C_Rented apartment`
      + `NAME_HOUSING_TYPE_C_With parents`)       AS row_sum,
       COUNT(*)                                   -- 0 → 272,868 / 1 → 34,643
FROM model_C_final
GROUP BY 1 ORDER BY 1;

-- 4-4. 결측 플래그 인원
SELECT SUM(SOCIAL_CIRCLE_MISSING_FLAG) AS 결측인원 FROM model_C_final;   -- 1,021

-- 4-5. 잔여 결측 확인
SELECT COUNT(*) AS null_rows                                            -- 0
FROM model_C_final
WHERE FLAG_OWN_CAR IS NULL
   OR OBS_30_CNT_SOCIAL_CIRCLE IS NULL
   OR DEF_30_CNT_SOCIAL_CIRCLE IS NULL
   OR `NAME_EDUCATION_TYPE_C_Higher education` IS NULL
   OR `NAME_HOUSING_TYPE_C_With parents` IS NULL;
