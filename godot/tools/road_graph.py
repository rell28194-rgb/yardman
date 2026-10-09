"""Persistent OSM topology and disjoint tile geometry in canonical metres.

Road identity is independent of mesh residency. OSM node references, rather
than geometric intersections, determine connectivity (including overpasses).
"""
from __future__ import annotations

import hashlib
import math
from collections import Counter, defaultdict


def partition_id(identifier: str) -> str:
    return hashlib.sha1(identifier.encode()).hexdigest()[:2]


def split_segment(a, b, size):
    """Yield (owner tile, start, end) with shared exact boundary samples."""
    if size <= 0 or not math.isfinite(size):
        raise ValueError("tile size must be finite and positive")
    cuts = {0.0, 1.0}
    for axis in (0, 2):
        start, end = a[axis], b[axis]
        if abs(end - start) < 1e-12:
            continue
        lo, hi = sorted((start, end))
        for k in range(math.floor(lo / size) + 1, math.ceil(hi / size)):
            t = (k * size - start) / (end - start)
            if 1e-12 < t < 1.0 - 1e-12:
                cuts.add(t)
    cuts = sorted(cuts)
    for u, v in zip(cuts, cuts[1:]):
        if v - u < 1e-12:
            continue
        p = tuple(a[i] + (b[i] - a[i]) * u for i in range(3))
        q = tuple(a[i] + (b[i] - a[i]) * v for i in range(3))
        mid = tuple((p[i] + q[i]) / 2 for i in range(3))
        yield (math.floor(mid[0] / size), math.floor(mid[2] / size)), p, q


def polygon_area(points):
    return abs(sum(a[0] * b[2] - b[0] * a[2]
                   for a, b in zip(points, points[1:] + points[:1]))) / 2


def clip_polygon(points, tx, tz, size):
    """Clip a road ribbon, including its width, to one tile's rectangle."""
    result = list(points)
    for axis, value, lower in ((0, tx * size, True), (0, (tx + 1) * size, False),
                               (2, tz * size, True), (2, (tz + 1) * size, False)):
        if not result:
            break
        output = []
        previous = result[-1]
        previous_in = previous[axis] >= value if lower else previous[axis] <= value
        for current in result:
            current_in = current[axis] >= value if lower else current[axis] <= value
            if previous_in != current_in:
                t = (value - previous[axis]) / (current[axis] - previous[axis])
                crossing = [previous[i] + t * (current[i] - previous[i]) for i in range(3)]
                crossing[axis] = value
                output.append(tuple(crossing))
            if current_in:
                output.append(current)
            previous, previous_in = current, current_in
        result = output
    # Coordinates are quantized once globally, not relative to each tile.
    result = [tuple(round(v, 6) for v in p) for p in result]
    clean = []
    for point in result:
        if not clean or clean[-1] != point:
            clean.append(point)
    if len(clean) > 1 and clean[0] == clean[-1]:
        clean.pop()
    return clean if len(clean) >= 3 and polygon_area(clean) > 1e-6 else []


def ribbon_tiles(a, b, width, size):
    dx, dz = b[0] - a[0], b[2] - a[2]
    length = math.hypot(dx, dz)
    if length < 0.001:
        return
    nx, nz = -dz / length * width / 2, dx / length * width / 2
    points = [(a[0] + nx, a[1], a[2] + nz),
              (a[0] - nx, a[1], a[2] - nz),
              (b[0] - nx, b[1], b[2] - nz),
              (b[0] + nx, b[1], b[2] + nz)]
    for tz in range(math.floor(min(p[2] for p in points) / size),
                    math.floor(max(p[2] for p in points) / size) + 1):
        for tx in range(math.floor(min(p[0] for p in points) / size),
                        math.floor(max(p[0] for p in points) / size) + 1):
            polygon = clip_polygon(points, tx, tz, size)
            if polygon:
                yield (tx, tz), polygon


def read_osm_features(path):
    import osmium

    class Roads(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.features = []

        def way(self, way):
            if "highway" not in way.tags:
                return
            try:
                coordinates = [[n.lon, n.lat] for n in way.nodes]
            except osmium.InvalidLocationError as exc:
                raise ValueError(f"Missing location in OSM way {way.id}") from exc
            self.features.append({
                "type": "Feature", "id": f"w{way.id}",
                "properties": dict(way.tags),
                "geometry": {"type": "LineString", "coordinates": coordinates},
                "osm_node_ids": [n.ref for n in way.nodes],
            })

    handler = Roads()
    handler.apply_file(str(path), locations=True)
    return handler.features


def _width(tags, fallback):
    try:
        text = str(tags.get("width", "")).strip().lower()
        value = float(text.removesuffix("m").strip())
        if math.isfinite(value) and 1.0 <= value <= 50.0:
            return value
    except ValueError:
        pass
    return fallback


def _direction(tags):
    value = str(tags.get("oneway", "")).lower()
    if value == "-1":
        return -1
    if value in {"yes", "1", "true"}:
        return 1
    if value in {"no", "0", "false"}:
        return 0
    return 1 if tags.get("junction") == "roundabout" else 0


def _speed(tags):
    text = str(tags.get("maxspeed", "")).lower().strip()
    try:
        value = float(text.removesuffix("mph").removesuffix("km/h").strip())
        if not math.isfinite(value) or value <= 0:
            return None
        return round(value * (0.44704 if "mph" in text else 1 / 3.6), 4)
    except ValueError:
        return None


def build_network(features, transformer, origin, tile_size, widths, classes,
                  flag_function, anchors, height_sampler=None):
    ways = []
    references = Counter()
    skipped = 0
    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        highway = tags.get("highway")
        if highway not in widths:
            skipped += bool(highway)
            continue
        geometry = feature.get("geometry") or {}
        lines = ([geometry.get("coordinates", [])] if geometry.get("type") == "LineString"
                 else geometry.get("coordinates", []) if geometry.get("type") == "MultiLineString" else [])
        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            # GeoJSON fallback is deliberately separate from genuine OSM IDs.
            signature = repr((lines, sorted(tags.items())))
            source_id = "geojson-" + hashlib.sha1(signature.encode()).hexdigest()[:20]
        for line_index, line in enumerate(lines):
            if len(line) < 2:
                continue
            points, refs = [], []
            osm_refs = feature.get("osm_node_ids", []) if len(lines) == 1 else []
            for i, coordinate in enumerate(line):
                e, n = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                x, z = round(e - origin[0], 3), round(origin[1] - n, 3)
                y = round(float(height_sampler(x, z)), 6) if height_sampler else 0.0
                if not all(math.isfinite(v) for v in (x, y, z)):
                    raise ValueError(f"Non-finite road coordinate in {source_id}")
                points.append((x, y, z))
                if len(osm_refs) == len(line):
                    ref = f"osm:{osm_refs[i]}"
                else:
                    level = str(tags.get("layer", "0"))
                    ref = f"geo:{x:.3f}:{z:.3f}:{level}"
                refs.append(ref)
            references.update(set(refs))
            ways.append((source_id, line_index, tags, points, refs))

    nodes, edges, tiles = {}, {}, defaultdict(list)
    counts = Counter()
    anchor_min = {name: float("inf") for name in anchors}
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]
    source_segments = degenerate = continuations = 0
    for source_id, line_index, tags, points, refs in sorted(ways, key=lambda w: (w[0], w[1])):
        highway = tags["highway"]
        width, flags = _width(tags, widths[highway]), flag_function(tags)
        stops = [0] + [i for i in range(1, len(refs) - 1) if references[refs[i]] > 1] + [len(refs) - 1]
        had_edge = False
        for first, last in zip(stops, stops[1:]):
            path = points[first:last + 1]
            length = sum(math.dist(a, b) for a, b in zip(path, path[1:]))
            if length < 0.25:
                degenerate += last - first
                continue
            eid = f"{source_id}:{line_index}:{refs[first]}:{refs[last]}"
            if eid in edges:
                eid += ":" + hashlib.sha1(repr(path).encode()).hexdigest()[:10]
            edge = {"id": eid, "source_way": source_id, "from": refs[first], "to": refs[last],
                    "path": path, "length_m": round(length, 3), "class": highway,
                    "class_id": classes[highway], "width_m": width,
                    "surface": tags.get("surface", "unknown"), "direction": _direction(tags),
                    "speed_limit_mps": _speed(tags), "speed_tag": tags.get("maxspeed"),
                    "bridge": bool(flags & 2), "tunnel": bool(flags & 4),
                    "layer": tags.get("layer", "0"), "flags": flags,
                    "elevation_source": "DEM" if height_sampler else "unmeasured-flat"}
            edge["tiles"] = []
            edges[eid] = edge
            for index in (first, last):
                nid = refs[index]
                node = nodes.setdefault(nid, {"id": nid, "position": points[index], "edges": []})
                if node["position"] != points[index]:
                    raise ValueError(f"Conflicting coordinates for shared node {nid}")
                node["edges"].append(eid)
            touched = set()
            for segment_index, (a, b) in enumerate(zip(path, path[1:])):
                if math.dist(a, b) < 0.001:
                    degenerate += 1
                    continue
                source_segments += 1
                center_pieces = list(split_segment(a, b, tile_size))
                continuations += max(0, len(center_pieces) - 1)
                for tile, polygon in ribbon_tiles(a, b, width, tile_size):
                    # First seven fields remain compatible with the old renderer.
                    tiles[tile].append([a[0], a[2], b[0], b[2], width, classes[highway], flags,
                                        eid, segment_index, a[1], b[1], polygon])
                    touched.add(tile)
                for point in (a, b):
                    bounds[0] = min(bounds[0], point[0]); bounds[1] = min(bounds[1], point[2])
                    bounds[2] = max(bounds[2], point[0]); bounds[3] = max(bounds[3], point[2])
                    for parish, anchor in anchors.items():
                        anchor_min[parish] = min(anchor_min[parish], math.hypot(point[0] - anchor[0], point[2] - anchor[1]))
            edge["tiles"] = sorted(touched)
            had_edge = True
        if had_edge:
            counts[highway] += 1
    for node in nodes.values():
        node["edges"] = sorted(set(node["edges"]))
    for segments in tiles.values():
        segments.sort(key=lambda seg: (seg[7], seg[8]))
    stats = {"road_features": sum(counts.values()), "source_segments": source_segments,
             "segments": sum(map(len, tiles.values())), "tiles": len(tiles),
             "graph_nodes": len(nodes), "graph_edges": len(edges),
             "centerline_boundary_crossings": continuations,
             "skipped_non_drivable_features": skipped, "degenerate_segments": degenerate,
             "by_highway_type": dict(sorted(counts.items())),
             "parish_anchor_distance_m": {k: round(v, 1) for k, v in sorted(anchor_min.items())}}
    return {"nodes": nodes, "edges": edges, "tiles": tiles, "bounds": bounds, "stats": stats}
