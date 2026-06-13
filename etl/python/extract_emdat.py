"""
Load an EMDAT CSV export into staging table STG_EMDAT_Raw.

EMDAT requires a free account at emdat.be; export all fields for Disaster Type = Earthquake.
Place the downloaded file at config.EMDAT_FILE_PATH and run this script.

Monetary columns in EMDAT are denominated in $000 USD (adjusted). The script stores
them verbatim; the T-SQL stored procedure usp_Load_FactDisaster multiplies by 1 000
when inserting into FactDisaster (BIGINT columns represent full USD).

SSIS integration: Execute Process Task calling:
    python extract_emdat.py
"""

import sys
import logging
from pathlib import Path

import pandas as pd
import pyodbc

import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

# EMDAT 2023+ public export column names (strip whitespace on read)
EMDAT_COL_MAP = {
    "Dis No":                           "DisNo",
    "Year":                             "Year",
    "Disaster Group":                   "DisasterGroup",
    "Disaster Subgroup":                "DisasterSubgroup",
    "Disaster Type":                    "DisasterType",
    "Disaster Subtype":                 "DisasterSubtype",
    "Event Name":                       "EventName",
    "Country":                          "Country",
    "ISO":                              "ISO",
    "Region":                           "Region",
    "Continent":                        "Continent",
    "Location":                         "Location",
    "Origin":                           "Origin",
    "Latitude":                         "Latitude",
    "Longitude":                        "Longitude",
    "Start Year":                       "StartYear",
    "Start Month":                      "StartMonth",
    "Start Day":                        "StartDay",
    "End Year":                         "EndYear",
    "End Month":                        "EndMonth",
    "End Day":                          "EndDay",
    "Total Deaths":                     "TotalDeaths",
    "No Injured":                       "NoInjured",
    "No Affected":                      "NoAffected",
    "No Homeless":                      "NoHomeless",
    "Total Affected":                   "TotalAffected",
    "Reconstruction Costs, Adjusted ('000 US$)": "ReconstrCostsAdj",
    "Insured Damages, Adjusted ('000 US$)":      "InsuredDamagesAdj",
    "Total Damages, Adjusted ('000 US$)":        "TotalDamagesAdj",
    "Associated Dis":                   "AssociatedDis",
}


def _int_or_none(val) -> int | None:
    try:
        v = int(float(val))
        return v if v >= 0 else None
    except (TypeError, ValueError):
        return None


def _bigint_or_none(val) -> int | None:
    try:
        v = round(float(val))
        return v if v >= 0 else None
    except (TypeError, ValueError):
        return None


def _float_or_none(val) -> float | None:
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def load_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, dtype=str, encoding="utf-8-sig")
    df.columns = df.columns.str.strip()
    # Rename to canonical names where column exists
    rename = {k: v for k, v in EMDAT_COL_MAP.items() if k in df.columns}
    df = df.rename(columns=rename)
    # Keep only Earthquake disasters
    if "DisasterType" in df.columns:
        df = df[df["DisasterType"].str.strip().str.lower() == "earthquake"].copy()
    return df


def start_run(conn: pyodbc.Connection, source_file: str) -> int:
    cursor = conn.cursor()
    cursor.execute(
        """INSERT INTO ETL_RunLog (SourceSystem, RunStart, Status, ExtractFrom, ExtractTo)
           OUTPUT INSERTED.RunId VALUES ('EMDAT', GETDATE(), 'RUNNING', NULL, NULL)"""
    )
    run_id = cursor.fetchone()[0]
    conn.commit()
    return run_id


def finish_run(conn: pyodbc.Connection, run_id: int, loaded: int, error: str | None = None):
    status = "FAILED" if error else "SUCCESS"
    conn.cursor().execute(
        """UPDATE ETL_RunLog
           SET Status=?, RunEnd=GETDATE(), RowsLoaded=?, ErrorMessage=? WHERE RunId=?""",
        status, loaded, error, run_id,
    )
    conn.commit()


def load_to_staging(conn: pyodbc.Connection, df: pd.DataFrame, run_id: int) -> int:
    def _str(val, maxlen=None):
        if pd.isna(val) or val == "":
            return None
        s = str(val).strip()
        return s[:maxlen] if maxlen else s

    def _tsunami_flag(row) -> bool:
        assoc = str(row.get("AssociatedDis", "") or "").lower()
        return "tsunami" in assoc

    rows = []
    for _, r in df.iterrows():
        rows.append((
            _str(r.get("DisNo"), 20),
            _int_or_none(r.get("Year")),
            _str(r.get("DisasterGroup"), 30),
            _str(r.get("DisasterSubgroup"), 30),
            _str(r.get("DisasterType"), 30),
            _str(r.get("DisasterSubtype"), 30),
            _str(r.get("EventName"), 100),
            _str(r.get("Country"), 100),
            _str(r.get("ISO"), 3),
            _str(r.get("Region"), 30),
            _str(r.get("Continent"), 30),
            _str(r.get("Location"), 200),
            _str(r.get("Origin"), 100),
            _float_or_none(r.get("Latitude")),
            _float_or_none(r.get("Longitude")),
            _int_or_none(r.get("StartYear")),
            _int_or_none(r.get("StartMonth")),
            _int_or_none(r.get("StartDay")),
            _int_or_none(r.get("EndYear")),
            _int_or_none(r.get("EndMonth")),
            _int_or_none(r.get("EndDay")),
            _int_or_none(r.get("TotalDeaths")),
            _int_or_none(r.get("NoInjured")),
            _int_or_none(r.get("NoAffected")),
            _int_or_none(r.get("NoHomeless")),
            _int_or_none(r.get("TotalAffected")),
            _bigint_or_none(r.get("ReconstrCostsAdj")),
            _bigint_or_none(r.get("InsuredDamagesAdj")),
            _bigint_or_none(r.get("TotalDamagesAdj")),
            1 if _tsunami_flag(r) else 0,
            run_id,
        ))

    conn.cursor().executemany(
        """INSERT INTO STG_EMDAT_Raw (
               DisNo, [Year], DisasterGroup, DisasterSubgroup, DisasterType, DisasterSubtype,
               EventName, Country, ISO, Region, Continent, Location, Origin,
               Latitude, Longitude, StartYear, StartMonth, StartDay,
               EndYear, EndMonth, EndDay,
               TotalDeaths, NoInjured, NoAffected, NoHomeless, TotalAffected,
               ReconstrCostsAdj, InsuredDamagesAdj, TotalDamagesAdj,
               TsunamiFlag, LoadBatchId
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        rows,
    )
    conn.commit()
    return len(rows)


def run():
    emdat_path = Path(config.EMDAT_FILE_PATH)
    if not emdat_path.exists():
        log.error("EMDAT file not found: %s", emdat_path)
        log.error("Download the Earthquake export from https://www.emdat.be/ and place it there.")
        sys.exit(1)

    log.info("Reading EMDAT export: %s", emdat_path)
    df = load_csv(str(emdat_path))
    log.info("  %d earthquake disaster records after filtering.", len(df))

    conn = pyodbc.connect(config.connection_string(config.DB_STG_DATABASE))
    run_id = start_run(conn, str(emdat_path))

    try:
        loaded = load_to_staging(conn, df, run_id)
        finish_run(conn, run_id, loaded)
        log.info("EMDAT staging complete: %d rows loaded.", loaded)
    except Exception as exc:
        finish_run(conn, run_id, 0, str(exc)[:4000])
        log.error("EMDAT load failed: %s", exc)
        conn.close()
        sys.exit(1)

    conn.close()


if __name__ == "__main__":
    run()
