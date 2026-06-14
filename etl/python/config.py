DB_SERVER           = 'localhost'
DB_STG_DATABASE     = 'SeismicDisasterSTG'
DB_DWH_DATABASE     = 'SeismicDisasterDWH'
DB_TRUSTED_CONNECTION = True   # Windows auth; set False and fill below for SQL auth
DB_USERNAME         = 'sa'
DB_PASSWORD         = ''

USGS_API_URL        = 'https://earthquake.usgs.gov/fdsnws/event/1/query'
USGS_MIN_MAGNITUDE  = 4.5      # M4.5+ captures virtually all EMDAT-relevant events
USGS_START_YEAR     = 2000
USGS_END_YEAR       = 2024
USGS_REQUEST_TIMEOUT = 60      # seconds

EMDAT_FILE_PATH     = r'C:\DWH_Landing\emdat_earthquake_export.csv'

BRIDGE_RADIUS_KM    = 100      # max epicentre-to-disaster distance
BRIDGE_WINDOW_DAYS  = 3        # max days seismic event precedes disaster


def connection_string(database: str) -> str:
    base = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={DB_SERVER};DATABASE={database};"
    if DB_TRUSTED_CONNECTION:
        return base + "Trusted_Connection=yes;"
    return base + f"UID={DB_USERNAME};PWD={DB_PASSWORD};"
