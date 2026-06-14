# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Data Warehouse schema for geoseismic risk and tsunami disaster analysis. The single deliverable is `Skrypt_SQL_Hurtownia_tsunami.sql`, a T-SQL script that creates and populates the `SeismicDisasterDWH` database on Microsoft SQL Server.

## Required Software (Windows)

- **SQL Server** (Developer/Express edition) + **SQL Server Management Studio (SSMS)** — hosts both databases, runs all `.sql` scripts.
- **Python 3.x** with `pip install -r etl/python/requirements.txt` (uses `pyodbc`, `requests`, `reverse_geocoder`, `pandas`) + **ODBC Driver for SQL Server**.
- **SQL Server Data Tools (SSDT)** for Visual Studio — to open/edit `etl/ssis/SeismicDisasterDWH_ETL.dtsx` (Integration Services project) and `ssas/SeismicRiskModel.bim` (Analysis Services Tabular project).
- **SQL Server Analysis Services (SSAS, Tabular mode)** instance — to deploy the `.bim` model.
- **Power BI Desktop** — to build the report, connect to the deployed SSAS model, and paste in `powerbi/dax_measures.dax`.
- **SQL Server Agent** (part of SQL Server, not Express) — to run `etl/sql/06_sql_agent_job.sql` for scheduled orchestration.

## Project Status (see memory: project_etl_progress)

Done: DWH schema, staging DB, Python extractors, all load stored procs, bridge matching, SSAS model, DAX measures, SSIS package, SQL Agent job.

Still needed: obtain EMDAT CSV (register at emdat.be) and run `extract_emdat.py`; deploy SSAS model and build the actual Power BI `.pbix` report (12 planned dashboards); write a functional tests document; final PDF report (see `KM1.pdf`, `Raport_KM2.pdf`, `STTM_tsunami.xlsx` for the original plan/spec).

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

#### SCD2 Trigger Mechanism

`usp_Load_DimGeography` only creates a new SCD2 version when `REF_CountryMaster.CountryName` itself changes (a manual/reference-data update, e.g. after an official ISO 3166 country-name-change notice). It does **not** react to the free-text `Country` fields in `STG_USGS_Raw`/`STG_EMDAT_Raw` — those names are inconsistent across sources, so `ISO3` against `REF_CountryMaster` is treated as the single source of truth. `etl/sql/07_scd2_demo.sql` demonstrates this by renaming three countries in `REF_CountryMaster` and re-running the load, producing two `DimGeography` versions per country.

## Design Conventions

- All tables carry `InsertDate` and `UpdateDate DATETIME DEFAULT GETDATE()` audit columns.
- Surrogate key types are sized to expected cardinality: `TINYINT` for small lookup tables, `SMALLINT` for medium, `INT`/`BIGINT` for large fact tables.
- `GEM_PGA_g` on `DimGeography` stores Global Earthquake Model peak ground acceleration values (seismic hazard).
- Geographic coordinates use `DECIMAL(8,5)` (lat) / `DECIMAL(9,5)` (lon) for ~1 m precision.
