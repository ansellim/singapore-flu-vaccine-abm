#!/usr/bin/env python3
"""Download the raw public inputs for the Queenstown real-geography extension.

Every file is written to planning-evidence/queenstown/ exactly as served (raw
datastore_search JSON for Census tables, the GeoJSON or CSV file behind the
data.gov.sg poll-download endpoint for everything else). Each file gets a
sidecar <name>.source.json with the same fields as the existing sidecars in
planning-evidence/: source, dataset_page, title, retrieval_date, rows or
features, sha256 of the stored file, purpose.

Usage (from the assessment4 directory):
    python3 -I model/scripts/data/download_queenstown_inputs.py planning-evidence/queenstown

Existing files are skipped, so the script can be rerun after a failure.
Unauthenticated data.gov.sg calls are rate limited (about 5 per minute); the
script sleeps between calls and backs off on HTTP 429.
"""
import csv
import datetime
import hashlib
import io
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

USER_AGENT = "sph5105-a4-data-download"
PAUSE_S = 13  # stays under 5 requests per minute

# (file stem, dataset id, purpose). Census tables are fetched via datastore_search.
CENSUS_TABLES = [
    ("households-dwelling-type-pa-census2020", "d_388f9c61f437a588b47b008a012d13fa",
     "Queenstown households by type of dwelling: HDB flat-type mix and number of private (condominium, landed) households."),
    ("households-size-pa-census2020", "d_0ef47f84a0776b27010b242038ea2c6b",
     "Queenstown household size distribution for household synthesis."),
    ("households-structure-pa-census2020", "d_ce1804c655566f5089fff370bec37c2d",
     "Queenstown household structure (family nuclei, generations) for household synthesis."),
    ("households-tenancy-pa-census2020", "d_1ca435a3b62aafa6857d96368971765b",
     "Queenstown households by tenancy (owner, tenant); context for rental flat occupancy."),
    ("population-dwelling-type-subzone-census2020", "d_7f243956483d5901f237e6f87b096636",
     "Resident population by subzone and type of dwelling: allocates persons to HDB versus private housing per subzone."),
    ("population-age-floor-area-subzone-census2020", "d_9e035622439b5d25a63d7ea0699c9451",
     "Resident population by subzone, age group and floor area of residence: links age structure to dwelling size."),
    ("labour-force-status-sex-pa-census2020", "d_e9b1f437263fceebc0c1f0e60cd7b0f0",
     "Queenstown residents aged 15+ by labour force status and sex: employed fraction for workplace assignment."),
    ("employed-residence-transport-pa-census2020", "d_1f8f5ec7201964e365c77551cab99503",
     "Employed Queenstown residents by usual mode of transport to work: commuting outside-exposure context."),
    ("employed-residence-traveltime-pa-census2020", "d_9ebad44ae5f9dff4ccc577a59ac4b208",
     "Employed Queenstown residents by travelling time to work: proxy for work inside versus outside the planning area."),
    ("employed-residence-industry-pa-census2020", "d_a9b684696b39023c4b12f13e57aa2dfd",
     "Employed Queenstown residents by industry: workplace type mix (e.g. health and social services)."),
    ("employed-workplace-age-sex-pa-census2020", "d_22063c84778e6535b92b4d8f93fd2525",
     "Employed residents working in Queenstown by age and sex: size of the inbound working population."),
    ("employed-workplace-transport-pa-census2020", "d_f6ddbf6228d561454e27dd158846c688",
     "Employed residents working in Queenstown by mode of transport."),
    ("employed-workplace-traveltime-pa-census2020", "d_8ec1d0f5a86e5492f98e8598d6d258d1",
     "Employed residents working in Queenstown by travelling time to work."),
    ("employed-workplace-transport-region-of-residence-census2020", "d_5b38192e9c6f8d2c5f38c70939c76e71",
     "Workers in Queenstown by planning region of residence: the only public origin-destination breakdown (region, not planning area)."),
    ("students-transport-pa-census2020", "d_9eaccc6cc0f257cfd74d5c1ceb0fb663",
     "Queenstown resident students by usual mode of transport to school: school catchment context."),
    ("students-traveltime-pa-census2020", "d_6fce8e61bf5c5ce7ad36f770cb0faf78",
     "Queenstown resident students by travelling time to school: proxy for schooling inside versus outside the planning area."),
]

# (file stem, dataset id, extension, purpose). Fetched via poll-download.
FILE_DATASETS = [
    ("mp2019-subzone-boundary-nosea", "d_8594ae9ff96d0c708bc2af633048edfb", "geojson",
     "Subzone polygons (MP2019); Queenstown subzones carry Census 2020 resident counts."),
    ("mp2019-planning-area-boundary-nosea", "d_4765db0e87b9c86336792efe8a1f7a66", "geojson",
     "Official MP2019 planning-area polygons; Queenstown boundary for clipping."),
    ("mp2019-land-use", "d_90d86daa5bfaa371668b84fa5f01424f", "geojson",
     "MP2019 land-use polygons (island-wide); clipped to Queenstown for workplace and amenity zoning."),
    ("hdb-property-information", "d_17f5382f26140b1fdae0ba2ef6239d2f", "csv",
     "Block-level HDB dwelling units by flat type; residential blocks are household locations."),
    ("moe-general-information-of-schools", "d_688b934f82c1059ed0a6993d2a829089", "csv",
     "MOE schools with postal codes and main level; geocoded for school locations."),
    ("ecda-preschools-location", "d_61eefab99958fd70e6aab17320a71f1c", "geojson",
     "Preschool (childcare and kindergarten) point locations."),
    ("nea-hawker-centres", "d_4a086da0a5553be1d89383cd90d07ecd", "geojson",
     "Hawker centre point locations: community mixing venues."),
    ("pa-community-clubs", "d_f706de1427279e61fe41e89e24d440fa", "geojson",
     "Community club point locations: community mixing venues."),
    ("nea-supermarket-licences", "d_11edd0117280c5776651d7891114c88c", "csv",
     "NEA supermarket licences with postal codes; geocoded for supermarket locations (community mixing venues)."),
]


def http_get(url, max_attempts=8):
    """GET a URL, backing off on HTTP 429 and transient 5xx; raise otherwise."""
    for attempt in range(1, max_attempts + 1):
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                return resp.read()
        except urllib.error.HTTPError as err:
            if err.code == 429 or err.code >= 500:
                wait = 20 * attempt
                print(f"  HTTP {err.code} for {url}; retry {attempt} in {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise
    raise RuntimeError(f"Gave up after {max_attempts} attempts: {url}")


def dataset_title(dataset_id):
    meta = json.loads(http_get(f"https://api-production.data.gov.sg/v2/public/api/datasets/{dataset_id}/metadata"))
    if meta.get("code") != 0:
        raise RuntimeError(f"Metadata error for {dataset_id}: {meta}")
    return meta["data"]["name"]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def count_items(path, kind):
    """Return (key, count): rows for tabular files, features for GeoJSON."""
    if kind == "datastore":
        result = json.loads(path.read_text())["result"]
        n = len(result["records"])
        if n != result["total"]:
            raise RuntimeError(f"{path.name}: got {n} records but total is {result['total']} (increase limit)")
        return "rows", n
    if kind == "csv":
        with path.open(newline="", encoding="utf-8-sig") as fh:
            return "rows", sum(1 for _ in csv.DictReader(fh))
    if kind == "geojson":
        return "features", len(json.loads(path.read_text())["features"])
    raise ValueError(kind)


def write_sidecar(path, source, dataset_id, title, kind, purpose, extra=None):
    key, n = count_items(path, kind)
    side = {
        "source": source,
        "dataset_page": f"https://data.gov.sg/datasets/{dataset_id}/view",
        "title": title,
        "retrieval_date": datetime.date.today().isoformat(),
        key: n,
        "sha256": sha256(path),
        "purpose": purpose,
    }
    side.update(extra or {})
    path.with_name(path.name.rsplit(".", 1)[0] + ".source.json").write_text(json.dumps(side, indent=2) + "\n")
    print(f"  stored {path.name}: {key}={n}")


def fetch_census(out_dir, stem, dataset_id, purpose):
    path = out_dir / f"{stem}.json"
    if path.exists():
        print(f"skip {path.name}")
        return
    url = f"https://data.gov.sg/api/action/datastore_search?resource_id={dataset_id}&limit=10000"
    body = http_get(url)
    if not json.loads(body).get("success"):
        raise RuntimeError(f"datastore_search failed for {dataset_id}")
    path.write_bytes(body)
    time.sleep(PAUSE_S)
    title = dataset_title(dataset_id)
    write_sidecar(path, url, dataset_id, title, "datastore", purpose)
    time.sleep(PAUSE_S)


def fetch_file(out_dir, stem, dataset_id, ext, purpose):
    path = out_dir / f"{stem}.{ext}"
    if path.exists():
        print(f"skip {path.name}")
        return
    poll_url = f"https://api-open.data.gov.sg/v1/public/api/datasets/{dataset_id}/poll-download"
    poll = json.loads(http_get(poll_url))
    if poll.get("code") != 0 or "url" not in poll.get("data", {}):
        raise RuntimeError(f"poll-download failed for {dataset_id}: {poll}")
    time.sleep(PAUSE_S)
    body = http_get(poll["data"]["url"])
    path.write_bytes(body)
    title = dataset_title(dataset_id)
    write_sidecar(
        path, poll_url, dataset_id, title, ext, purpose,
        extra={"download_method": "GET source -> data.url (signed, expires in one hour) -> file stored unchanged"},
    )
    time.sleep(PAUSE_S)


def main(out_dir):
    out_dir = pathlib.Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for stem, dataset_id, ext, purpose in FILE_DATASETS:
        print(f"file {stem}")
        fetch_file(out_dir, stem, dataset_id, ext, purpose)
    for stem, dataset_id, purpose in CENSUS_TABLES:
        print(f"census {stem}")
        fetch_census(out_dir, stem, dataset_id, purpose)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
