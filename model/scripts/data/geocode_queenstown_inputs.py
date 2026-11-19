#!/usr/bin/env python3
"""Geocode HDB blocks, MOE schools and supermarkets with the OneMap search API.

Inputs (raw, stored by download_queenstown_inputs.py):
    planning-evidence/queenstown/hdb-property-information.csv
    planning-evidence/queenstown/moe-general-information-of-schools.csv
    planning-evidence/queenstown/nea-supermarket-licences.csv

Outputs (derived, written next to the inputs, each with a sidecar):
    hdb-blocks-geocoded-derived.csv      residential blocks in candidate HDB towns
    moe-schools-geocoded-derived.csv     all MOE schools (island-wide)
    supermarkets-geocoded-derived.csv    all licensed supermarkets (island-wide)

OneMap endpoint (no token needed):
    https://www.onemap.gov.sg/api/common/elastic/search?searchVal=<q>&returnGeom=Y&getAddrDetails=Y&pageNum=1
Raw OneMap responses are cached as JSON in CACHE_DIR (outside the project) so
reruns do not hit the API again.

Match rules (match_quality column):
  HDB blocks, query "<blk_no> <street>":
    exact          a result has BLK_NO == blk_no and a ROAD_NAME equal to the
                   street after expanding HDB abbreviations; all such results
                   share one coordinate (to 1 m)
    ambiguous      as exact, but matching results disagree on coordinates by
                   more than 1 m; the first matching result is used
    unmatched      no result has the same block number and road name
  Schools and supermarkets, query "<postal code>":
    exact          every result with POSTAL == postal code lies within 1 m of
                   the first (several building names at one point are fine)
    ambiguous      results with that postal code are more than 1 m apart; the
                   first is used and max_spread_m records the spread
    unmatched      no result carries that postal code

Usage (from the assessment4 directory):
    python3 -I model/scripts/data/geocode_queenstown_inputs.py planning-evidence/queenstown <cache_dir> [hdb[=TOWN,...]] [schools[=DGP_PLANNING_AREA,...]] [supermarkets]
"""
import concurrent.futures
import csv
import datetime
import hashlib
import json
import math
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ONEMAP = "https://www.onemap.gov.sg/api/common/elastic/search?searchVal={q}&returnGeom=Y&getAddrDetails=Y&pageNum=1"
USER_AGENT = "sph5105-a4-geocode"
PAUSE_S = 1.0  # unauthenticated OneMap search returns HTTP 429 above roughly 1 call per second
WORKERS = 1

# HDB town codes whose blocks could lie inside the URA Queenstown planning area.
# QT Queenstown, BM Bukit Merah, CL Clementi, BT Bukit Timah.
CANDIDATE_TOWNS = {"QT", "BM", "CL", "BT"}

# HDB abbreviations -> OneMap full words (applied token by token to both sides).
ABBREV = {
    "AVE": "AVENUE", "RD": "ROAD", "ST": "STREET", "DR": "DRIVE", "CRES": "CRESCENT",
    "CL": "CLOSE", "PL": "PLACE", "NTH": "NORTH", "STH": "SOUTH", "UPP": "UPPER",
    "LOR": "LORONG", "JLN": "JALAN", "BT": "BUKIT", "TG": "TANJONG", "KG": "KAMPONG",
    "CTRL": "CENTRAL", "PK": "PARK", "TER": "TERRACE", "HTS": "HEIGHTS", "MKT": "MARKET",
    "GDNS": "GARDENS", "CTR": "CENTRE", "C'WEALTH": "COMMONWEALTH", "CWEALTH": "COMMONWEALTH",
    "STR": "STREET", "WAY": "WAY", "LINK": "LINK", "SQ": "SQUARE", "BLVD": "BOULEVARD",
    "HWY": "HIGHWAY", "GRN": "GREEN", "RISE": "RISE", "VW": "VIEW", "WALK": "WALK",
    "MT": "MOUNT", "ADMIRALTY": "ADMIRALTY", "E": "EAST", "W": "WEST", "C": "CENTRAL",
    "INDL": "INDUSTRIAL", "ESTATE": "ESTATE", "PASIR": "PASIR", "TAMAN": "TAMAN",
    "CRSE": "COURSE", "CT": "COURT", "GR": "GROVE", "GRV": "GROVE",
}


def normalize_road(name):
    tokens = re.sub(r"[^A-Z0-9' ]", " ", name.upper()).split()
    return " ".join(ABBREV.get(t, t) for t in tokens).replace("'", "")


def onemap_search(query, cache_dir):
    """Return the parsed OneMap response for query, using the on-disk cache."""
    key = hashlib.sha1(query.encode()).hexdigest()
    path = cache_dir / f"{key}.json"
    if path.exists():
        return json.loads(path.read_text())["response"]
    url = ONEMAP.format(q=urllib.parse.quote(query))
    for attempt in range(1, 15):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.loads(resp.read())
            break
        except urllib.error.HTTPError as err:
            if err.code == 429 or err.code >= 500:
                time.sleep(2 * attempt)
                continue
            raise
    else:
        raise RuntimeError(f"OneMap gave up for {query!r}")
    path.write_text(json.dumps({"query": query, "url": url, "response": body}))
    time.sleep(PAUSE_S)
    return body


def dist_m(a, b):
    return math.hypot(float(a["X"]) - float(b["X"]), float(a["Y"]) - float(b["Y"]))


def summarize(matches):
    """Pick the first match and classify agreement among all matches."""
    if not matches:
        return {"match_quality": "unmatched", "n_matches": 0, "max_spread_m": ""}
    first = matches[0]
    spread = max(dist_m(first, m) for m in matches)
    return {
        "match_quality": "exact" if spread <= 1.0 else "ambiguous",
        "n_matches": len(matches),
        "max_spread_m": round(spread, 1),
        "svy21_x": first["X"], "svy21_y": first["Y"],
        "latitude": first["LATITUDE"], "longitude": first["LONGITUDE"],
        "matched_address": first["ADDRESS"], "matched_postal": first["POSTAL"],
        "matched_building": first["BUILDING"],
    }


def geocode_hdb(row, cache_dir):
    query = f"{row['blk_no']} {row['street']}"
    resp = onemap_search(query, cache_dir)
    want_road = normalize_road(row["street"])
    matches = [r for r in resp.get("results", [])
               if r["BLK_NO"].upper() == row["blk_no"].upper()
               and normalize_road(r["ROAD_NAME"]) == want_road]
    return {"onemap_query": query, "onemap_found": resp.get("found", 0), **summarize(matches)}


def geocode_postal(postal, cache_dir):
    postal = postal.strip().zfill(6)
    resp = onemap_search(postal, cache_dir)
    matches = [r for r in resp.get("results", []) if r["POSTAL"] == postal]
    return {"onemap_query": postal, "onemap_found": resp.get("found", 0), **summarize(matches)}


GEO_COLS = ["onemap_query", "onemap_found", "match_quality", "n_matches", "max_spread_m",
            "svy21_x", "svy21_y", "latitude", "longitude",
            "matched_address", "matched_postal", "matched_building"]


def read_csv(path):
    with path.open(newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def write_csv(path, rows, cols):
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="raise")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_sidecar(path, inputs, rows, method, purpose):
    counts = {}
    for r in rows:
        counts[r["match_quality"]] = counts.get(r["match_quality"], 0) + 1
    side = {
        "source": "derived",
        "derived_from": [{"file": p.name, "sha256": sha256(p)} for p in inputs],
        "script": "model/scripts/data/geocode_queenstown_inputs.py",
        "geocoder": ONEMAP.replace("{q}", "<query>"),
        "retrieval_date": datetime.date.today().isoformat(),
        "rows": len(rows),
        "match_quality_counts": counts,
        "method": method,
        "sha256": sha256(path),
        "purpose": purpose,
    }
    path.with_name(path.name.rsplit(".", 1)[0] + ".source.json").write_text(json.dumps(side, indent=2) + "\n")
    print(f"{path.name}: {len(rows)} rows, {counts}")


def prefetch(queries, cache_dir):
    """Fill the cache for all queries using a few concurrent workers."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(lambda q: onemap_search(q, cache_dir), sorted(set(queries))))


def run_hdb(ev, cache_dir, towns):
    src = ev / "hdb-property-information.csv"
    blocks = [r for r in read_csv(src) if r["bldg_contract_town"] in towns and r["residential"] == "Y"]
    prefetch([f"{b['blk_no']} {b['street']}" for b in blocks], cache_dir)
    out = [{**b, **geocode_hdb(b, cache_dir)} for b in blocks]
    path = ev / "hdb-blocks-geocoded-derived.csv"
    write_csv(path, out, list(blocks[0].keys()) + GEO_COLS)
    write_sidecar(
        path, [src], out,
        method=("Rows of hdb-property-information.csv with bldg_contract_town in "
                f"{sorted(towns)} and residential == 'Y', unchanged, plus OneMap "
                "geocode columns. Query '<blk_no> <street>'; a result matches when BLK_NO equals blk_no and "
                "ROAD_NAME equals street after expanding HDB abbreviations (ABBREV table in the script). "
                "exact: all matches within 1 m; ambiguous: matches more than 1 m apart, first used; "
                "unmatched: no match. Coordinates are SVY21 (EPSG:3414) X/Y and WGS84 lat/long from OneMap."),
        purpose="Candidate HDB block locations; clipped to the Queenstown planning area by build_queenstown_geography.R.",
    )


def run_postal(ev, cache_dir, src_name, out_name, postal_col, label, dgp=None):
    src = ev / src_name
    rows = [r for r in read_csv(src) if dgp is None or r["dgp_code"].strip().upper() in dgp]
    prefetch([r[postal_col].strip().zfill(6) for r in rows], cache_dir)
    out = [{**r, **geocode_postal(r[postal_col], cache_dir)} for r in rows]
    path = ev / out_name
    write_csv(path, out, list(rows[0].keys()) + GEO_COLS)
    write_sidecar(
        path, [src], out,
        method=((f"All rows of {src_name}" if dgp is None else
                 f"Rows of {src_name} with dgp_code (planning area) in {sorted(dgp)}") + ", unchanged, plus OneMap geocode columns. Query is the 6-digit "
                f"{postal_col} (zero padded); a result matches when POSTAL equals it. exact: all matches within "
                "1 m; ambiguous: matches more than 1 m apart, first used; unmatched: no match. Coordinates are "
                "SVY21 (EPSG:3414) X/Y and WGS84 lat/long from OneMap."),
        purpose=f"{label} locations; clipped to Queenstown (plus buffer) by build_queenstown_geography.R.",
    )


def parse_targets(targets):
    """'hdb' or 'hdb=QT,BT'; 'schools' or 'schools=QUEENSTOWN,CLEMENTI'; 'supermarkets'."""
    out = {}
    for t in targets:
        name, _, vals = t.partition("=")
        out[name] = set(v.strip().upper() for v in vals.split(",")) if vals else None
    return out


def main(ev_dir, cache_dir, targets):
    ev = pathlib.Path(ev_dir)
    cache = pathlib.Path(cache_dir)
    cache.mkdir(parents=True, exist_ok=True)
    targets = parse_targets(targets)
    if "hdb" in targets:
        run_hdb(ev, cache, targets["hdb"] or CANDIDATE_TOWNS)
    if "schools" in targets:
        run_postal(ev, cache, "moe-general-information-of-schools.csv", "moe-schools-geocoded-derived.csv",
                   "postal_code", "MOE school", dgp=targets["schools"])
    if "supermarkets" in targets:
        run_postal(ev, cache, "nea-supermarket-licences.csv", "supermarkets-geocoded-derived.csv",
                   "postal_code", "Licensed supermarket")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:] or ["hdb", "schools", "supermarkets"])
