-- 00_staging_schema.sql
-- Creates the SeismicDisasterSTG database and all staging/control tables.
-- Run once on a fresh SQL Server instance before any ETL execution.

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'SeismicDisasterSTG')
BEGIN
    CREATE DATABASE SeismicDisasterSTG;
END
GO

USE SeismicDisasterSTG;
GO

-- ETL run control
IF OBJECT_ID('dbo.ETL_RunLog', 'U') IS NULL
CREATE TABLE dbo.ETL_RunLog (
    RunId           INT             NOT NULL IDENTITY(1,1),
    SourceSystem    NVARCHAR(20)    NOT NULL,               -- 'USGS' | 'EMDAT'
    RunStart        DATETIME        NOT NULL DEFAULT GETDATE(),
    RunEnd          DATETIME        NULL,
    [Status]        NVARCHAR(15)    NOT NULL DEFAULT 'RUNNING', -- RUNNING|SUCCESS|FAILED
    RowsExtracted   INT             NULL,
    RowsLoaded      INT             NULL,
    RowsRejected    INT             NULL,
    ErrorMessage    NVARCHAR(MAX)   NULL,
    ExtractFrom     DATE            NULL,
    ExtractTo       DATE            NULL,
    CONSTRAINT PK_ETL_RunLog PRIMARY KEY (RunId)
);
GO

-- USGS raw staging
-- Mirrors USGS FDSN CSV output + ISO3 column added by reverse geocoding
IF OBJECT_ID('dbo.STG_USGS_Raw', 'U') IS NULL
CREATE TABLE dbo.STG_USGS_Raw (
    StgId           BIGINT          NOT NULL IDENTITY(1,1),
    SrcTime         NVARCHAR(30)    NULL,   -- "2024-01-15T06:42:11.340Z"
    Latitude        DECIMAL(8,5)    NULL,
    Longitude       DECIMAL(9,5)    NULL,
    Depth           DECIMAL(7,2)    NULL,   -- km
    Mag             DECIMAL(4,2)    NULL,
    MagType         NVARCHAR(5)     NULL,   -- Mw, Ml, mb, …
    Nst             INT             NULL,
    Gap             DECIMAL(6,2)    NULL,
    Dmin            DECIMAL(10,5)   NULL,
    Rms             DECIMAL(6,3)    NULL,
    Net             NVARCHAR(5)     NULL,
    EventId         NVARCHAR(20)    NULL,   -- USGS unique event ID (e.g. us7000abc1)
    Updated         NVARCHAR(30)    NULL,
    Place           NVARCHAR(200)   NULL,
    EventType       NVARCHAR(20)    NULL,
    HorizontalError DECIMAL(10,2)   NULL,
    DepthError      DECIMAL(10,2)   NULL,
    MagError        DECIMAL(5,3)    NULL,
    MagNst          INT             NULL,
    [Status]        NVARCHAR(10)    NULL,   -- reviewed | automatic
    LocationSource  NVARCHAR(5)     NULL,
    MagSource       NVARCHAR(5)     NULL,
    Mmi             DECIMAL(4,2)    NULL,   -- Modified Mercalli Intensity (geojson only)
    Sig             INT             NULL,   -- USGS significance score (geojson only)
    Cdi             DECIMAL(3,1)    NULL,   -- Community Decimal Intensity (geojson only)
    ISO3            CHAR(3)         NULL,   -- added by Python reverse_geocoder
    LoadBatchId     INT             NOT NULL,
    LoadTimestamp   DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_STG_USGS PRIMARY KEY (StgId)
);
GO

CREATE INDEX IX_STG_USGS_EventId ON dbo.STG_USGS_Raw (EventId);
CREATE INDEX IX_STG_USGS_Batch   ON dbo.STG_USGS_Raw (LoadBatchId);
GO

-- USGS rejected records
IF OBJECT_ID('dbo.STG_USGS_Rejected', 'U') IS NULL
CREATE TABLE dbo.STG_USGS_Rejected (
    RejId           BIGINT          NOT NULL IDENTITY(1,1),
    LoadBatchId     INT             NOT NULL,
    EventId         NVARCHAR(20)    NULL,
    RejectReason    NVARCHAR(500)   NOT NULL,
    RawRecord       NVARCHAR(MAX)   NULL,
    LoadTimestamp   DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_STG_USGS_Rejected PRIMARY KEY (RejId)
);
GO

-- EMDAT raw staging
-- Monetary columns stored in $000 USD (as exported); multiplied ×1 000
-- when loaded into FactDisaster.
IF OBJECT_ID('dbo.STG_EMDAT_Raw', 'U') IS NULL
CREATE TABLE dbo.STG_EMDAT_Raw (
    StgId               INT             NOT NULL IDENTITY(1,1),
    DisNo               NVARCHAR(20)    NULL,   -- "2004-0001-IDN"
    [Year]              SMALLINT        NULL,
    DisasterGroup       NVARCHAR(30)    NULL,
    DisasterSubgroup    NVARCHAR(30)    NULL,
    DisasterType        NVARCHAR(30)    NULL,
    DisasterSubtype     NVARCHAR(30)    NULL,
    EventName           NVARCHAR(100)   NULL,
    Country             NVARCHAR(100)   NULL,
    ISO                 CHAR(3)         NULL,   -- ISO 3166-1 alpha-3
    Region              NVARCHAR(30)    NULL,
    Continent           NVARCHAR(30)    NULL,
    Location            NVARCHAR(200)   NULL,
    Origin              NVARCHAR(100)   NULL,
    Latitude            DECIMAL(8,5)    NULL,
    Longitude           DECIMAL(9,5)    NULL,
    StartYear           SMALLINT        NULL,
    StartMonth          TINYINT         NULL,
    StartDay            TINYINT         NULL,
    EndYear             SMALLINT        NULL,
    EndMonth            TINYINT         NULL,
    EndDay              TINYINT         NULL,
    TotalDeaths         INT             NULL,
    NoInjured           INT             NULL,
    NoAffected          INT             NULL,
    NoHomeless          INT             NULL,
    TotalAffected       INT             NULL,
    ReconstrCostsAdj    BIGINT          NULL,   -- $000 USD
    InsuredDamagesAdj   BIGINT          NULL,   -- $000 USD
    TotalDamagesAdj     BIGINT          NULL,   -- $000 USD
    TsunamiFlag         BIT             NOT NULL DEFAULT 0,
    LoadBatchId         INT             NOT NULL,
    LoadTimestamp       DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_STG_EMDAT PRIMARY KEY (StgId)
);
GO

CREATE INDEX IX_STG_EMDAT_Batch ON dbo.STG_EMDAT_Raw (LoadBatchId);
CREATE INDEX IX_STG_EMDAT_ISO   ON dbo.STG_EMDAT_Raw (ISO);
GO
