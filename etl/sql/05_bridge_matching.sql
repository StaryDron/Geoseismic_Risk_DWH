-- =============================================================================
-- 05_bridge_matching.sql
-- Haversine helper function + stored procedure: usp_Build_BridgeDisasterSeismic
--
-- For every FactDisaster row that has no bridge entries yet, the procedure
-- finds all FactSeismic events that satisfy BOTH:
--   Temporal:  seismic event date is within BRIDGE_WINDOW_DAYS before disaster StartDate
--   Spatial:   epicentre is within BRIDGE_RADIUS_KM of disaster centroid
--
-- ~4% of EMDAT records lack coordinates (Latitude IS NULL).
-- For those, spatial matching is skipped; they appear with no bridge rows.
--
-- Configuration constants:
--   @RadiusKM  = 100 km   (matches spec)
--   @WindowDays = 3 days  (matches spec)
-- =============================================================================

USE SeismicDisasterDWH;
GO

-- ---------------------------------------------------------------------------
-- Haversine distance function (returns km)
-- ---------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_Haversine (
    @lat1 DECIMAL(8,5), @lon1 DECIMAL(9,5),
    @lat2 DECIMAL(8,5), @lon2 DECIMAL(9,5)
)
RETURNS DECIMAL(10,3)
AS
BEGIN
    DECLARE @R  FLOAT = 6371.0;
    DECLARE @dLat FLOAT = RADIANS(CAST(@lat2 - @lat1 AS FLOAT));
    DECLARE @dLon FLOAT = RADIANS(CAST(@lon2 - @lon1 AS FLOAT));
    DECLARE @a   FLOAT =
        POWER(SIN(@dLat / 2), 2)
        + COS(RADIANS(CAST(@lat1 AS FLOAT)))
        * COS(RADIANS(CAST(@lat2 AS FLOAT)))
        * POWER(SIN(@dLon / 2), 2);
    RETURN CAST(@R * 2.0 * ATN2(SQRT(@a), SQRT(1.0 - @a)) AS DECIMAL(10,3));
END;
GO

-- ---------------------------------------------------------------------------
-- Bridge matching procedure
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Build_BridgeDisasterSeismic
    @RadiusKM   INT = 100,
    @WindowDays INT = 3
AS
BEGIN
    SET NOCOUNT ON;

    -- Disasters that need bridge matching:
    -- either have coordinates OR we still want a temporal-only link
    ;WITH DisastersToMatch AS (
        SELECT
            fd.DisasterKey,
            fd.StartDate,                       -- YYYYMMDD INT key
            fd.Latitude  AS DLat,
            fd.Longitude AS DLon,
            fd.GeographyKey
        FROM dbo.FactDisaster fd
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.BridgeDisasterSeismic b WHERE b.DisasterKey = fd.DisasterKey
        )
    ),
    -- Expand disaster start date back by window
    DisasterWindow AS (
        SELECT
            d.DisasterKey,
            d.DLat,
            d.DLon,
            dd_start.Date                               AS StartDateValue,
            DATEADD(DAY, -@WindowDays, dd_start.Date)   AS EarliestSeismicDate,
            d.GeographyKey
        FROM DisastersToMatch d
        INNER JOIN dbo.DimDate dd_start ON dd_start.DateKey = d.StartDate
    )
    INSERT INTO dbo.BridgeDisasterSeismic (
        DisasterKey, SeismicKey, DistanceKM, TimeLagDays
    )
    SELECT
        dw.DisasterKey,
        fs.SeismicKey,
        -- Only compute distance when both sets of coordinates are available
        CASE
            WHEN dw.DLat IS NOT NULL AND fs.Latitude IS NOT NULL
            THEN dbo.fn_Haversine(dw.DLat, dw.DLon, fs.Latitude, fs.Longitude)
            ELSE NULL
        END,
        DATEDIFF(DAY, dd_seismic.Date, dw.StartDateValue)  -- positive = seismic before disaster
    FROM DisasterWindow dw
    INNER JOIN dbo.FactSeismic fs ON 1 = 1          -- cross with seismic events in time window
    INNER JOIN dbo.DimDate dd_seismic ON dd_seismic.DateKey = fs.DateKey
    WHERE
        -- Temporal filter: seismic event within window before disaster
        dd_seismic.Date BETWEEN dw.EarliestSeismicDate AND dw.StartDateValue
        -- Spatial filter: only when both have coordinates
        AND (
            dw.DLat IS NULL
            OR dbo.fn_Haversine(dw.DLat, dw.DLon, fs.Latitude, fs.Longitude) <= @RadiusKM
        )
        -- Same country (reduces Cartesian product dramatically before Haversine)
        AND fs.GeographyKey = dw.GeographyKey;

    PRINT CONCAT('BridgeDisasterSeismic: ', @@ROWCOUNT, ' links inserted.');
END;
GO
