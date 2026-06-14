-- 01_seed_dimensions.sql
-- Seeds static dimensions (DimDate, DimMagnitude, DimSeismicDepth, severity
-- bands, REF_CountryMaster) and the surrogate key sequences. Safe to re-run.

USE SeismicDisasterDWH;
GO

-- Sequences for surrogate keys (not IDENTITY so ETL controls assignment)
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = N'Seq_GeographyKey')
    CREATE SEQUENCE dbo.Seq_GeographyKey AS INT     START WITH 1 INCREMENT BY 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = N'Seq_SeismicKey')
    CREATE SEQUENCE dbo.Seq_SeismicKey   AS BIGINT  START WITH 1 INCREMENT BY 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = N'Seq_DisasterKey')
    CREATE SEQUENCE dbo.Seq_DisasterKey  AS INT     START WITH 1 INCREMENT BY 1;
GO

-- DimDate  1990-01-01 … 2030-12-31  (~14 976 rows)
IF NOT EXISTS (SELECT 1 FROM dbo.DimDate)
BEGIN
    ;WITH
    L0 AS (SELECT 1 c UNION ALL SELECT 1),
    L1 AS (SELECT 1 c FROM L0 a CROSS JOIN L0 b),
    L2 AS (SELECT 1 c FROM L1 a CROSS JOIN L1 b),
    L3 AS (SELECT 1 c FROM L2 a CROSS JOIN L2 b),
    L4 AS (SELECT 1 c FROM L3 a CROSS JOIN L3 b),
    Nums AS (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM L4),
    Dates AS (
        SELECT DATEADD(DAY, n, '1990-01-01') AS d
        FROM Nums
        WHERE DATEADD(DAY, n, '1990-01-01') <= '2030-12-31'
    )
    INSERT INTO dbo.DimDate (
        DateKey, [Date], [Year], [Quarter], [Month], MonthName, MonthNameShort,
        [Day], DayWeek, DayWeekName, DayYear, WeekYear
    )
    SELECT
        CAST(FORMAT(d, 'yyyyMMdd') AS INT),
        d,
        CAST(YEAR(d)                   AS SMALLINT),
        CAST(DATEPART(QUARTER, d)      AS TINYINT),
        CAST(MONTH(d)                  AS TINYINT),
        DATENAME(MONTH, d),
        LEFT(DATENAME(MONTH, d), 3),
        CAST(DAY(d)                    AS TINYINT),
        CAST(DATEPART(WEEKDAY, d)      AS TINYINT),
        DATENAME(WEEKDAY, d),
        CAST(DATEPART(DAYOFYEAR, d)    AS SMALLINT),
        CAST(DATEPART(ISO_WEEK, d)     AS TINYINT)
    FROM Dates;

    PRINT CONCAT('DimDate: ', @@ROWCOUNT, ' rows inserted.');
END
ELSE
    PRINT 'DimDate already populated – skipped.';
GO

-- DimMagnitude  (Moment Magnitude / Richter bands)
IF NOT EXISTS (SELECT 1 FROM dbo.DimMagnitude)
BEGIN
    INSERT INTO dbo.DimMagnitude (MagnitudeKey, BandCode, BandName, LowerBound, UpperBound, MagScale)
    VALUES
        (1,  'M0-2',  'Micro',        0.00,  1.99, 'Mw'),
        (2,  'M2-3',  'Minor',        2.00,  2.99, 'Mw'),
        (3,  'M3-4',  'Light',        3.00,  3.99, 'Mw'),
        (4,  'M4-5',  'Moderate',     4.00,  4.99, 'Mw'),
        (5,  'M5-6',  'Strong',       5.00,  5.99, 'Mw'),
        (6,  'M6-7',  'Major',        6.00,  6.99, 'Mw'),
        (7,  'M7-8',  'Great',        7.00,  7.99, 'Mw'),
        (8,  'M8+',   'Mega',         8.00, 10.00, 'Mw');

    PRINT 'DimMagnitude: 8 rows inserted.';
END
ELSE
    PRINT 'DimMagnitude already populated – skipped.';
GO

-- DimSeismicDepth
IF NOT EXISTS (SELECT 1 FROM dbo.DimSeismicDepth)
BEGIN
    INSERT INTO dbo.DimSeismicDepth (SeismicDepthKey, BandName, LowerBoundKM, UpperBoundKM)
    VALUES
        (1, 'Shallow',      0,   70),
        (2, 'Intermediate', 70,  300),
        (3, 'Deep',         300, 700),
        (4, 'Ultra-deep',   700, 9999);   -- rare but exists (Tonga slab)

    PRINT 'DimSeismicDepth: 4 rows inserted.';
END
ELSE
    PRINT 'DimSeismicDepth already populated – skipped.';
GO

-- DimSeverityDeaths
IF NOT EXISTS (SELECT 1 FROM dbo.DimSeverityDeaths)
BEGIN
    INSERT INTO dbo.DimSeverityDeaths (SeverityDeathsKey, SeverityCode, LowerBound, UpperBound)
    VALUES
        (1, 'Minimal',      0,     9),
        (2, 'Limited',      10,    99),
        (3, 'Severe',       100,   999),
        (4, 'Catastrophic', 1000,  2147483647);

    PRINT 'DimSeverityDeaths: 4 rows inserted.';
END
ELSE
    PRINT 'DimSeverityDeaths already populated – skipped.';
GO

-- DimSeverityAffected
IF NOT EXISTS (SELECT 1 FROM dbo.DimSeverityAffected)
BEGIN
    INSERT INTO dbo.DimSeverityAffected (SeverityAffectedKey, SeverityCode, LowerBound, UpperBound)
    VALUES
        (1, 'Minor',    0,      999),
        (2, 'Moderate', 1000,   9999),
        (3, 'Major',    10000,  99999),
        (4, 'Massive',  100000, 2147483647);

    PRINT 'DimSeverityAffected: 4 rows inserted.';
END
ELSE
    PRINT 'DimSeverityAffected already populated – skipped.';
GO

-- REF_CountryMaster
-- Reference table consumed by usp_Load_DimGeography.
-- GEM_PGA_g values are country-level medians (approximate) from the
-- GEM Global Seismic Hazard Map (10% prob. of exceedance in 50 years).
-- GeoSeismicZone: Very Low|Low|Moderate|High|Very High
-- CountryDurableKey: stable integer that does NOT change when a country
--                    renames itself (used as SCD2 business key).
IF OBJECT_ID('dbo.REF_CountryMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.REF_CountryMaster (
        CountryDurableKey   INT             NOT NULL,
        ISO3                CHAR(3)         NOT NULL,
        ISO2                CHAR(2)         NULL,
        CountryName         NVARCHAR(100)   NOT NULL,
        SubRegion           NVARCHAR(50)    NOT NULL,
        Region              NVARCHAR(25)    NOT NULL,
        GEM_PGA_g           DECIMAL(4,3)    NULL,
        GeoSeismicZone      NVARCHAR(20)    NULL,
        CONSTRAINT PK_REF_Country PRIMARY KEY (CountryDurableKey),
        CONSTRAINT UQ_REF_ISO3    UNIQUE (ISO3)
    );
    PRINT 'REF_CountryMaster table created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.REF_CountryMaster)
BEGIN
    INSERT INTO dbo.REF_CountryMaster
        (CountryDurableKey, ISO3, ISO2, CountryName,                    SubRegion,                  Region,     GEM_PGA_g, GeoSeismicZone)
    VALUES
    -- Special codes
    (  1, 'XIN', NULL,  'International Waters',         'Ocean',                    'Ocean',    NULL,  'Very Low'),
    -- Asia – Eastern
    (  2, 'JPN', 'JP',  'Japan',                        'Eastern Asia',             'Asia',     0.600, 'Very High'),
    (  3, 'CHN', 'CN',  'China',                        'Eastern Asia',             'Asia',     0.200, 'High'),
    (  4, 'KOR', 'KR',  'Republic of Korea',            'Eastern Asia',             'Asia',     0.070, 'Low'),
    (  5, 'PRK', 'KP',  'Dem. People''s Rep. Korea',    'Eastern Asia',             'Asia',     0.060, 'Low'),
    (  6, 'MNG', 'MN',  'Mongolia',                     'Eastern Asia',             'Asia',     0.100, 'Moderate'),
    (  7, 'TWN', 'TW',  'Taiwan',                       'Eastern Asia',             'Asia',     0.500, 'Very High'),
    -- Asia – South-eastern
    (  8, 'IDN', 'ID',  'Indonesia',                    'South-eastern Asia',       'Asia',     0.500, 'Very High'),
    (  9, 'PHL', 'PH',  'Philippines',                  'South-eastern Asia',       'Asia',     0.520, 'Very High'),
    ( 10, 'MMR', 'MM',  'Myanmar',                      'South-eastern Asia',       'Asia',     0.280, 'High'),
    ( 11, 'THA', 'TH',  'Thailand',                     'South-eastern Asia',       'Asia',     0.080, 'Moderate'),
    ( 12, 'VNM', 'VN',  'Viet Nam',                     'South-eastern Asia',       'Asia',     0.070, 'Low'),
    ( 13, 'MYS', 'MY',  'Malaysia',                     'South-eastern Asia',       'Asia',     0.060, 'Low'),
    ( 14, 'SGP', 'SG',  'Singapore',                    'South-eastern Asia',       'Asia',     0.020, 'Very Low'),
    ( 15, 'KHM', 'KH',  'Cambodia',                     'South-eastern Asia',       'Asia',     0.040, 'Very Low'),
    ( 16, 'LAO', 'LA',  'Lao PDR',                      'South-eastern Asia',       'Asia',     0.050, 'Very Low'),
    ( 17, 'TLS', 'TL',  'Timor-Leste',                  'South-eastern Asia',       'Asia',     0.350, 'High'),
    -- Asia – Southern
    ( 18, 'IND', 'IN',  'India',                        'Southern Asia',            'Asia',     0.160, 'Moderate'),
    ( 19, 'PAK', 'PK',  'Pakistan',                     'Southern Asia',            'Asia',     0.320, 'High'),
    ( 20, 'BGD', 'BD',  'Bangladesh',                   'Southern Asia',            'Asia',     0.120, 'Moderate'),
    ( 21, 'NPL', 'NP',  'Nepal',                        'Southern Asia',            'Asia',     0.380, 'High'),
    ( 22, 'AFG', 'AF',  'Afghanistan',                  'Southern Asia',            'Asia',     0.360, 'High'),
    ( 23, 'LKA', 'LK',  'Sri Lanka',                    'Southern Asia',            'Asia',     0.080, 'Moderate'),
    ( 24, 'BTN', 'BT',  'Bhutan',                       'Southern Asia',            'Asia',     0.200, 'High'),
    ( 25, 'MDV', 'MV',  'Maldives',                     'Southern Asia',            'Asia',     0.020, 'Very Low'),
    -- Asia – Central
    ( 26, 'KAZ', 'KZ',  'Kazakhstan',                   'Central Asia',             'Asia',     0.120, 'Moderate'),
    ( 27, 'UZB', 'UZ',  'Uzbekistan',                   'Central Asia',             'Asia',     0.280, 'High'),
    ( 28, 'TJK', 'TJ',  'Tajikistan',                   'Central Asia',             'Asia',     0.400, 'High'),
    ( 29, 'KGZ', 'KG',  'Kyrgyzstan',                   'Central Asia',             'Asia',     0.360, 'High'),
    ( 30, 'TKM', 'TM',  'Turkmenistan',                 'Central Asia',             'Asia',     0.200, 'High'),
    -- Asia – Western
    ( 31, 'TUR', 'TR',  'Turkey',                       'Western Asia',             'Asia',     0.350, 'High'),
    ( 32, 'IRN', 'IR',  'Iran',                         'Western Asia',             'Asia',     0.340, 'High'),
    ( 33, 'IRQ', 'IQ',  'Iraq',                         'Western Asia',             'Asia',     0.150, 'Moderate'),
    ( 34, 'SYR', 'SY',  'Syria',                        'Western Asia',             'Asia',     0.200, 'High'),
    ( 35, 'LBN', 'LB',  'Lebanon',                      'Western Asia',             'Asia',     0.220, 'High'),
    ( 36, 'ISR', 'IL',  'Israel',                       'Western Asia',             'Asia',     0.200, 'High'),
    ( 37, 'JOR', 'JO',  'Jordan',                       'Western Asia',             'Asia',     0.160, 'Moderate'),
    ( 38, 'SAU', 'SA',  'Saudi Arabia',                 'Western Asia',             'Asia',     0.080, 'Moderate'),
    ( 39, 'YEM', 'YE',  'Yemen',                        'Western Asia',             'Asia',     0.120, 'Moderate'),
    ( 40, 'OMN', 'OM',  'Oman',                         'Western Asia',             'Asia',     0.100, 'Moderate'),
    ( 41, 'ARE', 'AE',  'United Arab Emirates',         'Western Asia',             'Asia',     0.060, 'Low'),
    ( 42, 'KWT', 'KW',  'Kuwait',                       'Western Asia',             'Asia',     0.040, 'Very Low'),
    ( 43, 'BHR', 'BH',  'Bahrain',                      'Western Asia',             'Asia',     0.040, 'Very Low'),
    ( 44, 'QAT', 'QA',  'Qatar',                        'Western Asia',             'Asia',     0.040, 'Very Low'),
    ( 45, 'GEO', 'GE',  'Georgia',                      'Western Asia',             'Asia',     0.300, 'High'),
    ( 46, 'ARM', 'AM',  'Armenia',                      'Western Asia',             'Asia',     0.320, 'High'),
    ( 47, 'AZE', 'AZ',  'Azerbaijan',                   'Western Asia',             'Asia',     0.260, 'High'),
    ( 48, 'CYP', 'CY',  'Cyprus',                       'Western Asia',             'Asia',     0.200, 'High'),
    -- Europe – Southern
    ( 49, 'ITA', 'IT',  'Italy',                        'Southern Europe',          'Europe',   0.260, 'High'),
    ( 50, 'GRC', 'GR',  'Greece',                       'Southern Europe',          'Europe',   0.280, 'High'),
    ( 51, 'PRT', 'PT',  'Portugal',                     'Southern Europe',          'Europe',   0.160, 'Moderate'),
    ( 52, 'ESP', 'ES',  'Spain',                        'Southern Europe',          'Europe',   0.120, 'Moderate'),
    ( 53, 'MLT', 'MT',  'Malta',                        'Southern Europe',          'Europe',   0.120, 'Moderate'),
    ( 54, 'ALB', 'AL',  'Albania',                      'Southern Europe',          'Europe',   0.260, 'High'),
    ( 55, 'MKD', 'MK',  'North Macedonia',              'Southern Europe',          'Europe',   0.240, 'High'),
    ( 56, 'SRB', 'RS',  'Serbia',                       'Southern Europe',          'Europe',   0.180, 'Moderate'),
    ( 57, 'BIH', 'BA',  'Bosnia and Herzegovina',       'Southern Europe',          'Europe',   0.200, 'High'),
    ( 58, 'MNE', 'ME',  'Montenegro',                   'Southern Europe',          'Europe',   0.240, 'High'),
    ( 59, 'HRV', 'HR',  'Croatia',                      'Southern Europe',          'Europe',   0.200, 'High'),
    ( 60, 'SVN', 'SI',  'Slovenia',                     'Southern Europe',          'Europe',   0.180, 'Moderate'),
    -- Europe – Eastern
    ( 61, 'ROU', 'RO',  'Romania',                      'Eastern Europe',           'Europe',   0.200, 'High'),
    ( 62, 'BGR', 'BG',  'Bulgaria',                     'Eastern Europe',           'Europe',   0.180, 'Moderate'),
    ( 63, 'UKR', 'UA',  'Ukraine',                      'Eastern Europe',           'Europe',   0.080, 'Moderate'),
    ( 64, 'MDA', 'MD',  'Moldova',                      'Eastern Europe',           'Europe',   0.120, 'Moderate'),
    ( 65, 'BLR', 'BY',  'Belarus',                      'Eastern Europe',           'Europe',   0.020, 'Very Low'),
    ( 66, 'POL', 'PL',  'Poland',                       'Eastern Europe',           'Europe',   0.040, 'Very Low'),
    ( 67, 'CZE', 'CZ',  'Czechia',                      'Eastern Europe',           'Europe',   0.040, 'Very Low'),
    ( 68, 'SVK', 'SK',  'Slovakia',                     'Eastern Europe',           'Europe',   0.060, 'Low'),
    ( 69, 'HUN', 'HU',  'Hungary',                      'Eastern Europe',           'Europe',   0.080, 'Moderate'),
    ( 70, 'RUS', 'RU',  'Russian Federation',           'Eastern Europe',           'Europe',   0.120, 'Moderate'),
    -- Europe – Western/Northern
    ( 71, 'DEU', 'DE',  'Germany',                      'Western Europe',           'Europe',   0.040, 'Very Low'),
    ( 72, 'FRA', 'FR',  'France',                       'Western Europe',           'Europe',   0.060, 'Low'),
    ( 73, 'CHE', 'CH',  'Switzerland',                  'Western Europe',           'Europe',   0.120, 'Moderate'),
    ( 74, 'AUT', 'AT',  'Austria',                      'Western Europe',           'Europe',   0.100, 'Moderate'),
    ( 75, 'GBR', 'GB',  'United Kingdom',               'Northern Europe',          'Europe',   0.030, 'Very Low'),
    ( 76, 'IRL', 'IE',  'Ireland',                      'Northern Europe',          'Europe',   0.020, 'Very Low'),
    ( 77, 'NLD', 'NL',  'Netherlands',                  'Western Europe',           'Europe',   0.040, 'Very Low'),
    ( 78, 'BEL', 'BE',  'Belgium',                      'Western Europe',           'Europe',   0.040, 'Very Low'),
    ( 79, 'LUX', 'LU',  'Luxembourg',                   'Western Europe',           'Europe',   0.040, 'Very Low'),
    ( 80, 'DNK', 'DK',  'Denmark',                      'Northern Europe',          'Europe',   0.020, 'Very Low'),
    ( 81, 'SWE', 'SE',  'Sweden',                       'Northern Europe',          'Europe',   0.020, 'Very Low'),
    ( 82, 'NOR', 'NO',  'Norway',                       'Northern Europe',          'Europe',   0.040, 'Very Low'),
    ( 83, 'FIN', 'FI',  'Finland',                      'Northern Europe',          'Europe',   0.020, 'Very Low'),
    ( 84, 'ISL', 'IS',  'Iceland',                      'Northern Europe',          'Europe',   0.300, 'High'),
    -- Americas – South
    ( 85, 'CHL', 'CL',  'Chile',                        'South America',            'Americas', 0.550, 'Very High'),
    ( 86, 'PER', 'PE',  'Peru',                         'South America',            'Americas', 0.480, 'Very High'),
    ( 87, 'ECU', 'EC',  'Ecuador',                      'South America',            'Americas', 0.480, 'Very High'),
    ( 88, 'COL', 'CO',  'Colombia',                     'South America',            'Americas', 0.420, 'Very High'),
    ( 89, 'VEN', 'VE',  'Venezuela',                    'South America',            'Americas', 0.200, 'High'),
    ( 90, 'BOL', 'BO',  'Bolivia',                      'South America',            'Americas', 0.280, 'High'),
    ( 91, 'ARG', 'AR',  'Argentina',                    'South America',            'Americas', 0.200, 'High'),
    ( 92, 'BRA', 'BR',  'Brazil',                       'South America',            'Americas', 0.040, 'Very Low'),
    ( 93, 'PRY', 'PY',  'Paraguay',                     'South America',            'Americas', 0.030, 'Very Low'),
    ( 94, 'URY', 'UY',  'Uruguay',                      'South America',            'Americas', 0.030, 'Very Low'),
    -- Americas – Central
    ( 95, 'MEX', 'MX',  'Mexico',                       'Central America',          'Americas', 0.400, 'Very High'),
    ( 96, 'GTM', 'GT',  'Guatemala',                    'Central America',          'Americas', 0.440, 'Very High'),
    ( 97, 'SLV', 'SV',  'El Salvador',                  'Central America',          'Americas', 0.440, 'Very High'),
    ( 98, 'HND', 'HN',  'Honduras',                     'Central America',          'Americas', 0.200, 'High'),
    ( 99, 'NIC', 'NI',  'Nicaragua',                    'Central America',          'Americas', 0.360, 'High'),
    (100, 'CRI', 'CR',  'Costa Rica',                   'Central America',          'Americas', 0.420, 'Very High'),
    (101, 'PAN', 'PA',  'Panama',                       'Central America',          'Americas', 0.300, 'High'),
    (102, 'BLZ', 'BZ',  'Belize',                       'Central America',          'Americas', 0.100, 'Moderate'),
    -- Americas – Caribbean
    (103, 'HTI', 'HT',  'Haiti',                        'Caribbean',                'Americas', 0.380, 'High'),
    (104, 'DOM', 'DO',  'Dominican Republic',           'Caribbean',                'Americas', 0.240, 'High'),
    (105, 'CUB', 'CU',  'Cuba',                         'Caribbean',                'Americas', 0.180, 'Moderate'),
    (106, 'JAM', 'JM',  'Jamaica',                      'Caribbean',                'Americas', 0.280, 'High'),
    (107, 'TTO', 'TT',  'Trinidad and Tobago',          'Caribbean',                'Americas', 0.240, 'High'),
    (108, 'BRB', 'BB',  'Barbados',                     'Caribbean',                'Americas', 0.240, 'High'),
    -- Americas – Northern
    (109, 'USA', 'US',  'United States of America',     'Northern America',         'Americas', 0.200, 'High'),
    (110, 'CAN', 'CA',  'Canada',                       'Northern America',         'Americas', 0.120, 'Moderate'),
    -- Africa – Northern
    (111, 'DZA', 'DZ',  'Algeria',                      'Northern Africa',          'Africa',   0.180, 'Moderate'),
    (112, 'MAR', 'MA',  'Morocco',                      'Northern Africa',          'Africa',   0.160, 'Moderate'),
    (113, 'TUN', 'TN',  'Tunisia',                      'Northern Africa',          'Africa',   0.120, 'Moderate'),
    (114, 'LBY', 'LY',  'Libya',                        'Northern Africa',          'Africa',   0.100, 'Moderate'),
    (115, 'EGY', 'EG',  'Egypt',                        'Northern Africa',          'Africa',   0.120, 'Moderate'),
    (116, 'SDN', 'SD',  'Sudan',                        'Northern Africa',          'Africa',   0.060, 'Low'),
    -- Africa – Eastern
    (117, 'ETH', 'ET',  'Ethiopia',                     'Eastern Africa',           'Africa',   0.140, 'Moderate'),
    (118, 'KEN', 'KE',  'Kenya',                        'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (119, 'TZA', 'TZ',  'Tanzania',                     'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (120, 'MOZ', 'MZ',  'Mozambique',                   'Eastern Africa',           'Africa',   0.100, 'Moderate'),
    (121, 'MWI', 'MW',  'Malawi',                       'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (122, 'ZMB', 'ZM',  'Zambia',                       'Eastern Africa',           'Africa',   0.080, 'Moderate'),
    (123, 'UGA', 'UG',  'Uganda',                       'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (124, 'RWA', 'RW',  'Rwanda',                       'Eastern Africa',           'Africa',   0.140, 'Moderate'),
    (125, 'BDI', 'BI',  'Burundi',                      'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (126, 'SOM', 'SO',  'Somalia',                      'Eastern Africa',           'Africa',   0.100, 'Moderate'),
    (127, 'ERI', 'ER',  'Eritrea',                      'Eastern Africa',           'Africa',   0.100, 'Moderate'),
    (128, 'DJI', 'DJ',  'Djibouti',                     'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (129, 'MDG', 'MG',  'Madagascar',                   'Eastern Africa',           'Africa',   0.120, 'Moderate'),
    (130, 'COM', 'KM',  'Comoros',                      'Eastern Africa',           'Africa',   0.200, 'High'),
    -- Africa – Middle
    (131, 'COD', 'CD',  'Dem. Rep. of the Congo',       'Middle Africa',            'Africa',   0.100, 'Moderate'),
    (132, 'CMR', 'CM',  'Cameroon',                     'Middle Africa',            'Africa',   0.080, 'Moderate'),
    (133, 'CAF', 'CF',  'Central African Republic',     'Middle Africa',            'Africa',   0.040, 'Very Low'),
    (134, 'COG', 'CG',  'Congo',                        'Middle Africa',            'Africa',   0.040, 'Very Low'),
    (135, 'GAB', 'GA',  'Gabon',                        'Middle Africa',            'Africa',   0.040, 'Very Low'),
    (136, 'TCD', 'TD',  'Chad',                         'Middle Africa',            'Africa',   0.040, 'Very Low'),
    -- Africa – Western
    (137, 'NGA', 'NG',  'Nigeria',                      'Western Africa',           'Africa',   0.060, 'Low'),
    (138, 'GHA', 'GH',  'Ghana',                        'Western Africa',           'Africa',   0.060, 'Low'),
    (139, 'CIV', 'CI',  'Côte d''Ivoire',               'Western Africa',           'Africa',   0.060, 'Low'),
    (140, 'SEN', 'SN',  'Senegal',                      'Western Africa',           'Africa',   0.040, 'Very Low'),
    (141, 'MLI', 'ML',  'Mali',                         'Western Africa',           'Africa',   0.040, 'Very Low'),
    (142, 'GIN', 'GN',  'Guinea',                       'Western Africa',           'Africa',   0.080, 'Moderate'),
    -- Africa – Southern
    (143, 'ZAF', 'ZA',  'South Africa',                 'Southern Africa',          'Africa',   0.080, 'Moderate'),
    (144, 'ZWE', 'ZW',  'Zimbabwe',                     'Southern Africa',          'Africa',   0.060, 'Low'),
    (145, 'BWA', 'BW',  'Botswana',                     'Southern Africa',          'Africa',   0.060, 'Low'),
    (146, 'NAM', 'NA',  'Namibia',                      'Southern Africa',          'Africa',   0.060, 'Low'),
    -- Oceania – Melanesia / Pacific
    (147, 'PNG', 'PG',  'Papua New Guinea',             'Melanesia',                'Oceania',  0.460, 'Very High'),
    (148, 'SLB', 'SB',  'Solomon Islands',              'Melanesia',                'Oceania',  0.460, 'Very High'),
    (149, 'VUT', 'VU',  'Vanuatu',                      'Melanesia',                'Oceania',  0.520, 'Very High'),
    (150, 'FJI', 'FJ',  'Fiji',                         'Melanesia',                'Oceania',  0.280, 'High'),
    (151, 'NCL', 'NC',  'New Caledonia',                'Melanesia',                'Oceania',  0.200, 'High'),
    (152, 'NZL', 'NZ',  'New Zealand',                  'Australia and New Zealand','Oceania',  0.440, 'Very High'),
    (153, 'AUS', 'AU',  'Australia',                    'Australia and New Zealand','Oceania',  0.060, 'Low'),
    (154, 'TON', 'TO',  'Tonga',                        'Polynesia',                'Oceania',  0.480, 'Very High'),
    (155, 'WSM', 'WS',  'Samoa',                        'Polynesia',                'Oceania',  0.300, 'High'),
    (156, 'FSM', 'FM',  'Micronesia (Fed. States of)',  'Micronesia',               'Oceania',  0.200, 'High'),
    (157, 'PLW', 'PW',  'Palau',                        'Micronesia',               'Oceania',  0.200, 'High'),
    -- Remaining UN members (low seismicity)
    (159, 'AFR', NULL,  'Africa (unspecified)',          'Sub-Saharan Africa',       'Africa',   0.040, 'Very Low'),
    (160, 'PSE', 'PS',  'State of Palestine',           'Western Asia',             'Asia',     0.180, 'Moderate'),
    (161, 'XKX', NULL,  'Kosovo',                       'Southern Europe',          'Europe',   0.200, 'High');

    PRINT CONCAT('REF_CountryMaster: ', @@ROWCOUNT, ' rows inserted.');
END
ELSE
    PRINT 'REF_CountryMaster already populated – skipped.';
GO
