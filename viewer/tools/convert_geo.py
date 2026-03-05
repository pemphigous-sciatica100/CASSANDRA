#!/usr/bin/env python3
"""Convert Natural Earth GeoJSON → compact binary for the Zig viewer.

Binary format:
  Header:  num_regions (u32)
  Per region:
    name_len (u16), name (utf8 bytes)
    iso_a2 (2 bytes, zero-padded)
    centroid_x (f32), centroid_y (f32)
    num_polygons (u16)
    Per polygon:
      num_points (u32)
      [x: f32, y: f32] × num_points

Projection: equirectangular (lon→x, lat→y), scaled to fit ~-30..+30 world space.
"""

import json
import struct
import sys
from pathlib import Path

GEOJSON = Path(__file__).parent / "ne_110m_admin_0_countries.geojson"
OUTPUT = Path(__file__).parent.parent / "data" / "world.bin"

# Scale factor: map lon [-180,180] → [-30,30], lat [-90,90] → [-15,15]
SCALE = 30.0 / 180.0


def extract_polygons(geometry):
    """Return list of polygon rings (list of [lon, lat] lists)."""
    t = geometry["type"]
    coords = geometry["coordinates"]
    if t == "Polygon":
        return [coords[0]]  # outer ring only
    elif t == "MultiPolygon":
        return [poly[0] for poly in coords]  # outer ring of each
    return []


def centroid(polygons):
    """Simple centroid: average of all vertices."""
    sx, sy, n = 0.0, 0.0, 0
    for ring in polygons:
        for lon, lat, *_ in ring:
            sx += lon
            sy += lat
            n += 1
    return (sx / n * SCALE, -sy / n * SCALE) if n else (0.0, 0.0)


def main():
    with open(GEOJSON) as f:
        geo = json.load(f)

    features = geo["features"]
    buf = bytearray()

    # Placeholder for num_regions
    buf += struct.pack("<I", 0)
    num_regions = 0

    for feat in features:
        props = feat["properties"]
        geom = feat["geometry"]
        if geom is None:
            continue

        name = (props.get("NAME") or props.get("ADMIN") or "").encode("utf-8")
        iso = (props.get("ISO_A2") or "--").encode("ascii")[:2].ljust(2, b"-")

        polygons = extract_polygons(geom)
        if not polygons:
            continue

        cx, cy = centroid(polygons)

        # name
        buf += struct.pack("<H", len(name))
        buf += name
        # iso
        buf += iso
        # centroid
        buf += struct.pack("<ff", cx, cy)
        # num_polygons
        buf += struct.pack("<H", len(polygons))

        for ring in polygons:
            points = [(lon * SCALE, -lat * SCALE) for lon, lat, *_ in ring]
            buf += struct.pack("<I", len(points))
            for x, y in points:
                buf += struct.pack("<ff", x, y)

        num_regions += 1

    # Patch header
    struct.pack_into("<I", buf, 0, num_regions)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(buf)
    print(f"Wrote {num_regions} regions, {len(buf)} bytes → {OUTPUT}")


if __name__ == "__main__":
    main()
