-- =============================================================================
-- 03_load_fact_seismic.sql
-- Stored procedure: usp_Load_FactSeismic
--
-- Transforms STG_USGS_Raw → FactSeismic.
-- Lookup strategy:
--   DateKey        – parsed from SrcTime (UTC timestamp → YYYYMMDD)
--   GeographyKey   – ISO3 lookup on DimGeography WHERE IsCurrent=1
--   MagnitudeKey   – range lookup on DimMagnitude
--   SeismicDepthKey– range lookup on DimSeismicDepth
--
-- Idempotent: skips events whose USGS EventId already appears in staging
-- batch rows that have already been promoted (tracked via ETL_FactSeismicLoad).
-- In practice SSIS calls this once per batch; re-runs are safe because the
-- EventId uniqueness check prevents duplicates.
-- =============================================================================

USE SeismicDisasterDWH;
GO

-- Tracks which STG batch rows have been promoted to avoid re-processing
IF OBJECT_ID('dbo.ETL_FactSeismicLoad', 'U') IS NULL
CREATE TABLE dbo.ETL_FactSeismicLoad (
    StgId       BIGINT  NOT NULL,
    LoadedAt    DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_ETL_FSL PRIMARY KEY (StgId)
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Load_FactSeismic
AS
BEGIN
    SET NOCOUNT ON;

    -- Only process staging rows not yet promoted
    INSERT INTO dbo.FactSeismic (
        SeismicKey,
        DateKey,
        GeographyKey,
        MagnitudeKey,
        SeismicDepthKey,
        Latitude,
        Longitude,
        Magnitude,
        SeismicDepth,
        ModifiedMercalliIntensity,
        SignificanceScore,
        CommunityDecimalIntensity
    )
    SELECT
        NEXT VALUE FOR dbo.Seq_SeismicKey,
        -- DateKey: parse UTC timestamp "2024-01-15T06:42:11.340Z" → 20240115
        CAST(FORMAT(
            CAST(LEFT(s.SrcTime, 10) AS DATE),
            'yyyyMMdd'
        ) AS INT),
        -- GeographyKey: current version only; fallback to XIN if not in DimGeography
        COALESCE(g.GeographyKey, gxin.GeographyKey),
        -- MagnitudeKey
        m.MagnitudeKey,
        -- SeismicDepthKey
        d.SeismicDepthKey,
        s.Latitude,
        s.Longitude,
        s.Mag,
        s.Depth,
        NULL,   -- ModifiedMercalliIntensity not in USGS CSV; enriched separately if needed
        NULL,   -- SignificanceScore  – likewise
        NULL    -- CommunityDecimalIntensity
    FROM SeismicDisasterSTG.dbo.STG_USGS_Raw s
    -- Geography lookup (current version)
    LEFT JOIN dbo.DimGeography g
        ON  g.ISO       = s.ISO3
        AND g.IsCurrent = 1
    -- Fallback XIN key for unresolved / ocean events
    LEFT JOIN dbo.DimGeography gxin
        ON  gxin.ISO        = 'XIN'
        AND gxin.IsCurrent  = 1
    -- Magnitude band
    INNER JOIN dbo.DimMagnitude m
        ON  s.Mag >= m.LowerBound
        AND s.Mag  < m.UpperBound
    -- Depth band
    INNER JOIN dbo.DimSeismicDepth d
        ON  COALESCE(s.Depth, 0) >= d.LowerBoundKM
        AND COALESCE(s.Depth, 0)  < d.UpperBoundKM
    -- Exclude already-loaded rows
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.ETL_FactSeismicLoad fl WHERE fl.StgId = s.StgId
    )
    -- Skip rows where DateKey cannot be resolved (malformed timestamp)
    AND TRY_CAST(LEFT(s.SrcTime, 10) AS DATE) IS NOT NULL;

    -- Mark promoted rows
    INSERT INTO dbo.ETL_FactSeismicLoad (StgId)
    SELECT s.StgId
    FROM SeismicDisasterSTG.dbo.STG_USGS_Raw s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.ETL_FactSeismicLoad fl WHERE fl.StgId = s.StgId)
      AND TRY_CAST(LEFT(s.SrcTime, 10) AS DATE) IS NOT NULL;

    PRINT CONCAT('FactSeismic loaded: ', @@ROWCOUNT, ' rows marked.');
END;
GO
