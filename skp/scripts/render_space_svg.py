from __future__ import annotations

"""Render Moosas RDF spaces to SVG floor-plan visualizations for SketchUp.

Usage:
    python render_space_svg.py <rdf-path> [svg-output-path]
"""

from colorsys import hsv_to_rgb
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable
import sys

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.patches import Polygon as MplPolygon
from matplotlib.patches import PathPatch
from matplotlib.path import Path as MplPath
from matplotlib.ticker import MaxNLocator, MultipleLocator, ScalarFormatter
from rdflib import Graph, Namespace
from rdflib.namespace import RDF
from shapely import force_2d, from_wkt, get_coordinates
from shapely.geometry import LineString, Point
from shapely.ops import polygonize, unary_union


BOT = Namespace("https://w3id.org/bot#")
MOOSAS = Namespace("https://moosas#")
BES = Namespace("http://www.hkust.edu.hk/zhaojiwu/performance_based_generative_design#")
GEO = Namespace("http://www.opengis.net/ont/geosparql#")

BACKGROUND = "#f4f0e8"
FLOOR_OUTLINE = "#8f5b2e"
WALL_FILL = "#6f8ea3"
AIRWALL_FILL = "#d94b41"
WINDOW_FILL = "#42ff62"
SPACE_LABEL = "#1f1f1f"
CONNECTOR = "#8f8f8f"
FLOOR_HUE = 0.08
FLOOR_SAT = 0.58
FLOOR_VAL = 0.86
LEVEL_MIN_HEIGHT = 2.2
LEVEL_MIN_AREA = 9.0


@dataclass
class SpaceShape:
    space_uri: object
    space_id: str
    level_key: float
    boundary_geom: object | None = None
    floor_geoms: list = field(default_factory=list)
    edge_items: list = field(default_factory=list)
    window_geoms: list = field(default_factory=list)
    source_index: int = 0
    area_m2: float | None = None
    is_void: bool = False


def _local_name(value) -> str:
    if value is None:
        return ""
    text = str(value)
    if "#" in text:
        return text.rsplit("#", 1)[-1]
    if "/" in text:
        return text.rstrip("/").rsplit("/", 1)[-1]
    return text


def _first(graph: Graph, subject, predicate):
    for obj in graph.objects(subject, predicate):
        return obj
    return None


def _surface_type(graph: Graph, interface) -> str:
    for predicate in (BES.surfaceType, BES.hasSurfaceType):
        value = _first(graph, interface, predicate)
        if value is not None:
            return _local_name(value)
    return ""


def _opening_type(surface_type: str) -> bool:
    return surface_type in {
        "OperableWindow",
        "FixedWindow",
        "AirWindow",
        "OperableSkylight",
        "FixedSkylight",
        "Skylight",
        "Glazing",
    }


def _collect_wkt_literals(graph: Graph, node) -> list[str]:
    wkts: list[str] = []
    for wkt_literal in graph.objects(node, GEO.asWKT):
        wkts.append(str(wkt_literal))
    for geom_node in graph.objects(node, GEO.hasGeometry):
        wkts.extend(_collect_wkt_literals(graph, geom_node))
    for face_node in graph.objects(node, MOOSAS.hasFace):
        wkts.extend(_collect_wkt_literals(graph, face_node))
    return wkts


def _parse_geometry(graph: Graph, node) -> list:
    geometries = []
    for wkt_text in _collect_wkt_literals(graph, node):
        try:
            geom = from_wkt(wkt_text)
        except Exception:
            continue
        if geom.geom_type == "GeometryCollection":
            geometries.extend([part for part in geom.geoms if not part.is_empty])
        else:
            geometries.append(geom)
    return geometries


def _flatten_geometries(geometry) -> Iterable:
    if geometry.is_empty:
        return []
    if geometry.geom_type == "MultiPolygon":
        return list(geometry.geoms)
    if geometry.geom_type == "GeometryCollection":
        parts = []
        for geom in geometry.geoms:
            parts.extend(list(_flatten_geometries(geom)))
        return parts
    return [geometry]


def _unique_xy(coords) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for x, y in coords:
        point = (float(x), float(y))
        if not points or points[-1] != point:
            points.append(point)
    if len(points) > 1 and points[0] == points[-1]:
        points.pop()
    return points


def _geometry_xy(geometry) -> list[tuple[float, float]]:
    coords = get_coordinates(force_2d(geometry))
    return _unique_xy(coords[:, :2])


def _line_like_buffer(geometry, width: float):
    coords = _geometry_xy(geometry)
    if len(coords) < 2:
        return None
    if len(coords) == 2:
        line = LineString(coords)
    else:
        line = LineString([coords[0], coords[1]])
    return line.buffer(width / 2.0, cap_style=2, join_style=2)


def _polygon_fill_geometry(geometry):
    geometry = force_2d(geometry)
    if geometry.geom_type == "Polygon":
        return geometry
    if geometry.geom_type == "MultiPolygon":
        return geometry
    return None


def _bbox(geometries: Iterable) -> tuple[float, float, float, float] | None:
    bounds = []
    for geometry in geometries:
        if geometry is None or geometry.is_empty:
            continue
        bounds.append(geometry.bounds)
    if not bounds:
        return None
    minx = min(item[0] for item in bounds)
    miny = min(item[1] for item in bounds)
    maxx = max(item[2] for item in bounds)
    maxy = max(item[3] for item in bounds)
    return minx, miny, maxx, maxy


def _space_floor_color(space_id: str) -> tuple[str, str]:
    seed = sum(ord(ch) for ch in space_id)
    hue = (FLOOR_HUE + (seed % 11) * 0.015) % 1.0
    saturation = min(0.78, max(0.38, FLOOR_SAT + ((seed // 11) % 5 - 2) * 0.05))
    value = min(0.95, max(0.68, FLOOR_VAL + ((seed // 53) % 5 - 2) * 0.035))
    r, g, b = hsv_to_rgb(hue, saturation, value)
    fill = f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"
    edge = f"#{int(max(0, r * 0.72) * 255):02x}{int(max(0, g * 0.72) * 255):02x}{int(max(0, b * 0.72) * 255):02x}"
    return fill, edge


def _interface_order(graph: Graph, interface, fallback: int) -> int:
    order_value = _first(graph, interface, MOOSAS.subElementOrder)
    if order_value is None:
        return fallback
    try:
        return int(float(order_value))
    except Exception:
        return fallback


def _level_key_from_geometries(floor_geometries: list) -> float:
    z_values = []
    for geometry in floor_geometries:
        try:
            coords = get_coordinates(geometry, include_z=True)
        except Exception:
            coords = get_coordinates(force_2d(geometry))
            if coords.size == 0:
                continue
            z_values.append(0.0)
            continue
        if coords.size == 0:
            continue
        z_values.append(float(coords[:, 2].mean()))
    return round(float(sum(z_values) / len(z_values)), 3) if z_values else 0.0


def _space_level_key(graph: Graph, space_uri, floor_geometries: list) -> float:
    level_nodes = list(graph.subjects(BOT.hasSpace, space_uri))
    for level_node in level_nodes:
        level_value = _first(graph, level_node, MOOSAS.altitute)
        if level_value is None:
            continue
        try:
            return round(float(level_value), 3)
        except Exception:
            continue
    return _level_key_from_geometries(floor_geometries)


def _line_from_geometry(geometry):
    coords = _geometry_xy(geometry)
    if len(coords) < 2:
        return None
    xs = [point[0] for point in coords]
    ys = [point[1] for point in coords]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    if minx == maxx and miny == maxy:
        return LineString(coords[:2])

    candidates = [
        LineString([(minx, miny), (maxx, maxy)]),
        LineString([(minx, maxy), (maxx, miny)]),
    ]
    points = [Point(x, y) for x, y in coords]

    def candidate_error(line: LineString) -> float:
        return sum(point.distance(line) for point in points)

    return min(candidates, key=candidate_error)


def _space_boundary_geometry(edge_items, floor_geometries):
    lines = [item["line"] for item in edge_items if item.get("line") is not None]
    if lines:
        try:
            merged = unary_union(lines)
            boundary_polygons = list(polygonize(merged))
            if boundary_polygons:
                boundary = unary_union(boundary_polygons)
                if not boundary.is_empty:
                    return boundary
        except Exception:
            pass
    candidates = []
    for geometry in floor_geometries:
        poly = _polygon_fill_geometry(geometry)
        if poly is not None and not poly.is_empty:
            candidates.append(poly)
    if candidates:
        try:
            boundary = unary_union(candidates)
            if not boundary.is_empty:
                return boundary
        except Exception:
            return candidates[0]
    return None


def _ordered_edge_items(graph: Graph, space_uri) -> list[dict]:
    items = []
    fallback = 0
    for interface in graph.subjects(BOT.interfaceOf, space_uri):
        surface_type = _surface_type(graph, interface)
        has_edge = any(_local_name(value) == "Edge" for value in graph.objects(interface, BES.hasSurfaceType))
        if not has_edge or surface_type not in {"ExteriorWall", "InteriorWall", "AirWall"}:
            continue
        linked_nodes = [node for node in graph.objects(interface, BOT.interfaceOf) if node != space_uri]
        for linked in linked_nodes:
            geometries = _parse_geometry(graph, linked)
            for geometry in geometries:
                line = _line_from_geometry(geometry)
                if line is None:
                    continue
                items.append({
                    "order": _interface_order(graph, interface, fallback),
                    "surface_type": surface_type,
                    "line": line,
                    "element_id": _local_name(_first(graph, linked, MOOSAS.Uid)) or _local_name(linked).replace('element_', ''),
                    "element_uri": str(linked),
                })
                fallback += 1
    items.sort(key=lambda item: item["order"])
    return items


def _collect_spaces(graph: Graph) -> list[SpaceShape]:
    spaces: list[SpaceShape] = []
    for space_uri in graph.subjects(RDF.type, BOT.Space):
        space_id = _local_name(_first(graph, space_uri, MOOSAS.Uid)) or _local_name(space_uri)
        floor_geoms = []
        window_geoms = []
        for interface in graph.subjects(BOT.interfaceOf, space_uri):
            surface_type = _surface_type(graph, interface)
            linked_nodes = [node for node in graph.objects(interface, BOT.interfaceOf) if node != space_uri]
            for linked in linked_nodes:
                geometries = _parse_geometry(graph, linked)
                if not geometries:
                    continue
                if surface_type in {"Floor", "SlabOnGrade", "InteriorFloor", "UndergroundSlab"}:
                    floor_geoms.extend(geometries)
                elif _opening_type(surface_type):
                    element_id = _local_name(_first(graph, linked, MOOSAS.Uid)) or _local_name(linked).replace('element_', '')
                    window_geoms.extend([{'geometry': geometry, 'element_id': element_id, 'element_uri': str(linked)} for geometry in geometries])
        edge_items = _ordered_edge_items(graph, space_uri)
        boundary_geom = _space_boundary_geometry(edge_items, floor_geoms)
        if not floor_geoms and (boundary_geom is None or boundary_geom.is_empty):
            continue
        reported_area = _first(graph, space_uri, BES.hasFloorArea_m2)
        try:
            area_m2 = float(reported_area) if reported_area is not None else None
        except (TypeError, ValueError):
            area_m2 = None
        is_void_value = _first(graph, space_uri, MOOSAS.isVoid)
        spaces.append(
            SpaceShape(
                space_uri=space_uri,
                space_id=space_id,
                level_key=_space_level_key(graph, space_uri, floor_geoms),
                boundary_geom=boundary_geom,
                floor_geoms=floor_geoms,
                edge_items=edge_items,
                window_geoms=window_geoms,
                area_m2=area_m2,
                is_void=str(is_void_value).strip().lower() in {'true', '1'},
            )
        )
    return spaces


def _floor_area(spaces: Iterable[SpaceShape]) -> float:
    """Area represented by spaces and voids at one source elevation.

    Sum the RDF's effective ``hasFloorArea_m2`` for spaces and voids, matching
    MoosasPy's per-level horizontal-area test. If older RDF lacks that property,
    fall back to the union of its available floor footprints.
    """
    reported = [space for space in spaces if space.area_m2 is not None and space.area_m2 >= 0]
    missing = [space for space in spaces if space.area_m2 is None or space.area_m2 < 0]
    reported_total = sum(space.area_m2 for space in reported)
    polygons = []
    for space in missing:
        for geometry in space.floor_geoms:
            polygon = _polygon_fill_geometry(geometry)
            if polygon is not None and not polygon.is_empty:
                polygons.append(polygon)
    fallback_area = float(unary_union(polygons).area) if polygons else 0.0
    return float(reported_total + fallback_area)


def _group_display_levels(sources: list[tuple[Graph, list[SpaceShape]]]) -> list[dict]:
    """Combine selection RDFs and apply MoosasPy's display-level cleanse rule.

    Like ``cleanseDuplicatedLevel``, each elevation is evaluated against the
    preceding retained (lower) elevation. A level below 9 m² or less than 2.2 m
    above that retained level is assigned to it. The lowest level is preserved,
    matching MoosasPy's behavior for its first ``levelList`` entry.
    """
    by_elevation: dict[float, list[SpaceShape]] = {}
    known_space_ids = set()
    for source_index, (_, spaces) in enumerate(sources):
        for space in spaces:
            if space.space_id in known_space_ids:
                raise ValueError(f'Duplicate space ID across models: {space.space_id}')
            known_space_ids.add(space.space_id)
            space.source_index = source_index
            by_elevation.setdefault(float(space.level_key), []).append(space)

    levels = []
    for elevation, group in sorted(by_elevation.items()):
        area = _floor_area(group)
        if levels and (elevation - levels[-1]['elevation'] < LEVEL_MIN_HEIGHT or area < LEVEL_MIN_AREA):
            levels[-1]['spaces'].extend(group)
            levels[-1]['area_m2'] += area
            levels[-1]['merged_elevations'].append(elevation)
            continue
        levels.append({
            'elevation': elevation,
            'spaces': list(group),
            'area_m2': area,
            'merged_elevations': [elevation],
        })
    return levels


def _draw_shapely(ax, geometry, fill_color: str, edge_color: str, alpha: float, zorder: int) -> None:
    if geometry is None or geometry.is_empty:
        return
    for part in _flatten_geometries(geometry):
        if part.is_empty:
            continue
        if part.geom_type == "Polygon":
            ax.add_patch(PathPatch(_polygon_path(part), facecolor=fill_color, edgecolor=edge_color,
                                   alpha=alpha, linewidth=1.0, zorder=zorder))


def _polygon_path(polygon):
    from shapely.geometry.polygon import orient
    polygon = orient(polygon, sign=1.0)
    vertices, codes = [], []
    for ring in [polygon.exterior, *polygon.interiors]:
        points = list(ring.coords)
        vertices.extend([(x, y) for x, y, *rest in points])
        codes.extend([MplPath.MOVETO] + [MplPath.LINETO] * (len(points) - 2) + [MplPath.CLOSEPOLY])
    return MplPath(vertices, codes)


def _draw_outline(ax, geometry, color: str, linewidth: float, zorder: int, linestyle: str = "-") -> None:
    if geometry is None or geometry.is_empty:
        return
    for part in _flatten_geometries(geometry):
        if part.is_empty:
            continue
        if part.geom_type == "Polygon":
            coords = list(part.exterior.coords)
            xs = [pt[0] for pt in coords]
            ys = [pt[1] for pt in coords]
            ax.plot(xs, ys, color=color, linewidth=linewidth, linestyle=linestyle, zorder=zorder)


def _space_label_point(space: SpaceShape):
    if space.boundary_geom is not None and not space.boundary_geom.is_empty:
        try:
            return space.boundary_geom.representative_point()
        except Exception:
            pass
    if space.floor_geoms:
        geom = _polygon_fill_geometry(space.floor_geoms[0])
        if geom is not None:
            return geom.representative_point()
    if space.edge_items:
        points = [item["line"].interpolate(0.5, normalized=True) for item in space.edge_items]
        if points:
            x = sum(point.x for point in points) / len(points)
            y = sum(point.y for point in points) / len(points)
            return Point(x, y)
    return None


def _draw_space(ax, space: SpaceShape) -> list:
    drawn = []
    label_point = _space_label_point(space)
    fill_color, edge_color = _space_floor_color(space.space_id)
    boundary = space.boundary_geom
    if boundary is not None and not boundary.is_empty:
        drawn.append(boundary)
        _draw_shapely(ax, boundary, fill_color, edge_color, 0.30, 0)
        _draw_outline(ax, boundary, FLOOR_OUTLINE, 1.6, 1)
    else:
        for geometry in space.floor_geoms:
            geom = _polygon_fill_geometry(geometry)
            if geom is None:
                continue
            drawn.append(geom)
            _draw_shapely(ax, geom, fill_color, edge_color, 0.30, 0)
            _draw_outline(ax, geom, FLOOR_OUTLINE, 1.6, 1)
    for item in space.edge_items:
        line = item["line"]
        color = AIRWALL_FILL if item["surface_type"] == "AirWall" else WALL_FILL
        drawn.append(line)
        xs, ys = line.xy
        ax.plot(xs, ys, color=color, linewidth=4.0, alpha=0.95, zorder=4)
        if label_point is not None:
            midpoint = line.interpolate(0.5, normalized=True)
            ax.plot([midpoint.x, label_point.x], [midpoint.y, label_point.y], color=CONNECTOR, linewidth=0.8, alpha=0.35, zorder=3)
    for item in space.window_geoms:
        geometry = item['geometry'] if isinstance(item, dict) else item
        buffered = _line_like_buffer(geometry, 0.4)
        if buffered is None:
            continue
        drawn.append(buffered)
        _draw_shapely(ax, buffered, WINDOW_FILL, WINDOW_FILL, 0.98, 5)
    if label_point is not None:
        ax.text(label_point.x, label_point.y, getattr(space, 'display_name', space.space_id), fontsize=6, color=SPACE_LABEL, ha="center", va="center", zorder=7)
    return drawn


def _all_space_geometries(spaces: Iterable[SpaceShape]) -> list:
    geometries = []
    for space in spaces:
        if space.boundary_geom is not None:
            geometries.append(space.boundary_geom)
        geometries.extend(space.floor_geoms)
        geometries.extend([item["line"] for item in space.edge_items])
        geometries.extend([item['geometry'] if isinstance(item, dict) else item for item in space.window_geoms])
    return geometries


def _configure_plan_axes(ax, bounds):
    """One world-coordinate frame and metric grid, independent of floor content."""
    minx, miny, maxx, maxy = bounds
    if maxx <= minx:
        minx, maxx = minx - .5, maxx + .5
    if maxy <= miny:
        miny, maxy = miny - .5, maxy + .5
    ticks = MaxNLocator(nbins=8, steps=[1, 2, 2.5, 5, 10]).tick_values(0, max(maxx-minx, maxy-miny))
    step = float(ticks[1] - ticks[0])
    ax.set_aspect('equal', adjustable='box')
    ax.set_facecolor(BACKGROUND)
    for axis in (ax.xaxis, ax.yaxis):
        axis.set_major_locator(MultipleLocator(step))
        formatter = ScalarFormatter(useOffset=False)
        formatter.set_scientific(False)
        axis.set_major_formatter(formatter)
    ax.set_xlim(minx, maxx)
    ax.set_ylim(miny, maxy)
    ax.set_autoscale_on(False)
    ax.set_xlabel('X (m)')
    ax.set_ylabel('Y (m)')
    ax.tick_params(labelsize=9)
    ax.set_axisbelow(True)
    ax.grid(True, color='#87949c', alpha=.45, linewidth=.6, linestyle='--')
    return {'x': [minx, maxx], 'y': [miny, maxy], 'grid_step_m': step}


def render_rdf_svg(rdf_path: str | Path, svg_path: str | Path | None = None) -> Path:
    rdf_path = Path(rdf_path)
    if svg_path is None:
        svg_path = rdf_path.with_name(f"{rdf_path.stem}_floorplan.svg")
    svg_path = Path(svg_path)
    svg_path.parent.mkdir(parents=True, exist_ok=True)

    graph = Graph().parse(rdf_path, format="turtle")
    spaces = _collect_spaces(graph)
    if not spaces:
        raise ValueError(f"No spaces found in RDF file: {rdf_path}")

    levels = _group_display_levels([(graph, spaces)])
    fig, axes = plt.subplots(len(levels), 1, figsize=(12, max(6, 5 * len(levels))), constrained_layout=True)
    if len(levels) == 1:
        axes = [axes]

    global_bounds = _bbox(_all_space_geometries(spaces))

    for ax, level in zip(axes, levels):
        for space in level['spaces']:
            _draw_space(ax, space)
        ax.set_title(f"Level z ~ {level['elevation']:.3f} m ({len(level['spaces'])} spaces)")
        if global_bounds is not None:
            _configure_plan_axes(ax, global_bounds)

    fig.savefig(str(svg_path), format="svg", facecolor=BACKGROUND, bbox_inches="tight")
    plt.close(fig)
    return svg_path


def render_request(request_path):
    """Create globally grouped interactive elevation SVGs and a JSON manifest."""
    import io
    import json
    import xml.etree.ElementTree as ET
    request_path = Path(request_path)
    request = json.loads(request_path.read_text(encoding='utf-8-sig'))
    result = {'context': request['context'], 'levels': [], 'warnings': []}
    matplotlib.rcParams['svg.fonttype'] = 'none'
    matplotlib.rcParams['text.parse_math'] = False
    sources = []
    for rdf in request['rdf_paths']:
        graph = Graph().parse(rdf, format='turtle')
        sources.append((graph, _collect_spaces(graph)))
    building_bounds = _bbox(_all_space_geometries([s for _, spaces in sources for s in spaces]))
    for graph, spaces in sources:
        collected = {s.space_id for s in spaces}
        for uri in graph.subjects(RDF.type, BOT.Space):
            sid = str(graph.value(uri, MOOSAS.Uid) or _local_name(uri))
            if sid not in collected:
                result['warnings'].append(f'{sid}: no floor geometry available')
    levels = _group_display_levels(sources)
    for level_index, level in enumerate(levels):
        elevation, group = level['elevation'], level['spaces']
        # Fixed canvas and axes allocation: neither labels nor an upper
        # floor's smaller footprint may change the SVG-to-world transform.
        fig = plt.figure(figsize=(12, 7))
        ax = fig.add_axes([.10, .12, .85, .82])
        records = []
        try:
            for index, space in enumerate(group):
                space.display_name = request.get('names', {}).get(space.space_id) or space.space_id
                label_before = len(ax.texts)
                _draw_space(ax, space)
                gid = f'space-{space.source_index}-{level_index}-{index}'
                label_id = gid + '-label'
                if len(ax.texts) > label_before:
                    ax.texts[-1].set_gid(label_id)
                parts = list(_flatten_geometries(space.boundary_geom)) if space.boundary_geom is not None else []
                hits = []
                for part_index, part in enumerate(parts):
                    if part.geom_type != 'Polygon' or part.is_empty:
                        continue
                    hit_id = f'{gid}-hit-{part_index}'
                    hit = PathPatch(_polygon_path(part), facecolor='white', edgecolor='none', alpha=0, zorder=30)
                    hit.set_gid(hit_id)
                    ax.add_patch(hit)
                    hits.append(hit_id)
                # Element hit areas are drawn above space fills. A window is
                # above a wall, which makes selection deterministic.
                element_hits = []
                for edge_index, item in enumerate(space.edge_items):
                    hit_geom = _line_like_buffer(item['line'], 0.75)
                    if hit_geom is None:
                        continue
                    hit_id = f'{gid}-wall-hit-{edge_index}'
                    hit = PathPatch(_polygon_path(hit_geom), facecolor='white', edgecolor='none', alpha=0, zorder=40)
                    hit.set_gid(hit_id); ax.add_patch(hit)
                    element_hits.append((hit_id, 'wall', item['element_id'], item['element_uri']))
                for window_index, item in enumerate(space.window_geoms):
                    geometry = item['geometry'] if isinstance(item, dict) else item
                    hit_geom = _line_like_buffer(geometry, 0.7)
                    if hit_geom is None:
                        continue
                    hit_id = f'{gid}-window-hit-{window_index}'
                    hit = PathPatch(_polygon_path(hit_geom), facecolor='white', edgecolor='none', alpha=0, zorder=50)
                    hit.set_gid(hit_id); ax.add_patch(hit)
                    element_hits.append((hit_id, 'window', item.get('element_id', ''), item.get('element_uri', '')))
                if not hits:
                    result['warnings'].append(f'{space.space_id}: no selectable polygon')
                records.append({'space_id': space.space_id, 'space_uri': str(space.space_uri),
                                'source_index': space.source_index, 'hit_ids': hits, 'label_id': label_id,
                                'element_hits': [{'id': h, 'type': t, 'element_id': e, 'element_uri': u} for h, t, e, u in element_hits]})
            axis_limits = _configure_plan_axes(ax, building_bounds)
            stream = io.StringIO()
            fig.savefig(stream, format='svg', facecolor=BACKGROUND)
            root = ET.fromstring(stream.getvalue())
            for node in root.iter():
                for record in records:
                    if node.get('id') in record['hit_ids']:
                        node.set('data-space-id', record['space_id'])
                        node.set('class', 'space-hit')
                        node.set('tabindex', '0')
                        node.set('role', 'button')
                        node.set('aria-label', request.get('names', {}).get(record['space_id']) or record['space_id'])
                    for hit in record.get('element_hits', []):
                        if node.get('id') == hit['id']:
                            node.set('data-element-id', hit['element_id'])
                            node.set('data-element-type', hit['type'])
                            node.set('class', f"element-hit {hit['type']}-hit")
                            node.set('tabindex', '0'); node.set('role', 'button')
                            node.set('aria-label', f"{hit['type']} {hit['element_id']}")
            svg = ET.tostring(root, encoding='unicode')
            level_id = f'level-{level_index}:{elevation}'
            output = request_path.parent / f'floor-{level_index}.svg'
            output.write_text(svg, encoding='utf-8')
            result['levels'].append({'id': level_id, 'level_index': level_index, 'elevation': elevation,
                                    'area_m2': level['area_m2'], 'space_count': len(records),
                                    'merged_elevations': level['merged_elevations'],
                                    'building_bbox_xy': list(building_bounds), 'axis_limits': axis_limits,
                                    'svg': svg, 'spaces': records})
        finally:
            plt.close(fig)
    (request_path.parent / 'result.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    return result


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rdf", help="Input RDF turtle file")
    parser.add_argument("svg", nargs="?", help="Output SVG path")
    args = parser.parse_args(argv)

    if Path(args.rdf).suffix.lower() == '.json':
        render_request(args.rdf)
        return 0
    rdf_path = Path(args.rdf)
    svg_path = Path(args.svg) if args.svg else rdf_path.with_name(f"{rdf_path.stem}_floorplan.svg")
    result = render_rdf_svg(rdf_path, svg_path)
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
