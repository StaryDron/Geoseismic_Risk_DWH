"""
Extract seismic events from USGS Earthquake Catalog REST API and load to staging.

Runs in incremental mode: queries ETL_RunLog for the last successful USGS run date
and fetches data from the next day forward. On first run loads config.USGS_START_YEAR.

Reverse-geocodes each event (lat/lon → ISO 3166-1 alpha-3). Events in international
waters receive code 'XIN'.

SSIS integration: invoke via Execute Process Task as
    python extract_usgs.py
The script exits with code 0 on success, 1 on failure.
"""

import sys
import logging
from datetime import date, datetime, timedelta
from io import StringIO

import pandas as pd
import pycountry
import pyodbc
import requests
import reverse_geocoder as rg

import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

USGS_CSV_COLUMNS = [
    "time", "latitude", "longitude", "depth", "mag", "magType",
    "nst", "gap", "dmin", "rms", "net", "id", "updated",
    "place", "type", "horizontalError", "depthError",
    "magError", "magNst", "status", "locationSource", "magSource",
]

_ISO2_TO_ISO3_CACHE: dict[str, str] = {}


def _iso2_to_iso3(code2: str) -> str:
    if code2 in _ISO2_TO_ISO3_CACHE:
        return _ISO2_TO_ISO3_CACHE[code2]
    try:
        iso3 = pycountry.countries.get(alpha_2=code2).alpha_3
    except AttributeError:
        iso3 = "XIN"
    _ISO2_TO_ISO3_CACHE[code2] = iso3
    return iso3


def reverse_geocode(lats: list, lons: list) -> list[str]:
    coords = list(zip(lats, lons))
    results = rg.search(coords, verbose=False)
    return [_iso2_to_iso3(r.get("cc", "")) if r.get("cc") else "XIN" for r in results]


def fetch_usgs_year(year: int) -> pd.DataFrame:
    """
    Query one calendar year at M>=USGS_MIN_MAGNITUDE. The M4.5+ rate is
    ~6 000-8 000 events/year globally – well within the 20 000-row API cap.
    """
    params = {
        "format": "csv",
        "starttime": f"{year}-01-01",
        "endtime": f"{year}-12-31T23:59:59",
        "minmagnitude": config.USGS_MIN_MAGNITUDE,
        "eventtype": "earthquake",
        "orderby": "time-asc",
    }
    r = requests.get(config.USGS_API_URL, params=params, timeout=config.USGS_REQUEST_TIMEOUT)
    r.raise_for_status()
    df = pd.read_csv(StringIO(r.text), low_memory=False)
    if len(df) >= 19_900:
        log.warning("Year %d returned %d rows – approaching 20 000 API limit!", year, len(df))
    return df


def get_last_load_date(conn: pyodbc.Connection) -> date:
    row = conn.cursor().execute(
        "SELECT MAX(ExtractTo) FROM ETL_RunLog WHERE SourceSystem='USGS' AND Status='SUCCESS'"
    ).fetchone()
    return row[0] if row and row[0] else date(config.USGS_START_YEAR - 1, 12, 31)


def start_run(conn: pyodbc.Connection, extract_from: date, extract_to: date) -> int:
    cursor = conn.cursor()
    cursor.execute(
        """INSERT INTO ETL_RunLog (SourceSystem, RunStart, Status, ExtractFrom, ExtractTo)
           OUTPUT INSERTED.RunId
           VALUES ('USGS', GETDATE(), 'RUNNING', ?, ?)""",
        extract_from, extract_to,
    )
    run_id = cursor.fetchone()[0]
    conn.commit()
    return run_id


def finish_run(conn: pyodbc.Connection, run_id: int, loaded: int, rejected: int, error: str | None = None):
    status = "FAILED" if error else "SUCCESS"
    conn.cursor().execute(
        """UPDATE ETL_RunLog
           SET Status=?, RunEnd=GETDATE(), RowsLoaded=?, RowsRejected=?, ErrorMessage=?
           WHERE RunId=?""",
        status, loaded, rejected, error, run_id,
    )
    conn.commit()


def insert_rejected(conn: pyodbc.Connection, run_id: int, rows: list[tuple]):
    conn.cursor().executemany(
        "INSERT INTO STG_USGS_Rejected (LoadBatchId, EventId, RejectReason, RawRecord) VALUES (?,?,?,?)",
        rows,
    )
    conn.commit()


def load_to_staging(conn: pyodbc.Connection, df: pd.DataFrame, run_id: int) -> int:
    def _f(val):
        return None if pd.isna(val) else val

    rows = [
        (
            str(row["time"])[:30],
            _f(row.get("latitude")),
            _f(row.get("longitude")),
            _f(row.get("depth")),
            _f(row.get("mag")),
            str(row.get("magType", "") or "")[:5],
            _f(row.get("nst")),
            _f(row.get("gap")),
            _f(row.get("dmin")),
            _f(row.get("rms")),
            str(row.get("net", "") or "")[:5],
            str(row.get("id", "") or "")[:20],
            str(row.get("updated", "") or "")[:30],
            str(row.get("place", "") or "")[:200],
            str(row.get("type", "") or "")[:20],
            _f(row.get("horizontalError")),
            _f(row.get("depthError")),
            _f(row.get("magError")),
            _f(row.get("magNst")),
            str(row.get("status", "") or "")[:10],
            str(row.get("locationSource", "") or "")[:5],
            str(row.get("magSource", "") or "")[:5],
            str(row.get("ISO3", "XIN"))[:3],
            run_id,
        )
        for _, row in df.iterrows()
    ]
    conn.cursor().executemany(
        """INSERT INTO STG_USGS_Raw (
               SrcTime, Latitude, Longitude, Depth, Mag, MagType, Nst, Gap, Dmin, Rms,
               Net, EventId, Updated, Place, EventType, HorizontalError, DepthError,
               MagError, MagNst, [Status], LocationSource, MagSource, ISO3, LoadBatchId
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        rows,
    )
    conn.commit()
    return len(rows)


def run():
    conn = pyodbc.connect(config.connection_string(config.DB_STG_DATABASE))
    last_date = get_last_load_date(conn)
    start_year = last_date.year + (1 if last_date >= date(last_date.year, 12, 31) else 0)
    end_year = config.USGS_END_YEAR

    if start_year > end_year:
        log.info("Staging is up to date (last load: %s). Nothing to do.", last_date)
        conn.close()
        return

    run_id = start_run(conn, date(start_year, 1, 1), date(end_year, 12, 31))
    total_loaded = total_rejected = 0

    try:
        for year in range(start_year, end_year + 1):
            log.info("Fetching USGS data for %d ...", year)
            df = fetch_usgs_year(year)

            if df.empty:
                log.info("  No events returned for %d.", year)
                continue

            # Reverse geocode valid coordinates
            valid = df["latitude"].notna() & df["longitude"].notna()
            df["ISO3"] = "XIN"
            if valid.any():
                df.loc[valid, "ISO3"] = reverse_geocode(
                    df.loc[valid, "latitude"].tolist(),
                    df.loc[valid, "longitude"].tolist(),
                )

            # Separate rejects (invalid coordinates or missing core fields)
            bad = df[
                df["latitude"].isna() | df["longitude"].isna() |
                df["mag"].isna() | df["depth"].isna() |
                (df["latitude"].abs() > 90) | (df["longitude"].abs() > 180)
            ]
            good = df.drop(bad.index)

            if not bad.empty:
                rej_rows = [
                    (run_id, str(r.get("id", ""))[:20],
                     "Missing or out-of-range coordinate/magnitude/depth",
                     str(r.to_dict())[:4000])
                    for _, r in bad.iterrows()
                ]
                insert_rejected(conn, run_id, rej_rows)
                total_rejected += len(bad)

            loaded = load_to_staging(conn, good, run_id)
            total_loaded += loaded
            log.info("  Year %d: %d loaded, %d rejected.", year, loaded, len(bad))

        finish_run(conn, run_id, total_loaded, total_rejected)
        log.info("Done. Total loaded: %d, rejected: %d.", total_loaded, total_rejected)

    except Exception as exc:
        finish_run(conn, run_id, total_loaded, total_rejected, str(exc)[:4000])
        log.error("Extraction failed: %s", exc)
        conn.close()
        sys.exit(1)

    conn.close()


if __name__ == "__main__":
    run()
