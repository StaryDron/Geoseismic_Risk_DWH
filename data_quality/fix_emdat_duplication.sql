-- fix_emdat_duplication.sql
-- Remediation for the duplicate-EMDAT defect found during data quality analysis.
-- EMDAT was extracted twice before DisNo dedup existed in extract_emdat.py, so
-- STG_EMDAT_Raw held 2 rows per DisNo (1396 rows / 698 distinct), which doubled
-- FactDisaster and the bridge. This removes the duplicate staging rows and
-- rebuilds FactDisaster + BridgeDisasterSeismic from the deduplicated staging.
-- The extractor now dedups by DisNo, so this is a one-off repair.

SET NOCOUNT ON;
GO

-- 1. Keep one staging row per DisNo (lowest StgId)
DELETE FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw
WHERE StgId NOT IN (
    SELECT MIN(StgId) FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw GROUP BY DisNo
);
GO
DECLARE @stg INT = (SELECT COUNT(*) FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw);
PRINT CONCAT('STG_EMDAT_Raw after dedup: ', @stg, ' rows.');
GO

USE SeismicDisasterDWH;
GO

-- 2. Clear bridge (FK references FactDisaster), facts, and the load tracker
DELETE FROM dbo.BridgeDisasterSeismic;
DELETE FROM dbo.FactDisaster;
DELETE FROM dbo.ETL_FactDisasterLoad;
GO

-- 3. Rebuild from clean staging
EXEC dbo.usp_Load_FactDisaster;
EXEC dbo.usp_Build_BridgeDisasterSeismic;
GO

-- 4. Verify
SELECT 'FactDisaster' AS tbl, COUNT(*) AS rows_now FROM dbo.FactDisaster
UNION ALL SELECT 'FactDisaster distinct date+geo+deaths', COUNT(*) FROM (
    SELECT DISTINCT StartDate, GeographyKey, TotalDeaths FROM dbo.FactDisaster) x
UNION ALL SELECT 'BridgeDisasterSeismic', COUNT(*) FROM dbo.BridgeDisasterSeismic;
GO
