# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Data Warehouse schema for geoseismic risk and tsunami disaster analysis. The single deliverable is `Skrypt_SQL_Hurtownia_tsunami.sql`, a T-SQL script that creates and populates the `SeismicDisasterDWH` database on Microsoft SQL Server.

## ETL Execution Order

```
# 1. Create both databases
sqlcmd -S localhost -i Skrypt_SQL_Hurtownia_tsunami.sql
sqlcmd -S localhost -i etl/sql/00_staging_schema.sql

# 2. Seed static dimensions + reference data
sqlcmd -S localhost -i etl/sql/01_seed_dimensions.sql

# 3. Extract USGS data to staging (Python)
pip install -r etl/python/requirements.txt
python etl/python/extract_usgs.py

# 4. Extract EMDAT data (requires CSV from emdat.be)
python etl/python/extract_emdat.py

# 5. Run SSIS stored procedures (or via sqlcmd for manual runs)
sqlcmd -S localhost -d SeismicDisasterDWH -Q "EXEC dbo.usp_Load_DimGeography"
sqlcmd -S localhost -d SeismicDisasterDWH -Q "EXEC dbo.usp_Load_FactSeismic"
sqlcmd -S localhost -d SeismicDisasterDWH -Q "EXEC dbo.usp_Load_FactDisaster"
sqlcmd -S localhost -d SeismicDisasterDWH -Q "EXEC dbo.usp_Build_BridgeDisasterSeismic"
```

Connection settings are in `etl/python/config.py`.

## ETL Architecture

```
etl/
├── python/
│   ├── config.py          # DB connection, API settings, file paths
│   ├── extract_usgs.py    # USGS REST API → STG_USGS_Raw (incremental, reverse-geocoded)
│   └── extract_emdat.py   # EMDAT CSV export → STG_EMDAT_Raw
└── sql/
    ├── 00_staging_schema.sql    # SeismicDisasterSTG DB + staging tables + ETL_RunLog
    ├── 01_seed_dimensions.sql   # DimDate, DimMagnitude, DimSeismicDepth,
    │                            # DimSeverityDeaths, DimSeverityAffected,
    │                            # REF_CountryMaster (country + GEM hazard data),
    │                            # SQL Sequences for surrogate key generation
    ├── 02_load_dim_geography.sql # usp_Load_DimGeography – SCD2 merge
    ├── 03_load_fact_seismic.sql  # usp_Load_FactSeismic – USGS staging → fact table
    ├── 04_load_fact_disaster.sql # usp_Load_FactDisaster – EMDAT staging → fact table
    └── 05_bridge_matching.sql   # fn_Haversine + usp_Build_BridgeDisasterSeismic
```

Key design decisions:
- Surrogate keys use SQL **Sequences** (`Seq_GeographyKey`, `Seq_SeismicKey`, `Seq_DisasterKey`) — not IDENTITY — so ETL controls assignment.
- Reverse geocoding runs in Python (`reverse_geocoder` lib, offline) before staging insert; ocean events → ISO `XIN`.
- `REF_CountryMaster` is the stable reference table used by the SCD2 procedure; `CountryDurableKey` never changes even when a country renames.
- Bridge matching pre-filters by `GeographyKey` before computing Haversine to avoid a full Cartesian product.
- EMDAT monetary columns stored as `$000 USD` in staging; multiplied ×1 000 in `usp_Load_FactDisaster`.

## Running the Schema

Execute the SQL script against a SQL Server instance (SQL Server Management Studio, Azure Data Studio, or `sqlcmd`):

```powershell
sqlcmd -S <server> -i Skrypt_SQL_Hurtownia_tsunami.sql
```

The script is idempotent in intent but **not** in implementation — it runs `CREATE DATABASE` without a prior `DROP`, so re-running against the same server will fail if the database already exists. Drop it first when rebuilding:

```sql
DROP DATABASE IF EXISTS SeismicDisasterDWH;
```

## Schema Architecture

Classic dimensional model (star schema) with two fact tables joined by a bridge.

### Dimension Tables

| Table | Key Type | Notes |
|---|---|---|
| `DimDate` | `INT` (YYYYMMDD format) | Standard time dimension |
| `DimGeography` | `INT` surrogate | **SCD Type 2** — has `ValidFrom`, `ValidTo`, `IsCurrent`, `CountryDurableKey`; index on `(CountryDurableKey, IsCurrent)` |
| `DimMagnitude` | `SMALLINT` | Richter scale band ranges |
| `DimSeismicDepth` | `TINYINT` | Depth bands in km |
| `DimSeverityDeaths` | `TINYINT` | Mortality impact bands |
| `DimSeverityAffected` | `TINYINT` | Population affected bands |

### Fact Tables

**`FactSeismic`** — one row per seismic event; stores raw geophysical measurements alongside dimension keys (DateKey, GeographyKey, MagnitudeKey, SeismicDepthKey).

**`FactDisaster`** — one row per disaster event; has two date FKs (`StartDate`, `EndDate` → `DimDate`), casualty/damage metrics, and a `Tsunami BIT` flag.

### Bridge Table

**`BridgeDisasterSeismic`** — resolves the many-to-many relationship between disasters and seismic events. Carries `DistanceKM` and `TimeLagDays` as relationship-level attributes. Composite PK `(DisasterKey, SeismicKey)`; secondary index on `(SeismicKey, DisasterKey)` for reverse lookups.

### Design Conventions

- All tables carry `InsertDate` and `UpdateDate DATETIME DEFAULT GETDATE()` audit columns.
- Surrogate key types are sized to expected cardinality: `TINYINT` for small lookup tables, `SMALLINT` for medium, `INT`/`BIGINT` for large fact tables.
- `GEM_PGA_g` on `DimGeography` stores Global Earthquake Model peak ground acceleration values (seismic hazard).
- Geographic coordinates use `DECIMAL(8,5)` (lat) / `DECIMAL(9,5)` (lon) for ~1 m precision.
