"""Replayable MoosasPy Radiance daylight job used by SketchUp."""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import traceback

from MoosasPy.model import MoosasModel
from MoosasPy.simulation.contracts import Location
from MoosasPy.simulation.radiation import RadianceRunner, RadianceSky, build_daylight_grids


def _write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


def run_file(request_path: str | Path) -> dict:
    request_path = Path(request_path).resolve()
    root = request_path.parent
    request = json.loads(request_path.read_text(encoding="utf-8"))
    progress_path = root / "progress.json"
    try:
        _write(progress_path, {"request_id": request["request_id"], "stage": "loading"})
        model = MoosasModel.load(request["rdf_path"])
        params = request["parameters"]
        grids = build_daylight_grids(model, request.get("space_ids"), params["grid_size"], params["grid_offset"])
        _write(progress_path, {"request_id": request["request_id"], "stage": "radiance", "grid_points": sum(len(g.cells) for g in grids)})
        location = Location(**request["location"])
        sky = RadianceSky(datetime.fromisoformat(params["datetime"]), params["sky_type"], location,
                          params["diffuse_illuminance"], params.get("timezone_hours", 8.0))
        result = RadianceRunner(model, sky, grids=grids, work_dir=root,
                                timeout_seconds=params.get("timeout_seconds", 300.0),
                                threshold_lux=params.get("threshold_lux", 300.0)).run()
        spaces = []
        for space in result.spaces:
            spaces.append({
                "space_id": space.space_id, "point_count": space.point_count,
                "effective_area": space.effective_area, "average_illuminance": space.average_illuminance,
                "minimum_illuminance": space.minimum_illuminance, "maximum_illuminance": space.maximum_illuminance,
                "uniformity": space.uniformity, "satisfied_fraction": space.satisfied_fraction,
                "metric_kind": space.metric_kind, "daylight_factor_percent": space.daylight_factor_percent,
                "points": [{"grid_id": point.cell.grid_id, "point": point.cell.point,
                            "normal": point.cell.normal, "polygon": point.cell.polygon,
                            "holes": point.cell.holes,
                            "area": point.cell.area, "rgb": point.rgb,
                            "illuminance": point.illuminance} for point in space.points],
            })
        payload = {
            "schema_version": 1, "request_id": request["request_id"], "success": True,
            "model_snapshot": request["model_snapshot"], "settings_version": request["settings_version"],
            "metric_kind": result.metric_kind, "warnings": result.warnings,
            "reference_illuminance": result.reference_illuminance,
            "spaces": spaces, "commands": [
                {"command": list(command.command), "returncode": command.returncode,
                 "stderr": command.stderr, "elapsed_ms": command.elapsed_ms}
                for command in result.commands],
            "workspace": result.workspace.path,
        }
        _write(root / "result.json", payload)
        _write(progress_path, {"request_id": request["request_id"], "stage": "complete"})
        return payload
    except Exception as error:
        payload = {"schema_version": 1, "request_id": request.get("request_id"), "success": False,
                   "error": str(error), "traceback": traceback.format_exc()}
        _write(root / "error.json", payload)
        _write(progress_path, {"request_id": request.get("request_id"), "stage": "failed", "error": str(error)})
        raise
