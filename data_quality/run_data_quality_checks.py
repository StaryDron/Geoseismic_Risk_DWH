"""
Data quality analysis for SeismicDisasterDWH (+ staging for uniqueness checks).

Groups checks into completeness, validity, consistency/integrity and uniqueness,
distinguishing genuine defects from inherent source sparsity and feed-scope
limitations. Saves PNG charts and an interpretive markdown report under
data_quality/output/ for the final project report.

Usage: python run_data_quality_checks.py
"""

import os
import sys
import warnings

warnings.filterwarnings("ignore", message="pandas only supports SQLAlchemy")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import pyodbc

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "etl", "python"))
import config

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "output")

GREEN, AMBER, RED, BLUE = "#2a9d8f", "#e9c46a", "#e76f51", "#264653"

# Columns defined in the schema but not provided by the USGS CSV feed
# (mmi / sig / cdi live in the GeoJSON feed only) — reported separately so
# the completeness chart measures genuinely-sourced attributes.
GEOJSON_ONLY = ["ModifiedMercalliIntensity", "SignificanceScore", "CommunityDecimalIntensity"]


def connect(database):
    return pyodbc.connect(config.connection_string(database))


def q(conn, sql):
    return pd.read_sql(sql, conn)


def threshold_color(pct):
    return GREEN if pct >= 95 else AMBER if pct >= 50 else RED


# ----------------------------------------------------------------------------- checks
def row_counts(conn):
    tables = ["FactSeismic", "FactDisaster", "BridgeDisasterSeismic", "DimGeography",
              "DimDate", "DimMagnitude", "DimSeismicDepth", "DimSeverityDeaths",
              "DimSeverityAffected"]
    return pd.DataFrame(
        [{"Tabela": t, "Liczba wierszy": q(conn, f"SELECT COUNT(*) n FROM dbo.{t}").iat[0, 0]}
         for t in tables])


def temporal_coverage(conn):
    s = q(conn, "SELECT MIN(d.[Date]) a, MAX(d.[Date]) b FROM FactSeismic f "
                "JOIN DimDate d ON d.DateKey=f.DateKey")
    d = q(conn, "SELECT MIN(d.[Date]) a, MAX(d.[Date]) b FROM FactDisaster f "
                "JOIN DimDate d ON d.DateKey=f.StartDate")
    return s.iat[0, 0], s.iat[0, 1], d.iat[0, 0], d.iat[0, 1]


# Surrogate/FK keys and audit timestamps are always 100% populated by
# construction, so they're excluded from the completeness charts — only
# measure/attribute columns are interesting there.
FACT_EXCLUDE = {
    "FactSeismic": ["SeismicKey", "DateKey", "GeographyKey", "MagnitudeKey",
                    "SeismicDepthKey", "InsertDate", "UpdateDate"],
    "FactDisaster": ["DisasterKey", "StartDate", "EndDate", "GeographyKey",
                     "SeverityDeathsKey", "SeverityAffectedKey", "InsertDate", "UpdateDate"],
}


def completeness_table(conn, table):
    cols = q(conn, "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
                   f"WHERE TABLE_NAME='{table}' ORDER BY ORDINAL_POSITION")["COLUMN_NAME"].tolist()
    cols = [c for c in cols if c not in FACT_EXCLUDE.get(table, [])]
    selects = ", ".join(f"AVG(CASE WHEN [{c}] IS NULL THEN 1.0 ELSE 0 END) AS [{c}]" for c in cols)
    row = q(conn, f"SELECT {selects} FROM {table}").iloc[0]
    df = pd.DataFrame({
        "Kolumna": cols,
        "% wypełnienia": [(1 - (row[c] or 0)) * 100 for c in cols],
    })
    return df.sort_values("% wypełnienia", ascending=True)


def tsunami_share(conn):
    return q(conn, "SELECT Tsunami, COUNT(*) n FROM FactDisaster GROUP BY Tsunami")


def top_countries_seismic(conn, n=10):
    return q(conn, f"""
        SELECT TOP {n} g.CountryName, COUNT(*) n
        FROM FactSeismic f JOIN DimGeography g ON g.GeographyKey = f.GeographyKey
        WHERE g.ISO <> 'XIN'
        GROUP BY g.CountryName ORDER BY n DESC
    """)


def top_countries_deaths(conn, n=10):
    return q(conn, f"""
        SELECT TOP {n} g.CountryName, SUM(f.TotalDeaths) deaths
        FROM FactDisaster f JOIN DimGeography g ON g.GeographyKey = f.GeographyKey
        WHERE f.TotalDeaths IS NOT NULL AND g.ISO <> 'XIN'
        GROUP BY g.CountryName ORDER BY deaths DESC
    """)


def geography_resolution(conn):
    sql = """
        SELECT src, CASE WHEN ISO='XIN' THEN 1 ELSE 0 END is_xin, COUNT(*) n FROM (
            SELECT 'FactSeismic' src, g.ISO FROM FactSeismic f
                JOIN DimGeography g ON g.GeographyKey=f.GeographyKey
            UNION ALL
            SELECT 'FactDisaster' src, g.ISO FROM FactDisaster f
                JOIN DimGeography g ON g.GeographyKey=f.GeographyKey
        ) x GROUP BY src, CASE WHEN ISO='XIN' THEN 1 ELSE 0 END
    """
    return q(conn, sql)


def magnitudes(conn):
    return q(conn, "SELECT Magnitude FROM FactSeismic WHERE Magnitude IS NOT NULL")


def validity_checks(conn):
    mag_bad = q(conn, "SELECT COUNT(*) n FROM FactSeismic WHERE Magnitude < 0 OR Magnitude > 10").iat[0, 0]
    lat_bad = q(conn, "SELECT COUNT(*) n FROM FactSeismic WHERE Latitude < -90 OR Latitude > 90").iat[0, 0]
    lon_bad = q(conn, "SELECT COUNT(*) n FROM FactSeismic WHERE Longitude < -180 OR Longitude > 180").iat[0, 0]
    date_bad = q(conn, "SELECT COUNT(*) n FROM FactDisaster WHERE EndDate < StartDate").iat[0, 0]
    neg_deaths = q(conn, "SELECT COUNT(*) n FROM FactDisaster WHERE TotalDeaths < 0").iat[0, 0]
    return [
        ("Magnitude w zakresie [0, 10]", mag_bad),
        ("Szerokość geogr. w [-90, 90]", lat_bad),
        ("Długość geogr. w [-180, 180]", lon_bad),
        ("EndDate >= StartDate (katastrofy)", date_bad),
        ("TotalDeaths >= 0", neg_deaths),
    ]


def events_per_year(conn):
    return q(conn, "SELECT d.[Year] yr, COUNT(*) n FROM FactSeismic f "
                   "JOIN DimDate d ON d.DateKey=f.DateKey GROUP BY d.[Year] ORDER BY d.[Year]")


def bridge_coverage(conn):
    df = q(conn, """
        SELECT d.DisasterKey, COUNT(b.SeismicKey) n
        FROM FactDisaster d LEFT JOIN BridgeDisasterSeismic b ON b.DisasterKey=d.DisasterKey
        GROUP BY d.DisasterKey""")
    df["bucket"] = pd.cut(df["n"], [-1, 0, 1, 5, 10, 10**6], labels=["0", "1", "2-5", "6-10", ">10"])
    return df


def staging_dupes(conn):
    u = q(conn, "SELECT COUNT(*) n FROM (SELECT EventId FROM STG_USGS_Raw "
                "GROUP BY EventId HAVING COUNT(*)>1) x").iat[0, 0]
    e = q(conn, "SELECT COUNT(*) n FROM (SELECT DisNo FROM STG_EMDAT_Raw "
                "GROUP BY DisNo HAVING COUNT(*)>1) x").iat[0, 0]
    return u, e


# ----------------------------------------------------------------------------- charts
def chart_completeness(comp, table, filename):
    fig, ax = plt.subplots(figsize=(8, max(3, 0.4 * len(comp))))
    colors = [threshold_color(v) for v in comp["% wypełnienia"]]
    ax.barh(comp["Kolumna"], comp["% wypełnienia"], color=colors)
    for y, v in enumerate(comp["% wypełnienia"]):
        ax.text(min(v + 1.5, 92), y, f"{v:.1f}%", va="center", fontsize=8)
    ax.set_xlim(0, 100)
    ax.set_xlabel("% wierszy z wartością (nie NULL)")
    ax.set_title(f"Kompletność atrybutów — {table} (rosnąco)")
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, filename), dpi=120)
    plt.close(fig)


def chart_tsunami_share(ts):
    labels = {0: "Inne katastrofy", 1: "Tsunami"}
    colors = {0: BLUE, 1: RED}
    fig, ax = plt.subplots(figsize=(5, 4))
    vals = [int(ts[ts["Tsunami"] == k]["n"].sum()) for k in (0, 1)]
    total = sum(vals) or 1
    ax.bar([labels[0], labels[1]], vals, color=[colors[0], colors[1]])
    for i, v in enumerate(vals):
        ax.text(i, v, f"{v}\n({v/total*100:.1f}%)", ha="center", va="bottom", fontsize=9)
    ax.set_title("Udział katastrof tsunami w FactDisaster")
    ax.set_ylabel("Liczba katastrof")
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "tsunami_share.png"), dpi=120)
    plt.close(fig)


def chart_top_countries(df, value_col, title, xlabel, filename, color=BLUE):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    df = df.iloc[::-1]
    bars = ax.barh(df["CountryName"], df[value_col], color=color)
    ax.bar_label(bars, fmt="%d", fontsize=8)
    ax.set_title(title)
    ax.set_xlabel(xlabel)
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, filename), dpi=120)
    plt.close(fig)


def chart_geography(geo):
    fig, ax = plt.subplots(figsize=(8, 3.2))
    srcs = ["FactSeismic", "FactDisaster"]
    for i, src in enumerate(srcs):
        sub = geo[geo["src"] == src]
        resolved = int(sub[sub["is_xin"] == 0]["n"].sum())
        xin = int(sub[sub["is_xin"] == 1]["n"].sum())
        total = resolved + xin or 1
        rp, xp = resolved / total * 100, xin / total * 100
        ax.barh(i, rp, color=GREEN, label="Rozpoznany kraj (ISO3)" if i == 0 else "")
        ax.barh(i, xp, left=rp, color=RED, label="Wody międzynar. (XIN)" if i == 0 else "")
        ax.text(rp / 2, i, f"{rp:.1f}%\n({resolved:,})", va="center", ha="center",
                color="white", fontsize=9)
        if xp > 4:
            ax.text(rp + xp / 2, i, f"{xp:.1f}%\n({xin:,})", va="center", ha="center",
                    color="white", fontsize=9)
    ax.set_yticks(range(len(srcs)))
    ax.set_yticklabels(srcs)
    ax.set_xlim(0, 100)
    ax.set_xlabel("Udział wierszy [%]")
    ax.set_title("Rozpoznanie geograficzne (proporcja, etykiety = liczby bezwzględne)")
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, -0.45), ncol=2, frameon=False)
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "geography_resolution.png"), dpi=120)
    plt.close(fig)


def chart_magnitude(mag):
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.hist(mag["Magnitude"], bins=30, color=BLUE)
    ax.axvline(config.USGS_MIN_MAGNITUDE, color=RED, linestyle="--",
               label=f"Próg pozyskiwania M{config.USGS_MIN_MAGNITUDE}")
    ax.set_title("Rozkład magnitudo (FactSeismic)")
    ax.set_xlabel("Magnitude")
    ax.set_ylabel("Liczba zdarzeń")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "magnitude_distribution.png"), dpi=120)
    plt.close(fig)


def chart_events_per_year(epy):
    fig, ax = plt.subplots(figsize=(8, 3.8))
    ax.bar(epy["yr"].astype(int), epy["n"], color=BLUE)
    ax.set_title("Zdarzenia sejsmiczne wg roku (ciągłość pokrycia)")
    ax.set_xlabel("Rok")
    ax.set_ylabel("Liczba zdarzeń")
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "events_per_year.png"), dpi=120)
    plt.close(fig)


def chart_bridge(bridge):
    counts = bridge["bucket"].value_counts().reindex(["0", "1", "2-5", "6-10", ">10"]).fillna(0)
    colors = [RED] + [GREEN] * 4
    fig, ax = plt.subplots(figsize=(7, 4))
    bars = ax.bar(counts.index.astype(str), counts.values, color=colors)
    ax.bar_label(bars, fmt="%d")
    ax.set_title("Dopasowane zdarzenia sejsmiczne na katastrofę")
    ax.set_xlabel("Liczba dopasowań w BridgeDisasterSeismic (100 km / 3 dni)")
    ax.set_ylabel("Liczba katastrof")
    fig.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "bridge_coverage.png"), dpi=120)
    plt.close(fig)


# ----------------------------------------------------------------------------- report
def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    dwh, stg = connect(config.DB_DWH_DATABASE), connect(config.DB_STG_DATABASE)

    counts = row_counts(dwh)
    s_min, s_max, d_min, d_max = temporal_coverage(dwh)
    comp_seismic = completeness_table(dwh, "FactSeismic")
    comp_disaster = completeness_table(dwh, "FactDisaster")
    geo = geography_resolution(dwh)
    mag = magnitudes(dwh)
    validity = validity_checks(dwh)
    epy = events_per_year(dwh)
    bridge = bridge_coverage(dwh)
    dup_u, dup_e = staging_dupes(stg)
    tsunami = tsunami_share(dwh)
    top_countries_seis = top_countries_seismic(dwh)
    top_countries_dth = top_countries_deaths(dwh)

    chart_completeness(comp_seismic, "FactSeismic", "completeness_factseismic.png")
    chart_completeness(comp_disaster, "FactDisaster", "completeness_factdisaster.png")
    chart_geography(geo)
    chart_magnitude(mag)
    chart_events_per_year(epy)
    chart_bridge(bridge)
    chart_tsunami_share(tsunami)
    chart_top_countries(top_countries_seis, "n", "Top 10 krajów wg liczby zdarzeń sejsmicznych",
                         "Liczba zdarzeń", "top_countries_seismic.png")
    chart_top_countries(top_countries_dth, "deaths", "Top 10 krajów wg ofiar śmiertelnych (FactDisaster)",
                         "Liczba ofiar śmiertelnych", "top_countries_deaths.png", color=RED)

    no_bridge = int((bridge["n"] == 0).sum())
    n_dis = len(bridge)
    seis_xin = int(geo[(geo.src == "FactSeismic") & (geo.is_xin == 1)]["n"].sum())
    seis_tot = int(geo[geo.src == "FactSeismic"]["n"].sum())

    L = []
    w = L.append
    w("# Analiza jakości danych — SeismicDisasterDWH\n")
    w("Analiza obejmuje hurtownię `SeismicDisasterDWH` (warstwa prezentacji) oraz "
      "warstwę staging (`SeismicDisasterSTG`) na potrzeby kontroli unikalności. "
      "Dane sejsmiczne pochodzą z USGS, dane o katastrofach z EM-DAT.\n")
    w(f"**Pokrycie czasowe:** zdarzenia sejsmiczne {s_min}–{s_max}, "
      f"katastrofy {d_min}–{d_max}.\n")

    w("## 1. Liczność tabel\n")
    w(counts.to_markdown(index=False) + "\n")

    w("## 2. Kompletność atrybutów\n")
    w("Dla każdej tabeli faktów wykres pokazuje % wierszy z wartością (nie NULL) dla "
      "każdej kolumny-atrybutu, sortowane rosnąco. Kolumny kluczy (surogatów, FK) i "
      "znaczniki audytowe (`InsertDate`/`UpdateDate`) są zawsze w 100% wypełnione z "
      "definicji, więc zostały wyłączone. Kolor: zielony ≥95%, pomarańczowy 50–95%, "
      "czerwony <50%.\n")
    w("### 2.1 FactSeismic\n")
    w(comp_seismic.to_markdown(index=False, floatfmt=".1f") + "\n")
    w("![Kompletność FactSeismic](completeness_factseismic.png)\n")
    w(f"- Kolumny `{'`, `'.join(GEOJSON_ONLY)}` pochodzą z feedu **GeoJSON** USGS (od "
      "06.2026 ekstraktor pobiera ten format zamiast CSV). `SignificanceScore` jest "
      "wyliczany przez USGS dla każdego zdarzenia (100%). `ModifiedMercalliIntensity` i "
      "`CommunityDecimalIntensity` pochodzą z systemu „Did You Feel It?” (zgłoszenia "
      "obywateli) i istnieją tylko dla zdarzeń odczuwalnych przez ludzi — niskie "
      "wypełnienie (7-16%) jest naturalną właściwością tych danych, nie błędem ETL.\n")
    w("### 2.2 FactDisaster\n")
    w(comp_disaster.to_markdown(index=False, floatfmt=".1f") + "\n")
    w("![Kompletność FactDisaster](completeness_factdisaster.png)\n")
    w("- `TotalDamageAdj` i `InsuredDamage` mają niskie wypełnienie — to **naturalna "
      "rzadkość danych źródłowych** EM-DAT (dane finansowe raportowane tylko dla części "
      "katastrof), nie błąd ETL. Podobnie `NumHomeless`, `NumOtherAffected` i `NumInjuries` "
      "są raportowane tylko dla części zdarzeń.\n")

    w("## 3. Walidność (reguły zakresowe)\n")
    w("| Reguła | Liczba naruszeń | Wynik |\n|---|---:|:--:|")
    for name, bad in validity:
        w(f"| {name} | {bad} | {'✅ PASS' if bad == 0 else '❌ FAIL'} |")
    w("")
    w("![Rozkład magnitudo](magnitude_distribution.png)\n")
    w(f"Rozkład magnitudo zaczyna się od progu pozyskiwania M{config.USGS_MIN_MAGNITUDE} "
      "(filtr API USGS), co jest zgodne z założeniem projektu.\n")

    w("## 4. Spójność i integralność\n")
    w("### 4.1 Rozpoznanie geograficzne (ISO3 vs XIN)\n")
    w("![Geografia](geography_resolution.png)\n")
    w(f"Ok. {seis_xin/seis_tot*100:.1f}% zdarzeń sejsmicznych ({seis_xin:,} z {seis_tot:,}) "
      "ma kod `XIN` (wody międzynarodowe). To **oczekiwane** — wiele trzęsień ziemi "
      "występuje na strefach subdukcji pod oceanami; reverse-geocoding przypisuje im "
      "umowny kod oceaniczny. Katastrofy EM-DAT są niemal w całości przypisane do krajów.\n")
    w("### 4.2 Pokrycie tabeli mostkowej\n")
    w("![Pokrycie mostka](bridge_coverage.png)\n")
    w(f"{no_bridge} z {n_dis} katastrof nie ma żadnego dopasowanego zdarzenia sejsmicznego "
      "w oknie 100 km / 3 dni. Wynika to z braku współrzędnych w części rekordów EM-DAT "
      "oraz z katastrof spoza zakresu magnitudo USGS (M≥4.5).\n")

    w("## 5. Unikalność i wykryte defekty\n")
    w(f"- Zduplikowane `EventId` w `STG_USGS_Raw`: **{dup_u}**.\n")
    w(f"- Zduplikowane `DisNo` w `STG_EMDAT_Raw`: **{dup_e}**.\n")
    w("**Wykryty i naprawiony defekt:** pierwotnie EM-DAT został załadowany dwukrotnie "
      "(przed dodaniem deduplikacji po `DisNo` w `extract_emdat.py`), co podwajało "
      "`FactDisaster` (1396 zamiast 698) i tabelę mostkową. Naprawiono skryptem "
      "`fix_emdat_duplication.sql`; ekstraktor obecnie deduplikuje rekordy przy wejściu "
      "do stagingu, więc defekt się nie powtórzy.\n")

    w("## 6. Profil danych — kontekst biznesowy\n")
    w("### 6.1 Udział katastrof tsunami\n")
    w("![Udział tsunami](tsunami_share.png)\n")
    tsu_n = int(tsunami[tsunami['Tsunami'] == 1]['n'].sum())
    tsu_tot = int(tsunami['n'].sum())
    w(f"{tsu_n} z {tsu_tot} katastrof ({tsu_n/tsu_tot*100:.1f}%) ma ustawioną flagę "
      "`Tsunami=1` — pozwala to wyodrębnić podzbiór katastrof tsunami, kluczowy dla "
      "tematu hurtowni, niezależnie od ogólnej analizy sejsmicznej.\n")
    w("### 6.2 Geografia zdarzeń sejsmicznych i ofiar\n")
    w("![Top kraje sejsmiczne](top_countries_seismic.png)\n")
    w("Kraje o najwyższej liczbie zarejestrowanych zdarzeń sejsmicznych M≥4.5 — "
      "zgodnie z oczekiwaniami dominują kraje leżące na granicach płyt tektonicznych "
      "(Pacyficzny Pierścień Ognia).\n")
    w("![Top kraje ofiary](top_countries_deaths.png)\n")
    w("Kraje z największą sumą ofiar śmiertelnych w `FactDisaster` — istotny widok "
      "dla analizy ryzyka, często odmienny od rankingu samej liczby zdarzeń sejsmicznych "
      "(zależy od gęstości zaludnienia, infrastruktury i typu katastrofy).\n")

    path = os.path.join(OUTPUT_DIR, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print("\n".join(L))
    print(f"\nRaport i wykresy zapisane w {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
