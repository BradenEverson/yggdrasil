import math
from dataclasses import dataclass

KM_PER_DEG_LAT = 111.32


@dataclass(frozen=True)
class Region:
    name: str
    south: float
    west: float
    north: float
    east: float

    @property
    def center(self):
        return (self.south + self.north) / 2.0, (self.west + self.east) / 2.0

    @property
    def bbox(self):
        return self.west, self.south, self.east, self.north

    @property
    def utm_epsg(self):
        lat, lon = self.center
        zone = int((lon + 180.0) // 6.0) + 1
        return (32600 if lat >= 0 else 32700) + zone

    def _km_per_deg_lon(self):
        return KM_PER_DEG_LAT * math.cos(math.radians(self.center[0]))

    def buffered(self, km):
        dlat = km / KM_PER_DEG_LAT
        dlon = km / self._km_per_deg_lon()
        return Region(f"{self.name} +{km:g} km", self.south - dlat, self.west - dlon, self.north + dlat, self.east + dlon)

    def grid(self, spacing_km):
        rows = max(1, round((self.north - self.south) * KM_PER_DEG_LAT / spacing_km)) + 1
        cols = max(1, round((self.east - self.west) * self._km_per_deg_lon() / spacing_km)) + 1
        lats = [self.south + (self.north - self.south) * i / (rows - 1) for i in range(rows)]
        lons = [self.west + (self.east - self.west) * j / (cols - 1) for j in range(cols)]
        return lats, lons


HAVENWOODS = Region("Havenwoods State Forest", 43.1194308, -87.9832549, 43.1320066, -87.9664857)
