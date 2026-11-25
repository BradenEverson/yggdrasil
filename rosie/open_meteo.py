import json
import time
import urllib.error
import urllib.parse
import urllib.request

import numpy as np
import pandas as pd
import xarray as xr

from region import HAVENWOODS

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"

FORECAST_VARIABLES = [
    "temperature_2m",
    "relative_humidity_2m",
    "dew_point_2m",
    "precipitation",
    "rain",
    "snowfall",
    "wind_speed_10m",
    "wind_direction_10m",
    "wind_gusts_10m",
    "vapour_pressure_deficit",
    "et0_fao_evapotranspiration",
    "shortwave_radiation",
    "cloud_cover",
    "surface_pressure",
    "soil_moisture_0_to_1cm",
    "soil_moisture_3_to_9cm",
    "soil_moisture_9_to_27cm",
    "soil_temperature_0cm",
]

ARCHIVE_VARIABLES = [
    "temperature_2m",
    "relative_humidity_2m",
    "dew_point_2m",
    "precipitation",
    "rain",
    "snowfall",
    "wind_speed_10m",
    "wind_direction_10m",
    "wind_gusts_10m",
    "vapour_pressure_deficit",
    "et0_fao_evapotranspiration",
    "shortwave_radiation",
    "cloud_cover",
    "surface_pressure",
    "soil_moisture_0_to_7cm",
    "soil_moisture_7_to_28cm",
    "soil_temperature_0_to_7cm",
]

WIND_VARIABLES = ["wind_speed_10m", "wind_direction_10m", "wind_gusts_10m"]

MAX_LOCATIONS_PER_REQUEST = 100
RETRIES = 4


def _get(url, params):
    query = urllib.parse.urlencode(params, safe=",")
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(f"{url}?{query}", timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if e.code == 429 or e.code >= 500:
                if attempt + 1 < RETRIES:
                    time.sleep(2 ** attempt * 5)
                    continue
            raise RuntimeError(f"Open-Meteo {e.code}: {body}") from None


def _fetch(url, lats, lons, variables, units, extra):
    params = {
        "hourly": ",".join(variables),
        "timezone": "UTC",
        "timeformat": "unixtime",
        "temperature_unit": units["temperature"],
        "wind_speed_unit": units["wind_speed"],
        "precipitation_unit": units["precipitation"],
        **extra,
    }
    results = []
    for i in range(0, len(lats), MAX_LOCATIONS_PER_REQUEST):
        chunk_lats = lats[i:i + MAX_LOCATIONS_PER_REQUEST]
        chunk_lons = lons[i:i + MAX_LOCATIONS_PER_REQUEST]
        data = _get(url, {
            **params,
            "latitude": ",".join(f"{v:.5f}" for v in chunk_lats),
            "longitude": ",".join(f"{v:.5f}" for v in chunk_lons),
        })
        results.extend(data if isinstance(data, list) else [data])
    return results


def _to_dataset(results, lats, lons, shape):
    times = pd.to_datetime(results[0]["hourly"]["time"], unit="s")
    variables = [k for k in results[0]["hourly"] if k != "time"]
    dims = ("time",) + (("lat", "lon") if shape else ())

    def stack(values):
        arr = np.array(values, dtype="float64")
        if not shape:
            return arr[0]
        return np.moveaxis(arr.reshape(shape + (arr.shape[1],)), -1, 0)

    data_vars = {}
    for name in variables:
        series = [[np.nan if v is None else v for v in r["hourly"][name]] for r in results]
        data_vars[name] = (dims, stack(series), {"units": results[0]["hourly_units"][name]})

    coords = {"time": times}
    meta = {
        "model_lat": [r["latitude"] for r in results],
        "model_lon": [r["longitude"] for r in results],
        "elevation": [r["elevation"] for r in results],
    }
    if shape:
        coords["lat"] = lats
        coords["lon"] = lons
        for name, values in meta.items():
            coords[name] = (("lat", "lon"), np.array(values, dtype="float64").reshape(shape))
    else:
        for name, values in meta.items():
            coords[name] = values[0]
    return xr.Dataset(data_vars, coords=coords)


def _points(region, spacing_km):
    if spacing_km is None:
        lat, lon = region.center
        return [lat], [lon], [lat], [lon], ()
    lats, lons = region.grid(spacing_km)
    flat_lats = [lat for lat in lats for _ in lons]
    flat_lons = [lon for _ in lats for lon in lons]
    return flat_lats, flat_lons, lats, lons, (len(lats), len(lons))


def _units(temperature, wind_speed, precipitation):
    return {"temperature": temperature, "wind_speed": wind_speed, "precipitation": precipitation}


def forecast(region=HAVENWOODS, variables=FORECAST_VARIABLES, days=7, past_days=0, spacing_km=None,
             model="best_match", temperature_unit="celsius", wind_speed_unit="ms", precipitation_unit="mm"):
    flat_lats, flat_lons, lats, lons, shape = _points(region, spacing_km)
    results = _fetch(
        FORECAST_URL, flat_lats, flat_lons, variables,
        _units(temperature_unit, wind_speed_unit, precipitation_unit),
        {"forecast_days": days, "past_days": past_days, "models": model},
    )
    ds = _to_dataset(results, lats, lons, shape)
    ds.attrs.update(source="open-meteo forecast", model=model, region=region.name)
    return ds


def history(start, end, region=HAVENWOODS, variables=ARCHIVE_VARIABLES, spacing_km=None,
            temperature_unit="celsius", wind_speed_unit="ms", precipitation_unit="mm"):
    flat_lats, flat_lons, lats, lons, shape = _points(region, spacing_km)
    results = _fetch(
        ARCHIVE_URL, flat_lats, flat_lons, variables,
        _units(temperature_unit, wind_speed_unit, precipitation_unit),
        {"start_date": str(start), "end_date": str(end)},
    )
    ds = _to_dataset(results, lats, lons, shape)
    ds.attrs.update(source="open-meteo archive (ERA5)", region=region.name)
    return ds


def add_wind_components(ds, speed="wind_speed_10m", direction="wind_direction_10m"):
    rad = np.deg2rad(ds[direction])
    units = ds[speed].attrs.get("units")
    ds["wind_u_10m"] = (-ds[speed] * np.sin(rad)).assign_attrs(units=units, description="eastward component")
    ds["wind_v_10m"] = (-ds[speed] * np.cos(rad)).assign_attrs(units=units, description="northward component")
    return ds


def wind_map(region=HAVENWOODS, buffer_km=10.0, spacing_km=3.0, days=2, past_days=0, model="best_match", wind_speed_unit="ms"):
    ds = forecast(
        region.buffered(buffer_km), variables=WIND_VARIABLES, days=days, past_days=past_days,
        spacing_km=spacing_km, model=model, wind_speed_unit=wind_speed_unit,
    )
    return add_wind_components(ds)
