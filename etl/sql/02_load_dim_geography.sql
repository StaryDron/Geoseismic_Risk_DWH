-- =============================================================================
-- 02_load_dim_geography.sql
-- Stored procedure: usp_Load_DimGeography
--
-- Merges unique ISO3 codes seen in both staging tables against REF_CountryMaster
-- and applies SCD Type 2 logic to DimGeography.
--
-- SCD2 rules:
--   NEW country  → INSERT with IsCurrent=1, ValidFrom=today, ValidTo=NULL
--   CHANGED name → close old row (ValidTo=yesterday, IsCurrent=0),
--                  INSERT new row
--   UNCHANGED    → no action
--
-- Called by SSIS Execute SQL Task after both staging loads succeed.
-- =============================================================================

USE SeismicDisasterDWH;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Load_DimGeography
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @Yesterday DATE = DATEADD(DAY, -1, @Today);

    -- Collect all ISO3 codes referenced in current staging batches
    -- (union of USGS and EMDAT sources)
    IF OBJECT_ID('tempdb..#IncomingISO', 'U') IS NOT NULL DROP TABLE #IncomingISO;

    SELECT DISTINCT r.ISO3, r.CountryDurableKey, r.CountryName,
                    r.SubRegion, r.Region, r.GEM_PGA_g, r.GeoSeismicZone
    INTO #IncomingISO
    FROM (
        SELECT ISO3 FROM SeismicDisasterSTG.dbo.STG_USGS_Raw
        UNION
        SELECT ISO  FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw WHERE ISO IS NOT NULL
    ) src
    INNER JOIN dbo.REF_CountryMaster r ON r.ISO3 = src.ISO3;

    -- -----------------------------------------------------------------------
    -- STEP 1: NEW countries (not yet in DimGeography at all)
    -- -----------------------------------------------------------------------
    INSERT INTO dbo.DimGeography (
        GeographyKey, CountryName, ISO, SubRegion, Region,
        ValidFrom, ValidTo, IsCurrent,
        GeoSeismicZone, GEM_PGA_g, CountryDurableKey
    )
    SELECT
        NEXT VALUE FOR dbo.Seq_GeographyKey,
        i.CountryName, i.ISO3, i.SubRegion, i.Region,
        @Today, NULL, 1,
        i.GeoSeismicZone, i.GEM_PGA_g, i.CountryDurableKey
    FROM #IncomingISO i
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.DimGeography g WHERE g.CountryDurableKey = i.CountryDurableKey
    );

    -- -----------------------------------------------------------------------
    -- STEP 2: CHANGED countries – name differs from current active record
    --         (DurableKey is the same, CountryName is different)
    -- -----------------------------------------------------------------------

    -- 2a. Close old version
    UPDATE dbo.DimGeography
    SET ValidTo   = @Yesterday,
        IsCurrent = 0,
        UpdateDate = GETDATE()
    FROM dbo.DimGeography g
    INNER JOIN #IncomingISO i ON i.CountryDurableKey = g.CountryDurableKey
    WHERE g.IsCurrent = 1
      AND g.CountryName <> i.CountryName;

    -- 2b. Open new version
    INSERT INTO dbo.DimGeography (
        GeographyKey, CountryName, ISO, SubRegion, Region,
        ValidFrom, ValidTo, IsCurrent,
        GeoSeismicZone, GEM_PGA_g, CountryDurableKey
    )
    SELECT
        NEXT VALUE FOR dbo.Seq_GeographyKey,
        i.CountryName, i.ISO3, i.SubRegion, i.Region,
        @Today, NULL, 1,
        i.GeoSeismicZone, i.GEM_PGA_g, i.CountryDurableKey
    FROM #IncomingISO i
    WHERE EXISTS (
        SELECT 1 FROM dbo.DimGeography g
        WHERE g.CountryDurableKey = i.CountryDurableKey
          AND g.IsCurrent = 0
          AND g.ValidTo   = @Yesterday  -- just closed above
    )
    AND NOT EXISTS (
        SELECT 1 FROM dbo.DimGeography g
        WHERE g.CountryDurableKey = i.CountryDurableKey
          AND g.IsCurrent = 1
    );

    DROP TABLE #IncomingISO;
END;
GO
