IF OBJECT_ID(N'DBO.usp_LoyaltyCohort_opt') IS NOT NULL DROP PROCEDURE DBO.usp_LoyaltyCohort_opt
GO

CREATE PROC DBO.usp_LoyaltyCohort_opt
     @indexDate datetime
    ,@site varchar(10) 
    ,@lookbackYears int = 1 /* DEFAULT TO 1 YEAR */
    ,@gendered bit = 0 /* DEFAULT TO NON GENDER VERSION */
    ,@output bit = 1 /* DEFAULT TO SHOW FINAL OUTPUT */
AS

/* 
   CHECK ANY CUSTOM LOCAL CODES ADDED TO xref_LoyaltyCode_paths AT <PE.1> AND <PE.2> - PLEASE SEE COMMENTS
*/

SET NOCOUNT ON
SET XACT_ABORT ON

/* UNCOMMENT IF TESTING PROC BODY ALONE */
--DECLARE @indexDate DATE='20210201'
--DECLARE @site VARCHAR(10) = '' /* ALTER TO YOUR DESIRED SITE CODE */
--DECLARE @lookbackYears INT = 1
--DECLARE @gendered BIT = 0
--DECLARE @output BIT = 1

/* create the target summary table if not exists */
IF OBJECT_ID(N'dbo.loyalty_dev_summary', N'U') IS NULL
  CREATE TABLE dbo.[loyalty_dev_summary](
    [SITE] VARCHAR(10) NOT NULL,
    [GENDER_DENOMINATORS_YN] char(1) NOT NULL,
    [CUTOFF_FILTER_YN] char(1) NOT NULL,
	  [Summary_Description] varchar(20) NOT NULL,
	  [tablename] [varchar](20) NULL,
	  [Num_DX1] float NULL,
	  [Num_DX2] float NULL,
	  [MedUse1] float NULL,
	  [MedUse2] float NULL,
	  [Mammography] float NULL,
	  [PapTest] float NULL,
	  [PSATest] float NULL,
	  [Colonoscopy] float NULL,
	  [FecalOccultTest] float NULL,
	  [FluShot] float NULL,
	  [PneumococcalVaccine] float NULL,
	  [BMI] float NULL,
	  [A1C] float NULL,
	  [MedicalExam] float NULL,
	  [INP1_OPT1_Visit] float NULL,
	  [OPT2_Visit] float NULL,
	  [ED_Visit] float NULL,
	  [MDVisit_pname2] float NULL,
	  [MDVisit_pname3] float NULL,
	  [Routine_care_2] float NULL,
	  [Subjects_NoCriteria] float NULL,
	  [PredictiveScoreCutoff] float NULL,
	  [MEAN_10YRPROB] float NULL,
	  [MEDIAN_10YR_SURVIVAL] float NULL,
	  [MODE_10YRPROB] float NULL,
	  [STDEV_10YRPROB] float NULL,
    [TotalSubjects] int NULL,
    [TotalSubjectsFemale] int NULL,
    [TotalSubjectsMale] int NULL,
    [EXTRACT_DTTM] DATETIME NOT NULL DEFAULT GETDATE(),
    [LOOKBACK_YR] INT NOT NULL,
    [RUNTIMEms] int NULL
  )

/* ENSURE TEMP IS CLEAR FROM PREVIOUS RUNS */
IF OBJECT_ID(N'tempdb..#DEMCONCEPT', N'U') IS NOT NULL DROP TABLE #DEMCONCEPT;
IF OBJECT_ID(N'tempdb..#INCLPAT', N'U') IS NOT NULL DROP TABLE #INCLPAT;
IF OBJECT_ID(N'tempdb..#NUM_DX_CODES', N'U') IS NOT NULL DROP TABLE #NUM_DX_CODES;
IF OBJECT_ID(N'tempdb..#MEDUSE_CODES', N'U') IS NOT NULL DROP TABLE #MEDUSE_CODES;
IF OBJECT_ID(N'tempdb..#VARIABLE_EXPANSION', N'U') IS NOT NULL DROP TABLE #VARIABLE_EXPANSION;
IF OBJECT_ID(N'tempdb..#cohort', N'U') IS NOT NULL DROP TABLE #cohort;
IF OBJECT_ID(N'tempdb..#COHORT_FLAGS_PSC', N'U') IS NOT NULL DROP TABLE #COHORT_FLAGS_PSC;
IF OBJECT_ID(N'tempdb..#cohort_agegrp', N'U') IS NOT NULL DROP TABLE #cohort_agegrp;
IF OBJECT_ID(N'tempdb..#AGEGRP_PSC', N'U') IS NOT NULL DROP TABLE #AGEGRP_PSC;
IF OBJECT_ID(N'tempdb..#CHARLSON_VISIT_BASE', N'U') IS NOT NULL DROP TABLE #CHARLSON_VISIT_BASE;
IF OBJECT_ID(N'tempdb..#CHARLSON_DX', N'U') IS NOT NULL DROP TABLE #CHARLSON_DX;
IF OBJECT_ID(N'tempdb..#COHORT_CHARLSON', N'U') IS NOT NULL DROP TABLE #COHORT_CHARLSON;
IF OBJECT_ID(N'tempdb..#CHARLSON_STATS', N'U') IS NOT NULL DROP TABLE #CHARLSON_STATS;

DECLARE @STARTTS DATETIME = GETDATE()
DECLARE @STEPTTS DATETIME 
DECLARE @ENDRUNTIMEms INT, @STEPRUNTIMEms INT
DECLARE @ROWS INT

/* PRE-BUILD AN PATIENT INCLUSION TABLE FOR `HAVING A NON-DEMOGRAPHIC FACT AFTER 20120101` */

RAISERROR(N'Starting #INCLPAT phase.', 1, 1) with nowait;

/* EXTRACT DEMOGRAPHIC CONCEPTS */
SELECT DISTINCT CONCEPT_CD
  , SUBSTRING(CONCEPT_CD,1,CHARINDEX(':',CONCEPT_CD)-1) AS CONCEPT_PREFIX 
INTO #DEMCONCEPT
FROM CONCEPT_DIMENSION
WHERE CONCEPT_PATH LIKE '\ACT\Demographics%'
  AND CONCEPT_CD != ''

/* include only patients with non-demographic concepts after 20120101 */
SET @STEPTTS = GETDATE()

SELECT DISTINCT PATIENT_NUM
/* distinct list of patients left over from except operation would be patient-concept_cd key pairs for any other fact type */
INTO #INCLPAT
FROM (
/* all patient-concept_cd key pairs between 2012 and index */
SELECT F.PATIENT_NUM, F.CONCEPT_CD
FROM DBO.OBSERVATION_FACT F
WHERE F.START_DATE >= CAST('20120101' AS DATETIME) AND F.START_DATE < @indexDate
EXCEPT
/* exclude patient-concept_cd demographic pairs */
SELECT PATIENT_NUM, F.CONCEPT_CD
FROM DBO.OBSERVATION_FACT F
  JOIN #DEMCONCEPT D
    ON F.CONCEPT_CD = D.CONCEPT_CD
WHERE F.START_DATE >= CAST('20120101' AS DATETIME) AND F.START_DATE < @indexDate
)OFMINUSDEM

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Build #INCLPAT - Rows: %d - Total Execution (ms): %d - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* FINISH PRE-BUILD ACT MODEL */

CREATE TABLE #cohort (
patient_num INT NOT NULL PRIMARY KEY,
sex varchar(50) null,
age int null,
Num_Dx1 bit not null DEFAULT 0,
Num_Dx2 bit not null DEFAULT 0,
MedUse1 bit not null DEFAULT 0,
MedUse2 bit not null DEFAULT 0,
Mammography bit not null DEFAULT 0,
PapTest bit not null DEFAULT 0,
PSATest bit not null DEFAULT 0,
Colonoscopy bit not null DEFAULT 0,
FecalOccultTest bit not null DEFAULT 0,
FluShot bit not null DEFAULT 0,
PneumococcalVaccine bit not null DEFAULT 0,
BMI bit not null DEFAULT 0,
A1C bit not null DEFAULT 0,
MedicalExam bit not null DEFAULT 0,
INP1_OPT1_Visit bit not null DEFAULT 0,
OPT2_Visit bit not null DEFAULT 0,
ED_Visit bit not null DEFAULT 0,
MDVisit_pname2 bit not null DEFAULT 0,
MDVisit_pname3 bit not null DEFAULT 0,
Routine_Care_2 bit not null DEFAULT 0,
Predicted_score FLOAT not null DEFAULT 0,
LAST_VISIT DATE NULL
)

/* EXTRACT COHORT AND VISIT TYPE FLAGS */
SET @STEPTTS = GETDATE()

INSERT INTO #COHORT (PATIENT_NUM, INP1_OPT1_Visit, OPT2_Visit, ED_Visit, LAST_VISIT)
SELECT V.PATIENT_NUM
  , CAST(SUM(CASE WHEN V.START_DATE >= DATEADD(YY,-@lookbackYears,@indexDate) AND (V.INOUT_CD IN ('I','O')) THEN 1 ELSE 0 END) AS BIT) INP1_OPT1_VISIT
  , CASE WHEN (COUNT(DISTINCT CASE WHEN V.START_DATE >= DATEADD(YY,-@lookbackYears,@indexDate) AND (V.INOUT_CD IN ('X','O')) THEN CONVERT(DATE,V.START_DATE) ELSE NULL END)) >= 2 THEN 1 ELSE 0 END AS OPT2_VISIT
  , MAX(CASE WHEN V.START_DATE >= DATEADD(YY,-@lookbackYears,@indexDate) AND (V.INOUT_CD IN ('E','EI')) THEN 1 ELSE 0 END) AS ED_VISIT
  , MAX(V.START_DATE)
FROM VISIT_DIMENSION V
  JOIN #INCLPAT P ON V.PATIENT_NUM = P.PATIENT_NUM
WHERE V.START_DATE >= CAST('20120101' AS DATETIME) AND V.START_DATE < @indexDate
GROUP BY V.PATIENT_NUM

UPDATE #COHORT
SET SEX = REPLACE(P.SEX_CD,'DEM|SEX:','')
  , AGE = FLOOR(DATEDIFF(DD,P.BIRTH_DATE,@indexDate)/365.25)
FROM #COHORT C, PATIENT_DIMENSION P
WHERE C.PATIENT_NUM = P.PATIENT_NUM

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Cohort and Visit Type variables - Rows: %d - Total Execution (ms): %d - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* HAVE TO CENSOR BAD BIRTH_DATE DATA FOR AGEGRP STEPS LATER */
DELETE FROM #COHORT WHERE AGE IS NULL

SELECT @ROWS=@@ROWCOUNT

IF @ROWS > 0
  RAISERROR(N'Dropping patients with null birth_date - Rows: %d', 1, 1, @ROWS) with nowait;

/* NEW COHORT FLAGS PSC BLOCK */
SET @STEPTTS = GETDATE()

SELECT DISTINCT 'Num_DX' as Feature_name, concept_cd
into #NUM_DX_CODES
from (
Select concept_cd
from ACT_ICD10CM_DX_2018AA d, concept_dimension c
where d.C_FULLNAME = C.CONCEPT_PATH
  and (c_basecode is not null and c_basecode <> '')
UNION ALL
Select concept_cd 
from ACT_ICD9CM_DX_2018AA d, concept_dimension c
where d.C_FULLNAME = C.CONCEPT_PATH
  and (c_basecode is not null and c_basecode <> '')
UNION ALL
/* <PE.2> Check that this subquery returns the concept codes your site added to 
  xref_LoyaltyCode_paths are returned correctly */
Select c.concept_cd
from CONCEPT_DIMENSION c, DBO.xref_LoyaltyCode_paths x 
where c.CONCEPT_PATH LIKE x.ACT_PATH+'%'  ----- > This block of code handles any local dx codes
  and (NULLIF(c.CONCEPT_CD,'') is not null)
  and (NULLIF(x.SiteSpecificCode,'') is not null)
  and x.[code_type] = 'DX'
)DX

SELECT DISTINCT 'MedUse' as Feature_name, concept_cd
INTO #MEDUSE_CODES
from (
Select c_basecode as CONCEPT_CD
from ACT_MED_VA_V2_092818
where c_basecode is not null and c_basecode  <> ''
UNION ALL
select c_basecode as CONCEPT_CD 
from ACT_MED_ALPHA_V2_121318
where c_basecode is not null and c_basecode <> ''
)MU

SELECT FEATURE_NAME, VARIABLE_NAME, THRESHOLD
INTO #VARIABLE_EXPANSION
FROM (
SELECT 'Num_DX' as FEATURE_NAME, 'Num_DX1' as VARIABLE_NAME, 1 AS THRESHOLD UNION ALL
SELECT 'Num_DX' as FEATURE_NAME, 'Num_DX2' as VARIABLE_NAME, 2 AS THRESHOLD UNION ALL
SELECT 'MedUse' as FEATURE_NAME, 'MedUse1' as VARIABLE_NAME, 1 AS THRESHOLD UNION ALL
SELECT 'MedUse' as FEATURE_NAME, 'MedUse2' as VARIABLE_NAME, 2 AS THRESHOLD 
)VE

SET @STEPTTS = GETDATE()

;WITH CTE_PARAMS AS (
select distinct Feature_name, concept_cd, code_type --[ACT_PATH], 
from DBO.xref_LoyaltyCode_paths L, CONCEPT_DIMENSION c
where C.CONCEPT_PATH like L.Act_path+'%'  --jgk: must support local children
AND code_type IN ('DX','PX','lab','SITE') /* <PE.1> IF YOUR SITE IS MANAGING ANY SITE SPECIFIC CODES FOR THE FOLLOWING DOMAINS SET THEIR CODE_TYPE = 'SITE' IN dbo.xref_LoyaltyCode_paths </PE.1> */
and (act_path <> '**Not Found' and act_path is not null)
UNION 
SELECT FEATURE_NAME, CONCEPT_CD, 'DX' AS CODE_TYPE FROM #NUM_DX_CODES
UNION 
SELECT FEATURE_NAME, CONCEPT_CD, 'DRUG' AS CODE_TYPE FROM #MEDUSE_CODES
) 
, CTE_FEATURE_OCCUR AS (
SELECT PATIENT_NUM
  , CASE  WHEN Feature_name = 'MD visit' AND OCCUR = 2 THEN 'MDVisit_pname2'
          WHEN Feature_name = 'MD visit' AND OCCUR > 2 THEN 'MDVisit_pname3'
          ELSE Feature_name END as Feature_name
  , CASE  WHEN Feature_name = 'MD visit' AND OCCUR = 2 THEN 1
          WHEN Feature_name = 'MD visit' AND OCCUR > 2 THEN 1
          ELSE OCCUR END as OCCUR
FROM (
SELECT DISTINCT O.PATIENT_NUM, P.[FEATURE_NAME]
  , CASE /*WHEN FEATURE_NAME = 'MD visit' THEN COUNT(DISTINCT CHECKSUM(CONVERT(DATE,O.START_DATE),PROVIDER_ID))*/
         WHEN FEATURE_NAME IN ('MD visit','Num_DX','Meduse') THEN COUNT(DISTINCT CONVERT(DATE,O.START_DATE))
         ELSE COUNT(*) END OCCUR
FROM OBSERVATION_FACT o, CTE_PARAMS p
where o.CONCEPT_CD = p.CONCEPT_CD
AND O.START_DATE >=  dateadd(yy,-@lookbackYears,@indexDate)
AND O.START_DATE < @indexDate
AND O.PATIENT_NUM IN (SELECT PATIENT_NUM FROM #COHORT)
GROUP BY O.PATIENT_NUM, P.[FEATURE_NAME]
) FOMV
)
, CTE_PSC AS (
SELECT VE.PATIENT_NUM, VE.VARIABLE_NAME, VE.OCCUR
  , PSC.COEFF
  , -0.010+SUM(PSC.COEFF) OVER (PARTITION BY VE.PATIENT_NUM ORDER BY (SELECT 1)) Predicted_Score
FROM (
  SELECT FO.PATIENT_NUM, COALESCE(VE.VARIABLE_NAME,FO.Feature_name) AS VARIABLE_NAME,  IIF(FO.OCCUR>0,1,0) OCCUR
  FROM CTE_FEATURE_OCCUR FO
    LEFT JOIN #VARIABLE_EXPANSION VE
      ON FO.FEATURE_NAME = VE.FEATURE_NAME
      AND FO.OCCUR >= VE.THRESHOLD
  UNION ALL
  SELECT PATIENT_NUM, 'Routine_Care_2' as VARIABLE_NAME, SUM(IIF(FO.OCCUR>0,1,0)) OCCUR
  FROM CTE_FEATURE_OCCUR FO
  WHERE Feature_name IN ('MedicalExam','Mammography','PSATest','Colonoscopy','FecalOccultTest','FluShot','PneumococcalVaccine','A1C','BMI')
  GROUP BY PATIENT_NUM
  HAVING SUM(IIF(FO.OCCUR>0,1,0)) >= 2
  UNION ALL
  SELECT PATIENT_NUM, 'INP1_OPT1_Visit' AS VARIABLE_NAME, INP1_OPT1_VISIT FROM #COHORT WHERE INP1_OPT1_VISIT != 0
  UNION ALL
  SELECT PATIENT_NUM, 'OPT2_Visit' AS VARIABLE_NAME, OPT2_Visit FROM #COHORT WHERE OPT2_Visit != 0
  UNION ALL
  SELECT PATIENT_NUM, 'ED_Visit' AS VARIABLE_NAME, ED_Visit FROM #COHORT WHERE ED_Visit != 0
)VE JOIN dbo.xref_LoyaltyCode_PSCoeff PSC
  on VE.VARIABLE_NAME = PSC.FIELD_NAME
)
SELECT PATIENT_NUM,
MAX(SEX) AS SEX,
MAX(AGE) AS AGE,
MAX([Num_DX1]) AS [Num_DX1],
MAX([Num_DX2]) AS [Num_DX2],
MAX([MedUse1]) AS [MedUse1],
MAX([MedUse2]) AS [MedUse2],
MAX([Mammography]) AS [Mammography],
MAX([PapTest]) AS [PapTest],
MAX([PSATest]) AS [PSATest],
MAX([Colonoscopy]) AS [Colonoscopy],
MAX(FecalOccultTest) AS FecalOccultTest,
MAX([FluShot]) AS [FluShot],
MAX([PneumococcalVaccine]) AS [PneumococcalVaccine],
MAX([BMI]) AS [BMI],
MAX([A1C]) AS [A1C],
MAX([MedicalExam]) AS [MedicalExam],
MAX([INP1_OPT1_Visit]) AS [INP1_OPT1_Visit],
MAX([OPT2_Visit]) AS [OPT2_Visit],
MAX([ED_Visit]) AS [ED_Visit],
MAX([MDVisit_pname2]) AS [MDVisit_pname2],
MAX([MDVisit_pname3]) AS [MDVisit_pname3],
MAX([Routine_Care_2]) AS [Routine_Care_2],
MAX([Predicted_Score]) AS [Predicted_Score],
MAX(LAST_VISIT) AS LAST_VISIT
INTO #COHORT_FLAGS_PSC
FROM (
SELECT PATIENT_NUM, SEX, AGE, [Num_DX1], [Num_DX2], [MedUse1], [MedUse2], [Mammography], [PapTest], [PSATest], [Colonoscopy], FecalOccultTest, [FluShot], [PneumococcalVaccine]
  , [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit], [MDVisit_pname2], [MDVisit_pname3]
  , [Routine_Care_2]
  , Predicted_Score
  , LAST_VISIT
FROM #COHORT 
UNION ALL 
SELECT PATIENT_NUM, NULL AS SEX, NULL AS AGE
  , [Num_DX1], [Num_DX2], [MedUse1], [MedUse2], [Mammography], [PapTest], [PSATest], [Colonoscopy], FecalOccultTest, [FluShot], [PneumococcalVaccine]
  , [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit], [MDVisit_pname2], [MDVisit_pname3]
  , [Routine_Care_2], Predicted_Score
  , NULL AS LAST_VISIT
FROM (
SELECT * 
FROM CTE_PSC
)U
PIVOT
(MAX(OCCUR) FOR VARIABLE_NAME IN ([Num_DX1], [Num_DX2], [MedUse1], [MedUse2], [Mammography], [PapTest], [PSATest], [Colonoscopy], [FecalOccultTest], [FluShot], [PneumococcalVaccine]
, [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit], [MDVisit_pname2], [MDVisit_pname3],[Routine_Care_2]))P
)COHORT_FLAGS
GROUP BY PATIENT_NUM

TRUNCATE TABLE #COHORT

INSERT INTO #COHORT (PATIENT_NUM, SEX, AGE, [Num_DX1], [Num_DX2], [MedUse1], [MedUse2], [Mammography], [PapTest], [PSATest], [Colonoscopy], FecalOccultTest, [FluShot], [PneumococcalVaccine], [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit], [MDVisit_pname2], [MDVisit_pname3] , Routine_Care_2 , Predicted_Score , LAST_VISIT)
SELECT PATIENT_NUM, SEX, AGE, [Num_DX1], [Num_DX2], [MedUse1], [MedUse2], [Mammography], [PapTest], [PSATest], [Colonoscopy], FecalOccultTest, [FluShot], [PneumococcalVaccine], [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit], [MDVisit_pname2], [MDVisit_pname3]
  , Routine_Care_2, Predicted_Score, LAST_VISIT
FROM #COHORT_FLAGS_PSC

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Cohort Flags - Rows: %d - Total Execution (ms): %d  - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* Cohort Agegrp - Makes Predictive Score filtering easier in final step if pre-calculated */
SET @STEPTTS = GETDATE()

SELECT * 
INTO #cohort_agegrp
FROM (
select patient_num
,sex
,CAST(case when ISNULL(AGE,0)< 65 then 'Under 65' 
     when AGE>=65 then 'Over 65' else null end AS VARCHAR(20)) as AGEGRP
,Num_Dx1              AS Num_Dx1            
,Num_Dx2              AS Num_Dx2            
,MedUse1              AS MedUse1            
,MedUse2              AS MedUse2            
,Mammography          AS Mammography        
,PapTest              AS PapTest            
,PSATest              AS PSATest            
,Colonoscopy          AS Colonoscopy        
,FecalOccultTest      AS FecalOccultTest    
,FluShot              AS FluShot            
,PneumococcalVaccine  AS PneumococcalVaccine
,BMI                  AS BMI                
,A1C                  AS A1C                
,MedicalExam          AS MedicalExam        
,INP1_OPT1_Visit      AS INP1_OPT1_Visit    
,OPT2_Visit           AS OPT2_Visit         
,ED_Visit             AS ED_Visit           
,MDVisit_pname2       AS MDVisit_pname2     
,MDVisit_pname3       AS MDVisit_pname3     
,Routine_Care_2       AS Routine_Care_2     
,Predicted_score      AS Predicted_score
from #cohort
UNION 
select patient_num
,sex
,'All Patients' AS AGEGRP
,Num_Dx1              AS Num_Dx1            
,Num_Dx2              AS Num_Dx2            
,MedUse1              AS MedUse1            
,MedUse2              AS MedUse2            
,Mammography          AS Mammography        
,PapTest              AS PapTest            
,PSATest              AS PSATest            
,Colonoscopy          AS Colonoscopy        
,FecalOccultTest      AS FecalOccultTest    
,FluShot              AS FluShot            
,PneumococcalVaccine  AS PneumococcalVaccine
,BMI                  AS BMI                
,A1C                  AS A1C                
,MedicalExam          AS MedicalExam        
,INP1_OPT1_Visit      AS INP1_OPT1_Visit    
,OPT2_Visit           AS OPT2_Visit         
,ED_Visit             AS ED_Visit           
,MDVisit_pname2       AS MDVisit_pname2     
,MDVisit_pname3       AS MDVisit_pname3     
,Routine_Care_2       AS Routine_Care_2     
,Predicted_score      AS Predicted_score
from #cohort
)cag;

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Prepare #cohort_agegrp - Rows: %d - Total Execution (ms): %d  - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* Calculate Predictive Score Cutoff by over Agegroups */
SET @STEPTTS = GETDATE()

SELECT AGEGRP, MIN(PREDICTED_SCORE) PredictiveScoreCutoff
INTO #AGEGRP_PSC
FROM (
SELECT AGEGRP, Predicted_score, NTILE(5) OVER (PARTITION BY AGEGRP ORDER BY PREDICTED_SCORE DESC) AS ScoreRank
FROM(
SELECT AGEGRP, predicted_score
from #cohort_agegrp
)SCORES
)M
WHERE ScoreRank=1
GROUP BY AGEGRP

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Prepare #AGEGRP_PSC - Rows: %d - Total Execution (ms): %d  - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* OPTIONAL CHARLSON COMORBIDITY INDEX -- ADDS APPROX. 1m in UKY environment. 
   REQUIRES SITE TO LOAD LU_CHARLSON FROM REPO 
*/
SET @STEPTTS = GETDATE()

SELECT DISTINCT CHARLSON_CATGRY, CHARLSON_WT, C_BASECODE AS CONCEPT_CD
INTO #CHARLSON_DX
FROM (
SELECT C.CHARLSON_CATGRY, C.CHARLSON_WT, DX10.C_BASECODE
FROM LU_CHARLSON C
  JOIN ACT_ICD10CM_DX_V4 DX10
    ON DX10.C_BASECODE LIKE C.DIAGPATTERN
UNION ALL
SELECT C.CHARLSON_CATGRY, C.CHARLSON_WT, DX9.C_BASECODE
FROM LU_CHARLSON C
  JOIN ACT_ICD9CM_DX_V4 DX9
    ON DX9.C_BASECODE LIKE C.DIAGPATTERN
)C

;WITH CTE_VISIT_BASE AS (
SELECT PATIENT_NUM, AGE, LAST_VISIT
  , CASE  WHEN AGE < 50 THEN 0
          WHEN AGE BETWEEN 50 AND 59 THEN 1
          WHEN AGE BETWEEN 60 AND 69 THEN 2
          WHEN AGE >= 70 THEN 3 END AS CHARLSON_AGE_BASE
FROM (
SELECT V.PATIENT_NUM
  , V.AGE
  , LAST_VISIT
FROM #COHORT V 
) VISITS
)
SELECT PATIENT_NUM, AGE, LAST_VISIT, CHARLSON_AGE_BASE
INTO #CHARLSON_VISIT_BASE
FROM CTE_VISIT_BASE

SELECT PATIENT_NUM
  , LAST_VISIT
  , AGE
  , CAST(case when AGE < 65 then 'Under 65' 
     when age>=65           then 'Over 65' else '-' end AS VARCHAR(20)) AS AGEGRP
  , CHARLSON_INDEX
  , POWER( 0.983
      , POWER(2.71828, (CASE WHEN CHARLSON_INDEX > 7 THEN 7 ELSE CHARLSON_INDEX END) * 0.9)
      ) * 100.0 AS CHARLSON_10YR_SURVIVAL_PROB
  , MI, CHF, CVD, PVD, DEMENTIA, COPD, RHEUMDIS, PEPULCER, MILDLIVDIS, DIABETES_NOCC, DIABETES_WTCC, HEMIPARAPLEG, RENALDIS, CANCER, MSVLIVDIS, METASTATIC, AIDSHIV
INTO #COHORT_CHARLSON
FROM (
SELECT PATIENT_NUM, LAST_VISIT, AGE
  , CHARLSON_AGE_BASE
      + MI + CHF + CVD + PVD + DEMENTIA + COPD + RHEUMDIS + PEPULCER 
      + (CASE WHEN MSVLIVDIS > 0 THEN 0 ELSE MILDLIVDIS END)
      + (CASE WHEN DIABETES_WTCC > 0 THEN 0 ELSE DIABETES_NOCC END)
      + DIABETES_WTCC + HEMIPARAPLEG + RENALDIS + CANCER + MSVLIVDIS + METASTATIC + AIDSHIV AS CHARLSON_INDEX
  , MI, CHF, CVD, PVD, DEMENTIA, COPD, RHEUMDIS, PEPULCER, MILDLIVDIS, DIABETES_NOCC, DIABETES_WTCC, HEMIPARAPLEG, RENALDIS, CANCER, MSVLIVDIS, METASTATIC, AIDSHIV
FROM (
SELECT PATIENT_NUM, AGE, LAST_VISIT, CHARLSON_AGE_BASE
  , MAX(CASE WHEN CHARLSON_CATGRY = 'MI'            THEN CHARLSON_WT ELSE 0 END) AS MI
  , MAX(CASE WHEN CHARLSON_CATGRY = 'CHF'           THEN CHARLSON_WT ELSE 0 END) AS CHF
  , MAX(CASE WHEN CHARLSON_CATGRY = 'CVD'           THEN CHARLSON_WT ELSE 0 END) AS CVD
  , MAX(CASE WHEN CHARLSON_CATGRY = 'PVD'           THEN CHARLSON_WT ELSE 0 END) AS PVD
  , MAX(CASE WHEN CHARLSON_CATGRY = 'DEMENTIA'      THEN CHARLSON_WT ELSE 0 END) AS DEMENTIA
  , MAX(CASE WHEN CHARLSON_CATGRY = 'COPD'          THEN CHARLSON_WT ELSE 0 END) AS COPD
  , MAX(CASE WHEN CHARLSON_CATGRY = 'RHEUMDIS'      THEN CHARLSON_WT ELSE 0 END) AS RHEUMDIS
  , MAX(CASE WHEN CHARLSON_CATGRY = 'PEPULCER'      THEN CHARLSON_WT ELSE 0 END) AS PEPULCER
  , MAX(CASE WHEN CHARLSON_CATGRY = 'MILDLIVDIS'    THEN CHARLSON_WT ELSE 0 END) AS MILDLIVDIS
  , MAX(CASE WHEN CHARLSON_CATGRY = 'DIABETES_NOCC' THEN CHARLSON_WT ELSE 0 END) AS DIABETES_NOCC
  , MAX(CASE WHEN CHARLSON_CATGRY = 'DIABETES_WTCC' THEN CHARLSON_WT ELSE 0 END) AS DIABETES_WTCC
  , MAX(CASE WHEN CHARLSON_CATGRY = 'HEMIPARAPLEG'  THEN CHARLSON_WT ELSE 0 END) AS HEMIPARAPLEG
  , MAX(CASE WHEN CHARLSON_CATGRY = 'RENALDIS'      THEN CHARLSON_WT ELSE 0 END) AS RENALDIS
  , MAX(CASE WHEN CHARLSON_CATGRY = 'CANCER'        THEN CHARLSON_WT ELSE 0 END) AS CANCER
  , MAX(CASE WHEN CHARLSON_CATGRY = 'MSVLIVDIS'     THEN CHARLSON_WT ELSE 0 END) AS MSVLIVDIS
  , MAX(CASE WHEN CHARLSON_CATGRY = 'METASTATIC'    THEN CHARLSON_WT ELSE 0 END) AS METASTATIC
  , MAX(CASE WHEN CHARLSON_CATGRY = 'AIDSHIV'       THEN CHARLSON_WT ELSE 0 END) AS AIDSHIV
FROM (
  /* FOR EACH VISIT - PULL PREVIOUS YEAR OF DIAGNOSIS FACTS JOINED TO CHARLSON CATEGORIES - EXTRACTING CHARLSON CATGRY/WT */
  SELECT O.PATIENT_NUM, O.AGE, O.LAST_VISIT, O.CHARLSON_AGE_BASE, C.CHARLSON_CATGRY, C.CHARLSON_WT
  FROM (SELECT DISTINCT F.PATIENT_NUM, CONCEPT_CD, V.AGE, V.LAST_VISIT, V.CHARLSON_AGE_BASE 
        FROM OBSERVATION_FACT F 
          JOIN #CHARLSON_VISIT_BASE V 
            ON F.PATIENT_NUM = V.PATIENT_NUM
            AND F.START_DATE BETWEEN DATEADD(YY,-1,V.LAST_VISIT) AND V.LAST_VISIT
       )O
    JOIN #CHARLSON_DX C
      ON O.CONCEPT_CD = C.CONCEPT_CD
  GROUP BY O.PATIENT_NUM, O.AGE, O.LAST_VISIT, O.CHARLSON_AGE_BASE, C.CHARLSON_CATGRY, C.CHARLSON_WT
  UNION /* IF NO CHARLSON DX FOUND IN ABOVE INNER JOINS WE CAN UNION TO JUST THE ENCOUNTER+AGE_BASE RECORD WITH CHARLSON FIELDS NULLED OUT
           THIS IS MORE PERFORMANT (SHORTCUT) THAN A LEFT JOIN IN THE OBSERVATION-CHARLSON JOIN ABOVE */
  SELECT V2.PATIENT_NUM, V2.AGE, V2.LAST_VISIT, V2.CHARLSON_AGE_BASE, NULL, NULL
  FROM #CHARLSON_VISIT_BASE V2
  )DXU
  GROUP BY PATIENT_NUM, AGE, LAST_VISIT, CHARLSON_AGE_BASE
)cci
)ccisum

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Charlson Index and weighted flags - Rows: %d - Total Execution (ms): %d  - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* CHARLSON 10YR PROB MEDIAN/MEAN/MODE/STDEV */
SET @STEPTTS = GETDATE()

/* UNFILTERED BY PSC */
;WITH CTE_MODE AS (
SELECT ISNULL(A.AGEGRP,'All Patients') AGEGRP
  , CHARLSON_10YR_SURVIVAL_PROB
  , RANK() OVER (PARTITION BY ISNULL(A.AGEGRP,'All Patients') ORDER BY N DESC) MR_AG
FROM (
SELECT AGEGRP, CHARLSON_10YR_SURVIVAL_PROB, COUNT(*) N
FROM #COHORT_CHARLSON
GROUP BY GROUPING SETS ((AGEGRP, CHARLSON_10YR_SURVIVAL_PROB),(CHARLSON_10YR_SURVIVAL_PROB))
)A
GROUP BY ISNULL(A.AGEGRP,'All Patients'), CHARLSON_10YR_SURVIVAL_PROB, N
)
, CTE_MEAN_STDEV_MODE AS (
SELECT ISNULL(GS.AGEGRP,'All Patients') AGEGRP, MEAN_10YRPROB, STDEV_10YRPROB
  , (SELECT CHARLSON_10YR_SURVIVAL_PROB FROM CTE_MODE WHERE AGEGRP = ISNULL(GS.AGEGRP,'All Patients') AND (MR_AG = 1)) AS MODE_10YRPROB
FROM (
SELECT AGEGRP, AVG(CHARLSON_10YR_SURVIVAL_PROB) MEAN_10YRPROB, STDEV(CHARLSON_10YR_SURVIVAL_PROB) STDEV_10YRPROB
FROM #COHORT_CHARLSON
GROUP BY GROUPING SETS ((AGEGRP),())
)GS
)
SELECT MS.AGEGRP
  , CAST('N' AS CHAR(1)) CUTOFF_FILTER_YN
  , MEDIAN_10YR_SURVIVAL
  , S.MEAN_10YRPROB
  , S.STDEV_10YRPROB
  , S.MODE_10YRPROB
INTO #CHARLSON_STATS
FROM (
SELECT AGEGRP, CHARLSON_10YR_SURVIVAL_PROB
  , PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CHARLSON_10YR_SURVIVAL_PROB) OVER (PARTITION BY AGEGRP) AS MEDIAN_10YR_SURVIVAL
FROM #COHORT_CHARLSON
WHERE AGEGRP != '-'
UNION ALL
SELECT 'All Patients' as AGEGRP, CHARLSON_10YR_SURVIVAL_PROB
  , PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CHARLSON_10YR_SURVIVAL_PROB) OVER (PARTITION BY 1) AS MEDIAN_10YR_SURVIVAL
FROM #COHORT_CHARLSON
WHERE AGEGRP != '-'
)MS, CTE_MEAN_STDEV_MODE S
WHERE MS.AGEGRP = S.AGEGRP
GROUP BY MS.AGEGRP, MEDIAN_10YR_SURVIVAL, S.MODE_10YRPROB, S.STDEV_10YRPROB, S.MEAN_10YRPROB

/* FILTERED BY PSC */
;WITH CTE_MODE AS (
SELECT --ISNULL(A.AGEGRP,'All Patients') AGEGRP
    AGEGRP
  , CHARLSON_10YR_SURVIVAL_PROB
  , RANK() OVER (PARTITION BY ISNULL(A.AGEGRP,'All Patients') ORDER BY N DESC) MR_AG
FROM (
SELECT C.AGEGRP, CHARLSON_10YR_SURVIVAL_PROB, COUNT(*) N
FROM #COHORT_CHARLSON CC
  JOIN #cohort_agegrp C
    ON CC.PATIENT_NUM = C.patient_num
  JOIN #AGEGRP_PSC PSC
    ON C.AGEGRP = PSC.AGEGRP
    AND C.Predicted_score >= PSC.PredictiveScoreCutoff
GROUP BY C.AGEGRP,CHARLSON_10YR_SURVIVAL_PROB
)A
GROUP BY AGEGRP, CHARLSON_10YR_SURVIVAL_PROB, N
)
, CTE_MEAN_STDEV_MODE AS (
SELECT AGEGRP, MEAN_10YRPROB, STDEV_10YRPROB
  , (SELECT CHARLSON_10YR_SURVIVAL_PROB FROM CTE_MODE WHERE AGEGRP = ISNULL(GS.AGEGRP,'All Patients') AND (MR_AG = 1)) AS MODE_10YRPROB
FROM (
SELECT C.AGEGRP, AVG(CHARLSON_10YR_SURVIVAL_PROB) MEAN_10YRPROB, STDEV(CHARLSON_10YR_SURVIVAL_PROB) STDEV_10YRPROB
FROM #COHORT_CHARLSON CC
  JOIN #cohort_agegrp C
    ON CC.PATIENT_NUM = C.patient_num
  JOIN #AGEGRP_PSC PSC
    ON C.AGEGRP = PSC.AGEGRP
    AND C.Predicted_score >= PSC.PredictiveScoreCutoff
GROUP BY C.AGEGRP
)GS
)
INSERT INTO #CHARLSON_STATS(AGEGRP,CUTOFF_FILTER_YN,MEDIAN_10YR_SURVIVAL,MEAN_10YRPROB,STDEV_10YRPROB,MODE_10YRPROB)
SELECT MS.AGEGRP
  , CAST('Y' AS CHAR(1)) AS CUTOFF_FILTER_YN
  , MEDIAN_10YR_SURVIVAL
  , S.MEAN_10YRPROB
  , S.STDEV_10YRPROB
  , S.MODE_10YRPROB
FROM (
SELECT C.AGEGRP, CHARLSON_10YR_SURVIVAL_PROB
  , PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CHARLSON_10YR_SURVIVAL_PROB) OVER (PARTITION BY C.AGEGRP) AS MEDIAN_10YR_SURVIVAL
FROM #COHORT_CHARLSON CC
  JOIN #cohort_agegrp C
    ON CC.PATIENT_NUM = C.patient_num
  JOIN #AGEGRP_PSC PSC
    ON C.AGEGRP = PSC.AGEGRP
    AND C.Predicted_score >= PSC.PredictiveScoreCutoff
WHERE CC.AGEGRP != '-'
)MS, CTE_MEAN_STDEV_MODE S
WHERE MS.AGEGRP = S.AGEGRP
GROUP BY MS.AGEGRP, MEDIAN_10YR_SURVIVAL, S.MODE_10YRPROB, S.STDEV_10YRPROB, S.MEAN_10YRPROB


SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Charlson Stats - Rows: %d - Total Execution (ms): %d  - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* FINAL SUMMARIZATION OF RESULTS */
/* clear out last run of lookback */
DELETE FROM dbo.loyalty_dev_summary WHERE LOOKBACK_YR = @lookbackYears AND GENDER_DENOMINATORS_YN = IIF(@gendered=0,'N','Y') and [SITE]=@site

/* FINAL SUMMARIZATION OF RESULTS */
SET @STEPTTS = GETDATE()

INSERT INTO dbo.loyalty_dev_summary ([SITE], [LOOKBACK_YR], GENDER_DENOMINATORS_YN, [CUTOFF_FILTER_YN], [Summary_Description], [tablename], [Num_DX1], [Num_DX2], [MedUse1], [MedUse2]
, [Mammography], [PapTest], [PSATest], [Colonoscopy], [FecalOccultTest], [FluShot], [PneumococcalVaccine], [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit]
, [MDVisit_pname2], [MDVisit_pname3], [Routine_care_2], [Subjects_NoCriteria], [PredictiveScoreCutoff]
, [MEAN_10YRPROB], [MEDIAN_10YR_SURVIVAL], [MODE_10YRPROB], [STDEV_10YRPROB], [TotalSubjects]
, TotalSubjectsFemale, TotalSubjectsMale)
SELECT @site, @lookbackYears, IIF(@gendered=0,'N','Y') as GENDER_DENOMINATORS_YN, COHORTAGG.CUTOFF_FILTER_YN, Summary_Description, COHORTAGG.AGEGRP as tablename, Num_DX1, Num_DX2, MedUse1, MedUse2
  , Mammography, PapTest, PSATest, Colonoscopy, FecalOccultTest, FluShot, PneumococcalVaccine, BMI, A1C, MedicalExam, INP1_OPT1_Visit, OPT2_Visit, ED_Visit
  , MDVisit_pname2, MDVisit_pname3, Routine_care_2, Subjects_NoCriteria
  , CASE WHEN COHORTAGG.CUTOFF_FILTER_YN = 'Y' THEN CP.PredictiveScoreCutoff ELSE NULL END AS PredictiveScoreCutoff
  , CS.MEAN_10YRPROB, CS.MEDIAN_10YR_SURVIVAL, CS.MODE_10YRPROB, CS.STDEV_10YRPROB, TotalSubjects
  , TotalSubjectsFemale
  , TotalSubjectsMale
FROM (
/* FILTERED BY PREDICTIVE CUTOFF */
SELECT
'Y' AS CUTOFF_FILTER_YN,
'Patient Counts' as Summary_Description,
CAG.AGEGRP, 
count(distinct patient_num) as TotalSubjects,
sum(cast([Num_Dx1] as int)) as Num_DX1,
sum(cast([Num_Dx2] as int)) as Num_DX2,
sum(cast([MedUse1] as int))  as MedUse1,
sum(cast([MedUse2] as int)) as MedUse2,
sum(cast(IIF(@gendered=0,[Mammography],IIF(SEX='F',[Mammography],NULL)) as int)) as Mammography,
sum(cast(IIF(@gendered=0,[PapTest]    ,IIF(SEX='F',[PapTest]    ,NULL)) as int)) as PapTest,
sum(cast(IIF(@gendered=0,[PSATest]    ,IIF(SEX='M',[PSATest]    ,NULL)) as int)) as PSATest,
sum(cast([Colonoscopy] as int)) as Colonoscopy,
sum(cast([FecalOccultTest] as int)) as FecalOccultTest,
sum(cast([FluShot] as int)) as  FluShot,
sum(cast([PneumococcalVaccine] as int)) as PneumococcalVaccine,
sum(cast([BMI] as int))  as BMI,
sum(cast([A1C] as int)) as A1C,
sum(cast([MedicalExam] as int)) as MedicalExam,
sum(cast([INP1_OPT1_Visit] as int)) as INP1_OPT1_Visit,
sum(cast([OPT2_Visit] as int)) as OPT2_Visit,
sum(cast([ED_Visit] as int))  as ED_Visit,
sum(cast([MDVisit_pname2] as int)) as MDVisit_pname2,
sum(cast([MDVisit_pname3] as int)) as MDVisit_pname3,
sum(cast([Routine_Care_2] as int)) as Routine_care_2,
SUM(CAST(~(Num_Dx1|Num_Dx2|MedUse1|Mammography|PapTest|PSATest|Colonoscopy|FecalOccultTest|FluShot|PneumococcalVaccine|BMI|
  A1C|MedicalExam|INP1_OPT1_Visit|OPT2_Visit|ED_Visit|MDVisit_pname2|MDVisit_pname3|Routine_Care_2) AS INT)) as Subjects_NoCriteria, /* inverted bitwise OR of all bit flags */
count(distinct IIF(SEX='F',patient_num,NULL)) AS TotalSubjectsFemale,
count(distinct IIF(SEX='M',patient_num,NULL)) AS TotalSubjectsMale
from #cohort_agegrp CAG JOIN #AGEGRP_PSC P ON CAG.AGEGRP = P.AGEGRP AND CAG.Predicted_score >= P.PredictiveScoreCutoff
group by CAG.AGEGRP
UNION ALL
SELECT
'Y' AS CUTOFF_FILTER_YN,
'PercentOfSubjects' as Summary_Description,
CAG.AGEGRP, 
count(distinct patient_num) as TotalSubjects,
100*avg(cast([Num_Dx1] as numeric(2,1))) as Num_DX1,
100*avg(cast([Num_Dx2] as numeric(2,1))) as Num_DX2,
100*avg(cast([MedUse1] as numeric(2,1)))  as MedUse1,
100*avg(cast([MedUse2] as numeric(2,1))) as MedUse2,
100*avg(cast(IIF(@gendered=0,[Mammography],IIF(SEX='F',[Mammography],NULL)) AS numeric(2,1))) as Mammography,
100*avg(cast(IIF(@gendered=0,[PapTest]    ,IIF(SEX='F',[PapTest]    ,NULL)) AS numeric(2,1))) as PapTest,
100*avg(cast(IIF(@gendered=0,[PSATest]    ,IIF(SEX='M',[PSATest]    ,NULL)) AS numeric(2,1))) as PSATest,
100*avg(cast([Colonoscopy] as numeric(2,1))) as Colonoscopy,
100*avg(cast([FecalOccultTest] as numeric(2,1))) as FecalOccultTest,
100*avg(cast([FluShot] as numeric(2,1))) as  FluShot,
100*avg(cast([PneumococcalVaccine] as numeric(2,1))) as PneumococcalVaccine,
100*avg(cast([BMI] as numeric(2,1)))  as BMI,
100*avg(cast([A1C] as numeric(2,1))) as A1C,
100*avg(cast([MedicalExam] as numeric(2,1))) as MedicalExam,
100*avg(cast([INP1_OPT1_Visit] as numeric(2,1))) as INP1_OPT1_Visit,
100*avg(cast([OPT2_Visit] as numeric(2,1))) as OPT2_Visit,
100*avg(cast([ED_Visit] as numeric(2,1)))  as ED_Visit,
100*avg(cast([MDVisit_pname2] as numeric(2,1))) as MDVisit_pname2,
100*avg(cast([MDVisit_pname3] as numeric(2,1))) as MDVisit_pname3,
100*avg(cast([Routine_Care_2] as numeric(2,1))) as Routine_care_2,
100*AVG(CAST(~(Num_Dx1|Num_Dx2|MedUse1|Mammography|PapTest|PSATest|Colonoscopy|FecalOccultTest|FluShot|PneumococcalVaccine|BMI|
  A1C|MedicalExam|INP1_OPT1_Visit|OPT2_Visit|ED_Visit|MDVisit_pname2|MDVisit_pname3|Routine_Care_2) AS NUMERIC(2,1))) as Subjects_NoCriteria, /* inverted bitwise OR of all bit flags */
count(distinct IIF(SEX='F',patient_num,NULL)) AS TotalSubjectsFemale,
count(distinct IIF(SEX='M',patient_num,NULL)) AS TotalSubjectsMale
from #cohort_agegrp CAG JOIN #AGEGRP_PSC P ON CAG.AGEGRP = P.AGEGRP AND CAG.Predicted_score >= P.PredictiveScoreCutoff
group by CAG.AGEGRP
UNION ALL
/* UNFILTERED -- ALL QUINTILES */
SELECT
'N' AS CUTOFF_FILTER_YN,
'Patient Counts' as Summary_Description,
CAG.AGEGRP, 
count(distinct patient_num) as TotalSubjects,
sum(cast([Num_Dx1] as int)) as Num_DX1,
sum(cast([Num_Dx2] as int)) as Num_DX2,
sum(cast([MedUse1] as int))  as MedUse1,
sum(cast([MedUse2] as int)) as MedUse2,
sum(cast(IIF(@gendered=0,[Mammography],IIF(SEX='F',[Mammography],NULL)) as int)) as Mammography,
sum(cast(IIF(@gendered=0,[PapTest]    ,IIF(SEX='F',[PapTest]    ,NULL)) as int)) as PapTest,
sum(cast(IIF(@gendered=0,[PSATest]    ,IIF(SEX='M',[PSATest]    ,NULL)) as int)) as PSATest,
sum(cast([Colonoscopy] as int)) as Colonoscopy,
sum(cast([FecalOccultTest] as int)) as FecalOccultTest,
sum(cast([FluShot] as int)) as  FluShot,
sum(cast([PneumococcalVaccine] as int)) as PneumococcalVaccine,
sum(cast([BMI] as int))  as BMI,
sum(cast([A1C] as int)) as A1C,
sum(cast([MedicalExam] as int)) as MedicalExam,
sum(cast([INP1_OPT1_Visit] as int)) as INP1_OPT1_Visit,
sum(cast([OPT2_Visit] as int)) as OPT2_Visit,
sum(cast([ED_Visit] as int))  as ED_Visit,
sum(cast([MDVisit_pname2] as int)) as MDVisit_pname2,
sum(cast([MDVisit_pname3] as int)) as MDVisit_pname3,
sum(cast([Routine_Care_2] as int)) as Routine_care_2,
SUM(CAST(~(Num_Dx1|Num_Dx2|MedUse1|Mammography|PapTest|PSATest|Colonoscopy|FecalOccultTest|FluShot|PneumococcalVaccine|BMI|
  A1C|MedicalExam|INP1_OPT1_Visit|OPT2_Visit|ED_Visit|MDVisit_pname2|MDVisit_pname3|Routine_Care_2) AS INT)) as Subjects_NoCriteria, /* inverted bitwise OR of all bit flags */
count(distinct IIF(SEX='F',patient_num,NULL)) AS TotalSubjectsFemale,
count(distinct IIF(SEX='M',patient_num,NULL)) AS TotalSubjectsMale
from #cohort_agegrp CAG
group by CAG.AGEGRP
UNION ALL
SELECT
'N' AS PREDICTIVE_CUTOFF_FILTER_YN,
'PercentOfSubjects' as Summary_Description,
CAG.AGEGRP, 
count(distinct patient_num) as TotalSubjects,
100*avg(cast([Num_Dx1] as numeric(2,1))) as Num_DX1,
100*avg(cast([Num_Dx2] as numeric(2,1))) as Num_DX2,
100*avg(cast([MedUse1] as numeric(2,1)))  as MedUse1,
100*avg(cast([MedUse2] as numeric(2,1))) as MedUse2,
100*avg(cast(IIF(@gendered=0,[Mammography],IIF(SEX='F',[Mammography],NULL)) AS numeric(2,1))) as Mammography,
100*avg(cast(IIF(@gendered=0,[PapTest]    ,IIF(SEX='F',[PapTest]    ,NULL)) AS numeric(2,1))) as PapTest,
100*avg(cast(IIF(@gendered=0,[PSATest]    ,IIF(SEX='M',[PSATest]    ,NULL)) AS numeric(2,1))) as PSATest,
100*avg(cast([Colonoscopy] as numeric(2,1))) as Colonoscopy,
100*avg(cast([FecalOccultTest] as numeric(2,1))) as FecalOccultTest,
100*avg(cast([FluShot] as numeric(2,1))) as  FluShot,
100*avg(cast([PneumococcalVaccine] as numeric(2,1))) as PneumococcalVaccine,
100*avg(cast([BMI] as numeric(2,1)))  as BMI,
100*avg(cast([A1C] as numeric(2,1))) as A1C,
100*avg(cast([MedicalExam] as numeric(2,1))) as MedicalExam,
100*avg(cast([INP1_OPT1_Visit] as numeric(2,1))) as INP1_OPT1_Visit,
100*avg(cast([OPT2_Visit] as numeric(2,1))) as OPT2_Visit,
100*avg(cast([ED_Visit] as numeric(2,1)))  as ED_Visit,
100*avg(cast([MDVisit_pname2] as numeric(2,1))) as MDVisit_pname2,
100*avg(cast([MDVisit_pname3] as numeric(2,1))) as MDVisit_pname3,
100*avg(cast([Routine_Care_2] as numeric(2,1))) as Routine_care_2,
100*AVG(CAST(~(Num_Dx1|Num_Dx2|MedUse1|Mammography|PapTest|PSATest|Colonoscopy|FecalOccultTest|FluShot|PneumococcalVaccine|BMI|
  A1C|MedicalExam|INP1_OPT1_Visit|OPT2_Visit|ED_Visit|MDVisit_pname2|MDVisit_pname3|Routine_Care_2) AS NUMERIC(2,1))) as Subjects_NoCriteria, /* inverted bitwise OR of all bit flags */
count(distinct IIF(SEX='F',patient_num,NULL)) AS TotalSubjectsFemale,
count(distinct IIF(SEX='M',patient_num,NULL)) AS TotalSubjectsMale
from #cohort_agegrp CAG
group by CAG.AGEGRP 
)COHORTAGG
  JOIN #AGEGRP_PSC CP
    ON COHORTAGG.AGEGRP = CP.AGEGRP
  JOIN #CHARLSON_STATS CS
    ON COHORTAGG.AGEGRP = CS.AGEGRP
      AND COHORTAGG.CUTOFF_FILTER_YN = CS.CUTOFF_FILTER_YN

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Final Summary Table - Rows: %d - Total Execution (ms): %d - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

UPDATE [dbo].[loyalty_dev_summary]
SET RUNTIMEms = @ENDRUNTIMEms
WHERE LOOKBACK_YR = @lookbackYears

-- jgk 8/4/21: Expose the cohort table for analytics. Keep in mind it is fairly large. 

SET @STEPTTS = GETDATE()

IF OBJECT_ID(N'DBO.loyalty_dev', N'U') IS NOT NULL DROP TABLE DBO.loyalty_dev;
select * into DBO.loyalty_dev from #cohort_agegrp;

SELECT @ROWS=@@ROWCOUNT,@ENDRUNTIMEms = DATEDIFF(MILLISECOND,@STARTTS,GETDATE()),@STEPRUNTIMEms = DATEDIFF(MILLISECOND,@STEPTTS,GETDATE())
RAISERROR(N'Final Summary Table - Rows: %d - Total Execution (ms): %d - Step Runtime (ms): %d', 1, 1, @ROWS, @ENDRUNTIMEms, @STEPRUNTIMEms) with nowait;

/* FINAL OUTPUT FOR SHARED SPREADSHEET */
if(@output=1) /* Only if Output parameter was passed */
  SELECT [SITE], [EXTRACT_DTTM], [LOOKBACK_YR], GENDER_DENOMINATORS_YN, [CUTOFF_FILTER_YN], [Summary_Description], [tablename], [Num_DX1], [Num_DX2], [MedUse1], [MedUse2]
  , [Mammography], [PapTest], [PSATest], [Colonoscopy], [FecalOccultTest], [FluShot], [PneumococcalVaccine], [BMI], [A1C], [MedicalExam], [INP1_OPT1_Visit], [OPT2_Visit], [ED_Visit]
  , [MDVisit_pname2], [MDVisit_pname3], [Routine_care_2], [Subjects_NoCriteria], [PredictiveScoreCutoff]
  , [MEAN_10YRPROB], [MEDIAN_10YR_SURVIVAL], [MODE_10YRPROB], [STDEV_10YRPROB]
  , [TotalSubjects], [TotalSubjectsFemale], [TotalSubjectsMale]
  , FORMAT(1.0*[TotalSubjectsFemale]/[TotalSubjects],'P') AS PercentFemale
  , FORMAT(1.0*[TotalSubjectsMale]/[TotalSubjects],'P') AS PercentMale
  , [RUNTIMEms]
  FROM [dbo].[loyalty_dev_summary] 
  WHERE Summary_Description = 'PercentOfSubjects' 
    AND LOOKBACK_YR = @lookbackYears
    AND GENDER_DENOMINATORS_YN =  IIF(@gendered=0,'N','Y')
    AND [SITE] = @site
  ORDER BY LOOKBACK_YR, CUTOFF_FILTER_YN, TABLENAME;