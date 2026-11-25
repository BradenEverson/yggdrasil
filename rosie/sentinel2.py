from datetime import timedelta

import numpy as np
import pandas as pd
import xarray as xr
from odc.stac import load as stac_load
from pyproj import Transformer
from pystac_client import Client

from region import HAVENWOODS

STAC_URL = "https://earth-search.aws.element84.com/v1"
COLLECTION = "sentinel-2-c1-l2a"

BANDS = {
    "blue": "B02",
    "green": "B03",
    "red": "B04",
    "rededge1": "B05",
    "rededge2": "B06",
    "rededge3": "B07",
    "nir": "B08",
    "nir08": "B8A",
    "swir16": "B11",
    "swir22": "B12",
}

SCL_INVALID = {
    0: "no_data",
    1: "saturated",
    3: "cloud_shadow",
    8: "cloud_medium",
    9: "cloud_high",
    10: "thin_cirrus",
    11: "snow",
}

INDEX_DESCRIPTIONS = {
    "ndvi": "Normalized Difference Vegetation Index (B08, B04): greenness and canopy vigour",
    "evi": "Enhanced Vegetation Index (B08, B04, B02): greenness that saturates less than NDVI in dense canopy",
    "ndre": "Normalized Difference Red Edge (B8A, B05): chlorophyll, early stress before NDVI moves",
    "ndmi": "Normalized Difference Moisture Index (B08, B11): canopy water content, drought stress",
    "msi": "Moisture Stress Index (B11 / B08): rises as vegetation dries",
    "ndwi": "Normalized Difference Water Index, McFeeters (B03, B08): open water and saturated ground",
    "nbr": "Normalized Burn Ratio (B08, B12): burn scars, fuel condition; difference two dates for dNBR",
    "bsi": "Bare Soil Index (B11, B04, B08, B02): exposed soil, disturbance, trails",
}


def _client():
    return Client.open(STAC_URL)


def search(start, end, region=HAVENWOODS, max_cloud=60):
    items = _client().search(
        collections=[COLLECTION],
        bbox=region.bbox,
        datetime=f"{start}/{end}",
        query={"eo:cloud_cover": {"lt": max_cloud}},
    ).item_collection()
    return sorted(items, key=lambda item: item.datetime)


def solar_day(when, lon):
    return (pd.Timestamp(when).tz_localize(None) + timedelta(hours=lon / 15.0)).date()


def _band_scaling(items, band, lon):
    scaling = {}
    for item in items:
        raster = item.assets[band].extra_fields.get("raster:bands", [{}])[0]
        scaling.setdefault(solar_day(item.datetime, lon), (raster.get("scale", 1.0), raster.get("offset", 0.0)))
    return scaling


def _scl_valid(scl, mask):
    return (scl != 0) & ~scl.isin(list(SCL_INVALID)) if mask else scl != 0


def _stac_load(items, bands, region, resolution, pool):
    return stac_load(
        items,
        bands=bands,
        bbox=region.bbox,
        crs=f"EPSG:{region.utm_epsg}",
        resolution=resolution,
        groupby="solar_day",
        resampling={"*": "bilinear", "scl": "nearest"},
        dtype="uint16",
        nodata=0,
        pool=pool,
    )


def _shadow(ds, threshold):
    bands = [b for b in ("blue", "green", "red", "nir", "swir16", "swir22") if b in ds]
    if threshold is None or not bands:
        return xr.zeros_like(ds[bands[0]] if bands else ds["scl"], dtype=bool)
    brightness = sum(ds[b] for b in bands) / len(bands)
    shadow = brightness < threshold
    if "green" in ds and "nir" in ds:
        shadow = shadow & (_nd(ds.green, ds.nir) < 0)
    return shadow


def load(start, end, region=HAVENWOODS, bands=tuple(BANDS), resolution=10, max_cloud=60,
         min_clear=0.6, mask=True, dark_threshold=0.04, items=None, pool=8):
    items = search(start, end, region, max_cloud) if items is None else items
    if not items:
        raise ValueError(f"No Sentinel-2 scenes over {region.name} between {start} and {end}")

    lon = region.center[1]
    screen = _stac_load(items, ["scl"], region, max(resolution, 20), pool)
    screen_clear = _scl_valid(screen["scl"], mask).mean(dim=("y", "x"))
    keep_days = {solar_day(t, lon) for t, c in zip(screen.time.values, screen_clear.values) if c >= min_clear}
    items = [item for item in items if solar_day(item.datetime, lon) in keep_days]
    if not items:
        raise ValueError(f"No scenes over {region.name} between {start} and {end} were at least {min_clear:.0%} clear")

    raw = _stac_load(items, list(bands) + ["scl"], region, resolution, pool)
    days = [solar_day(t, lon) for t in raw.time.values]
    scl = raw["scl"]
    valid = _scl_valid(scl, mask)

    ds = xr.Dataset(coords=raw.coords)
    for band in bands:
        scaling = _band_scaling(items, band, lon)
        scale = xr.DataArray([scaling[d][0] for d in days], dims="time", coords={"time": raw.time})
        offset = xr.DataArray([scaling[d][1] for d in days], dims="time", coords={"time": raw.time})
        reflectance = raw[band].astype("float32") * scale + offset
        ds[band] = reflectance.where((raw[band] != 0) & valid).astype("float32")
        ds[band].attrs.update(units="reflectance", sentinel2_band=BANDS.get(band, band))

    if mask:
        shadow = _shadow(ds, dark_threshold)
        valid = valid & ~shadow
        for band in bands:
            ds[band] = ds[band].where(~shadow)

    ds["scl"] = scl
    ds["clear_fraction"] = valid.mean(dim=("y", "x"))
    ds = ds.sel(time=ds["clear_fraction"] >= min_clear)
    ds.attrs.update(source=f"{STAC_URL} {COLLECTION}", region=region.name, crs=f"EPSG:{region.utm_epsg}")
    return ds


def _nd(a, b):
    return (a - b) / (a + b)


def indices(ds, which=tuple(INDEX_DESCRIPTIONS)):
    out = {}
    calc = {
        "ndvi": lambda: _nd(ds.nir, ds.red),
        "evi": lambda: 2.5 * (ds.nir - ds.red) / (ds.nir + 6.0 * ds.red - 7.5 * ds.blue + 1.0),
        "ndre": lambda: _nd(ds.nir08, ds.rededge1),
        "ndmi": lambda: _nd(ds.nir, ds.swir16),
        "msi": lambda: ds.swir16 / ds.nir,
        "ndwi": lambda: _nd(ds.green, ds.nir),
        "nbr": lambda: _nd(ds.nir, ds.swir22),
        "bsi": lambda: _nd(ds.swir16 + ds.red, ds.nir + ds.blue),
    }
    for name in which:
        out[name] = calc[name]().astype("float32").assign_attrs(description=INDEX_DESCRIPTIONS[name])
    result = xr.Dataset(out, coords=ds.coords)
    if "clear_fraction" in ds:
        result["clear_fraction"] = ds["clear_fraction"]
    result.attrs.update(ds.attrs)
    return result


def composite(ds, freq="MS"):
    return ds.drop_vars(["scl"], errors="ignore").resample(time=freq).median()


def sample(ds, points, window=1):
    crs = ds.attrs.get("crs") or str(ds.odc.crs)
    to_utm = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    names = list(points)
    xs, ys = zip(*(to_utm.transform(lon, lat) for lat, lon in (points[n] for n in names)))
    series = []
    for name, x, y in zip(names, xs, ys):
        ix = int(np.abs(ds.x.values - x).argmin())
        iy = int(np.abs(ds.y.values - y).argmin())
        half = window // 2
        patch = ds.isel(x=slice(max(0, ix - half), ix + half + 1), y=slice(max(0, iy - half), iy + half + 1))
        series.append(patch.drop_vars(["scl", "clear_fraction"], errors="ignore").mean(dim=("x", "y"), skipna=True))
    return xr.concat(series, dim=pd.Index(names, name="point"))
