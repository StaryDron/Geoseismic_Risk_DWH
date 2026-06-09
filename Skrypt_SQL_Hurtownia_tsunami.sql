CREATE DATABASE SeismicDisasterDWH;
GO
USE SeismicDisasterDWH;
GO

CREATE TABLE DimDate (
    DateKey         INT             NOT NULL,
    [Date]          DATE            NOT NULL,
    [Year]          SMALLINT        NOT NULL,
    [Quarter]       TINYINT         NOT NULL,
    [Month]         TINYINT         NOT NULL,
    MonthName       NVARCHAR(15)    NOT NULL,
    MonthNameShort  CHAR(3)         NOT NULL,
    [Day]           TINYINT         NOT NULL,
    DayWeek         TINYINT         NOT NULL,
    DayWeekName     NVARCHAR(10)    NOT NULL,
    DayYear         SMALLINT        NOT NULL,
    WeekYear        TINYINT         NOT NULL,
    InsertDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimDate PRIMARY KEY (DateKey)
);
GO

CREATE TABLE DimGeography (
    GeographyKey        INT             NOT NULL,
    CountryName         NVARCHAR(100)   NOT NULL,
    ISO                 CHAR(3)         NOT NULL,
    SubRegion           NVARCHAR(50)    NOT NULL,
    Region              NVARCHAR(25)    NOT NULL,
    ValidFrom           DATE            NOT NULL,
    ValidTo             DATE            NULL,
    IsCurrent           BIT             NOT NULL,
    GeoSeismicZone      NVARCHAR(20)    NULL,
    GEM_PGA_g           DECIMAL(4,3)    NULL,
    CountryDurableKey   INT             NOT NULL,
    InsertDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimGeography PRIMARY KEY (GeographyKey)
);
GO

CREATE INDEX IX_DimGeography_Durable_IsCurrent
    ON DimGeography (CountryDurableKey, IsCurrent);
GO

CREATE TABLE DimMagnitude (
    MagnitudeKey    SMALLINT        NOT NULL,
    BandCode        NVARCHAR(5)     NOT NULL,
    BandName        NVARCHAR(10)    NOT NULL,
    LowerBound      DECIMAL(4,2)    NOT NULL,   
    UpperBound      DECIMAL(4,2)    NOT NULL,
    MagScale        NVARCHAR(3)     NOT NULL,
    InsertDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimMagnitude PRIMARY KEY (MagnitudeKey)
);
GO

CREATE TABLE DimSeismicDepth (
    SeismicDepthKey TINYINT         NOT NULL,
    BandName        NVARCHAR(15)    NOT NULL,
    LowerBoundKM    INT             NOT NULL,
    UpperBoundKM    INT             NOT NULL,
    InsertDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimSeismicDepth PRIMARY KEY (SeismicDepthKey)
);
GO

CREATE TABLE DimSeverityDeaths (
    SeverityDeathsKey   TINYINT         NOT NULL,
    SeverityCode        NVARCHAR(15)    NOT NULL,
    LowerBound          INT             NOT NULL,
    UpperBound          INT             NOT NULL,
    InsertDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimSeverityDeaths PRIMARY KEY (SeverityDeathsKey)
);
GO

CREATE TABLE DimSeverityAffected (
    SeverityAffectedKey TINYINT         NOT NULL,
    SeverityCode        NVARCHAR(15)    NOT NULL,
    LowerBound          INT             NOT NULL,
    UpperBound          INT             NOT NULL,
    InsertDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DimSeverityAffected PRIMARY KEY (SeverityAffectedKey)
);
GO


CREATE TABLE FactSeismic (
    SeismicKey                  BIGINT          NOT NULL,
    DateKey                     INT             NOT NULL,
    GeographyKey                INT             NOT NULL,
    MagnitudeKey                SMALLINT        NOT NULL,
    SeismicDepthKey             TINYINT         NOT NULL,
    Latitude                    DECIMAL(8,5)    NOT NULL,   
    Longitude                   DECIMAL(9,5)    NOT NULL,   
    Magnitude                   DECIMAL(4,2)    NOT NULL,   
    SeismicDepth                DECIMAL(7,2)    NOT NULL,   
    ModifiedMercalliIntensity   DECIMAL(4,2)    NULL,       
    SignificanceScore           INT             NULL,       
    CommunityDecimalIntensity   DECIMAL(3,1)    NULL,       
    InsertDate                  DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate                  DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_FactSeismic PRIMARY KEY (SeismicKey),
    CONSTRAINT FK_FactSeismic_Date
        FOREIGN KEY (DateKey)      REFERENCES DimDate (DateKey),
    CONSTRAINT FK_FactSeismic_Geography
        FOREIGN KEY (GeographyKey) REFERENCES DimGeography (GeographyKey),
    CONSTRAINT FK_FactSeismic_Magnitude
        FOREIGN KEY (MagnitudeKey) REFERENCES DimMagnitude (MagnitudeKey),
    CONSTRAINT FK_FactSeismic_SeismicDepth
        FOREIGN KEY (SeismicDepthKey) REFERENCES DimSeismicDepth (SeismicDepthKey)
);
GO

CREATE TABLE FactDisaster (
    DisasterKey         INT             NOT NULL,
    StartDate           INT             NOT NULL,   
    EndDate             INT             NOT NULL,   
    GeographyKey        INT             NOT NULL,
    SeverityDeathsKey   TINYINT         NOT NULL,
    SeverityAffectedKey TINYINT         NOT NULL,
    Latitude            DECIMAL(8,5)    NULL,  
    Longitude           DECIMAL(9,5)    NULL,   
    DurationDays        INT             NULL,
    TotalDeaths         INT             NULL,
    TotalAffected       INT             NULL,
    NumInjuries         INT             NULL,
    NumOtherAffected    INT             NULL,
    NumHomeless         INT             NULL,
    TotalDamageAdj      BIGINT          NULL,
    InsuredDamage       BIGINT          NULL,
    Tsunami             BIT             NOT NULL,
    InsertDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate          DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_FactDisaster PRIMARY KEY (DisasterKey),
    CONSTRAINT FK_FactDisaster_StartDate
        FOREIGN KEY (StartDate)           REFERENCES DimDate (DateKey),
    CONSTRAINT FK_FactDisaster_EndDate
        FOREIGN KEY (EndDate)             REFERENCES DimDate (DateKey),
    CONSTRAINT FK_FactDisaster_Geography
        FOREIGN KEY (GeographyKey)        REFERENCES DimGeography (GeographyKey),
    CONSTRAINT FK_FactDisaster_SeverityDeaths
        FOREIGN KEY (SeverityDeathsKey)   REFERENCES DimSeverityDeaths (SeverityDeathsKey),
    CONSTRAINT FK_FactDisaster_SeverityAffected
        FOREIGN KEY (SeverityAffectedKey) REFERENCES DimSeverityAffected (SeverityAffectedKey)
);
GO


CREATE TABLE BridgeDisasterSeismic (
    DisasterKey     INT             NOT NULL,
    SeismicKey      BIGINT          NOT NULL,
    DistanceKM      DECIMAL(6,3)    NULL,
    TimeLagDays     SMALLINT        NULL,
    InsertDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    UpdateDate      DATETIME        NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_BridgeDisasterSeismic
        PRIMARY KEY (DisasterKey, SeismicKey),
    CONSTRAINT FK_Bridge_Disaster
        FOREIGN KEY (DisasterKey) REFERENCES FactDisaster (DisasterKey),
    CONSTRAINT FK_Bridge_Seismic
        FOREIGN KEY (SeismicKey)  REFERENCES FactSeismic (SeismicKey)
);
GO

CREATE INDEX IX_Bridge_Seismic
    ON BridgeDisasterSeismic (SeismicKey, DisasterKey);
GO