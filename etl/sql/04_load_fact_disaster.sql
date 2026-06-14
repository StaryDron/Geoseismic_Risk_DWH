-- 04_load_fact_disaster.sql
-- Stored procedure usp_Load_FactDisaster: transforms STG_EMDAT_Raw into
-- FactDisaster, resolving date/geography/severity keys and converting
-- monetary columns from $000 USD to full USD. Idempotent via ETL_FactDisasterLoad
-- (duplicate DisNo are already filtered out at staging-load time).

USE SeismicDisasterDWH;
GO

IF OBJECT_ID('dbo.ETL_FactDisasterLoad', 'U') IS NULL
CREATE TABLE dbo.ETL_FactDisasterLoad (
    StgId       INT     NOT NULL,
    LoadedAt    DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_ETL_FDL PRIMARY KEY (StgId)
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Load_FactDisaster
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.FactDisaster (
        DisasterKey,
        StartDate,
        EndDate,
        GeographyKey,
        SeverityDeathsKey,
        SeverityAffectedKey,
        Latitude,
        Longitude,
        DurationDays,
        TotalDeaths,
        TotalAffected,
        NumInjuries,
        NumOtherAffected,
        NumHomeless,
        TotalDamageAdj,
        InsuredDamage,
        Tsunami
    )
    SELECT
        NEXT VALUE FOR dbo.Seq_DisasterKey,

        -- StartDate key (YYYYMMDD)
        CAST(FORMAT(
            DATEFROMPARTS(
                e.StartYear,
                COALESCE(e.StartMonth, 1),
                COALESCE(e.StartDay,   1)
            ), 'yyyyMMdd'
        ) AS INT),

        -- EndDate key; if no end data use start date
        CAST(FORMAT(
            DATEFROMPARTS(
                COALESCE(e.EndYear,   e.StartYear),
                COALESCE(e.EndMonth,  COALESCE(e.StartMonth, 1)),
                COALESCE(e.EndDay,    COALESCE(e.StartDay,   1))
            ), 'yyyyMMdd'
        ) AS INT),

        -- Geography
        COALESCE(g.GeographyKey, gfb.GeographyKey),

        -- SeverityDeaths band
        COALESCE(sd.SeverityDeathsKey, 1),      -- defaults to Minimal (0-9)

        -- SeverityAffected band
        COALESCE(sa.SeverityAffectedKey, 1),    -- defaults to Minor

        e.Latitude,
        e.Longitude,

        -- DurationDays
        DATEDIFF(DAY,
            DATEFROMPARTS(e.StartYear, COALESCE(e.StartMonth,1), COALESCE(e.StartDay,1)),
            DATEFROMPARTS(
                COALESCE(e.EndYear, e.StartYear),
                COALESCE(e.EndMonth, COALESCE(e.StartMonth,1)),
                COALESCE(e.EndDay,   COALESCE(e.StartDay,1))
            )
        ),

        COALESCE(e.TotalDeaths, 0),

        e.TotalAffected,

        -- NULL handling for casualty sub-components
        CASE WHEN e.TotalAffected IS NULL THEN NULL ELSE COALESCE(e.NoInjured, 0)   END,
        CASE WHEN e.TotalAffected IS NULL THEN NULL ELSE COALESCE(e.NoAffected - COALESCE(e.NoInjured,0) - COALESCE(e.NoHomeless,0), 0) END,
        CASE WHEN e.TotalAffected IS NULL THEN NULL ELSE COALESCE(e.NoHomeless, 0)  END,

        -- Monetary: $000 USD → full USD
        CASE WHEN e.TotalDamagesAdj    IS NOT NULL THEN e.TotalDamagesAdj    * 1000 ELSE NULL END,
        CASE WHEN e.InsuredDamagesAdj  IS NOT NULL THEN e.InsuredDamagesAdj  * 1000 ELSE NULL END,

        e.TsunamiFlag

    FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw e

    -- Geography lookup
    LEFT JOIN dbo.DimGeography g
        ON  g.ISO       = e.ISO
        AND g.IsCurrent = 1
    -- Fallback: XIN if ISO not resolved
    LEFT JOIN dbo.DimGeography gfb
        ON  gfb.ISO         = 'XIN'
        AND gfb.IsCurrent   = 1

    -- SeverityDeaths
    LEFT JOIN dbo.DimSeverityDeaths sd
        ON  COALESCE(e.TotalDeaths, 0) >= sd.LowerBound
        AND COALESCE(e.TotalDeaths, 0) <= sd.UpperBound

    -- SeverityAffected
    LEFT JOIN dbo.DimSeverityAffected sa
        ON  COALESCE(e.TotalAffected, 0) >= sa.LowerBound
        AND COALESCE(e.TotalAffected, 0) <= sa.UpperBound

    -- Skip already-loaded rows
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.ETL_FactDisasterLoad fl WHERE fl.StgId = e.StgId
    )
    -- Require a valid StartYear
    AND e.StartYear IS NOT NULL
    AND e.StartYear BETWEEN 1900 AND 2030
    -- Require corresponding DimDate entry
    AND EXISTS (
        SELECT 1 FROM dbo.DimDate dd
        WHERE dd.DateKey = CAST(FORMAT(
            DATEFROMPARTS(e.StartYear, COALESCE(e.StartMonth,1), COALESCE(e.StartDay,1)),
            'yyyyMMdd') AS INT)
    );

    -- Mark promoted rows
    INSERT INTO dbo.ETL_FactDisasterLoad (StgId)
    SELECT e.StgId
    FROM SeismicDisasterSTG.dbo.STG_EMDAT_Raw e
    WHERE NOT EXISTS (SELECT 1 FROM dbo.ETL_FactDisasterLoad fl WHERE fl.StgId = e.StgId)
      AND e.StartYear IS NOT NULL
      AND e.StartYear BETWEEN 1900 AND 2030;

    PRINT CONCAT('FactDisaster loaded: ', @@ROWCOUNT, ' rows marked.');
END;
GO
