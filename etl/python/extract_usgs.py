"""
Extract seismic events from the USGS Earthquake Catalog REST API into STG_USGS_Raw.

Runs incrementally based on ETL_RunLog, always re-querying the current year
(per-event EventId dedup avoids duplicates). Reverse-geocodes lat/lon to
ISO3; ocean events get 'XIN'. Invoked by SSIS via Execute Process Task.
"""

import sys
import logging
from datetime import date

import truststore
truststore.inject_into_ssl()

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

# Properties pulled from each GeoJSON feature; geometry gives lon/lat/depth
USGS_GEOJSON_PROPS = [
    "time", "mag", "magType", "nst", "gap", "dmin", "rms", "net", "updated",
    "place", "type", "horizontalError", "depthError", "magError", "magNst",
    "status", "locationSource", "magSource", "mmi", "sig", "cdi",
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
    GeoJSON format is used so mmi/sig/cdi (not present in the CSV feed) are
    available alongside the standard fields.
    """
    params = {
        "format": "geojson",
        "starttime": f"{year}-01-01",
        "endtime": f"{year}-12-31T23:59:59",
        "minmagnitude": config.USGS_MIN_MAGNITUDE,
        "eventtype": "earthquake",
        "orderby": "time-asc",
    }
    r = requests.get(config.USGS_API_URL, params=params, timeout=config.USGS_REQUEST_TIMEOUT)
    r.raise_for_status()
    features = r.json()["features"]
    if len(features) >= 19_900:
        log.warning("Year %d returned %d rows – approaching 20 000 API limit!", year, len(features))

    rows = []
    for feat in features:
        props = feat["properties"]
        lon, lat, depth = (feat["geometry"]["coordinates"] + [None, None, None])[:3]
        row = {k: props.get(k) for k in USGS_GEOJSON_PROPS}
        row["id"] = feat.get("id")
        row["latitude"] = lat
        row["longitude"] = lon
        row["depth"] = depth
        row["time"] = pd.to_datetime(row["time"], unit="ms", utc=True).isoformat() if row["time"] is not None else None
        row["updated"] = pd.to_datetime(row["updated"], unit="ms", utc=True).isoformat() if row["updated"] is not None else None
        rows.append(row)
    return pd.DataFrame(rows)


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

    existing_ids = {row[0] for row in conn.cursor().execute("SELECT EventId FROM STG_USGS_Raw")}
    df = df[~df["id"].astype(str).isin(existing_ids)]
    if df.empty:
        return 0

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
            _f(row.get("mmi")),
            _f(row.get("sig")),
            _f(row.get("cdi")),
            str(row.get("ISO3", "XIN"))[:3],
            run_id,
        )
        for _, row in df.iterrows()
    ]
    conn.cursor().executemany(
        """INSERT INTO STG_USGS_Raw (
               SrcTime, Latitude, Longitude, Depth, Mag, MagType, Nst, Gap, Dmin, Rms,
               Net, EventId, Updated, Place, EventType, HorizontalError, DepthError,
               MagError, MagNst, [Status], LocationSource, MagSource, Mmi, Sig, Cdi, ISO3, LoadBatchId
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        rows,
    )
    conn.commit()
    return len(rows)


def run():
    conn = pyodbc.connect(config.connection_string(config.DB_STG_DATABASE))
    today = date.today()
    last_date = get_last_load_date(conn)
    end_year = max(config.USGS_END_YEAR, today.year)
    # A past year is only "done" once its ExtractTo reached Dec 31. The
    # current (in-progress) year is always re-queried; per-event dedup in
    # load_to_staging() prevents duplicates.
    start_year = last_date.year + (1 if last_date >= date(last_date.year, 12, 31) else 0)
    start_year = min(start_year, today.year)

    if start_year > end_year:
        log.info("Staging is up to date (last load: %s). Nothing to do.", last_date)
        conn.close()
        return

    extract_to = today if end_year == today.year else date(end_year, 12, 31)
    run_id = start_run(conn, date(start_year, 1, 1), extract_to)
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
