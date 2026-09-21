"""Replayable Main-page analysis: python -m skp.scripts.main_analysis request.json."""
from __future__ import annotations

import json
import math
import sys
import time
import traceback
from pathlib import Path
from skp.scripts.workspace import workspace

from MoosasPy.model.io import load_model
from MoosasPy.model.resources import configure_model_resources
from MoosasPy.simulation.contracts import Location
from MoosasPy.simulation.energy.runner import EnergyRunner
from MoosasPy.simulation.coupling.energy_radiation import run_energy_with_radiation
from MoosasPy.simulation.radiation import estimate_space_daylight_factor
from MoosasPy.simulation.weather import load_epw, prepare_epw, read_cumulative_sky_matrix, build_cumulative_skies
from MoosasPy.simulation.weather.epw import read_weather_csv
from MoosasPy.utils.constant import buildingType

PARTS = ('cooling', 'heating', 'lighting', 'equipment')
MONTHS = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')
TYPES = {key: getattr(buildingType, key) for key in ('RESIDENTIAL', 'OFFICE', 'HOTEL', 'SCHOOL', 'COMMERCIAL')}


def atomic_json(path, data):
    path = Path(path)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2), encoding='utf-8')
    # Windows readers (including Ruby File.read) may briefly deny delete-sharing.
    # Keep the old complete JSON visible and retry the atomic replacement.
    for attempt in range(20):
        try:
            temporary.replace(path)
            break
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(min(.02 * (attempt + 1), .2))


def climate_zone(temperature):
    daily = temperature.reshape(365, 24).mean(axis=1)
    cold, hot = daily[:31].mean(), daily[181:212].mean()
    if cold <= -10: return 'climatezone1'
    if cold <= 0: return 'climatezone2'
    if cold <= 10 and 25 < hot <= 30: return 'climatezone3'
    if cold > 10 and 25 < hot <= 29: return 'climatezone4'
    if 0 < cold <= 13 and 18 < hot <= 25: return 'climatezone5'
    if (daily <= 5).sum() >= 145: return 'climatezone1'
    if (daily <= 5).sum() >= 90: return 'climatezone2'
    if 40 <= (daily >= 25).sum() < 110: return 'climatezone3'
    return 'climatezone4' if (daily >= 25).sum() < 200 else 'climatezone5'


def row(data):
    result = {key: float(data[key]) for key in PARTS}
    if not all(math.isfinite(value) for value in result.values()):
        raise ValueError('Non-finite energy result')
    result['total'] = sum(result.values())
    return result


def derive_envelope_averages(space):
    """Publish area-weighted exterior element values for legacy zone consumers."""
    if not hasattr(space, 'getAllFaces'):
        return
    faces = space.getAllFaces(to_dict=True)
    walls = [item for item in faces.get('MoosasWall', []) if getattr(item, 'isOuter', False)]
    windows = [item for item in faces.get('MoosasGlazing', []) if getattr(item, 'isOuter', False)]
    def average(items, field):
        weighted = []
        for item in items:
            value = getattr(item, 'settings', {}).get(field)
            area = float(getattr(item, 'area', 0) or 0)
            if value is not None and area > 0:
                weighted.append((float(value), area))
        return sum(value * area for value, area in weighted) / sum(area for _, area in weighted) if weighted else None
    wall_u, win_u, shgc = average(walls, 'u_value'), average(windows, 'u_value'), average(windows, 'shgc')
    if wall_u is not None: space.settings['zone_wallU'] = wall_u
    if win_u is not None: space.settings['zone_winU'] = win_u
    if shgc is not None: space.settings['zone_win_SHGC'] = shgc


def analyze(request, directory):
    directory = Path(directory)
    request_id = request['request_id']
    def progress(stage):
        atomic_json(directory / 'progress.json', {'request_id': request_id, 'stage': stage, 'running': True})
    if request.get('schema_version') != 1: raise ValueError('Unsupported request schema')
    core = TYPES[request['building_type']]
    if not isinstance(request['require_radiation'], bool): raise ValueError('require_radiation must be boolean')
    if not request['rdf_paths']: raise ValueError('No model snapshot')
    progress('model')
    models = []
    for rdf in request['rdf_paths']:
        model = load_model(rdf)
        configure_model_resources(model)
        model.spaceList = [s for s in model.spaceList if not s.is_open()]
        if not model.spaceList: raise ValueError('Model has no enclosed simulation spaces')
        if any(not math.isfinite(s.area) or not math.isfinite(s.height) or s.area <= 0 or s.height <= 0 for s in model.spaceList):
            raise ValueError('Model contains invalid space area or height')
        models.append(model)
    progress('weather')
    source = request['weather']
    skies = None
    if source.get('epw_path'):
        if request['require_radiation']:
            prepared = prepare_epw(source['epw_path'], str(directory / 'weather'))
            weather, skies = prepared.weather, prepared.cumulative_skies
        else:
            weather = load_epw(source['epw_path'], str(directory / 'weather'))
    else:
        weather = read_weather_csv(source['csv_path'], Location(**source['location']))
        if request['require_radiation']:
            if source.get('sky_station_id') != weather.location.station_id:
                raise ValueError('Sky and weather station do not match')
            skies = build_cumulative_skies(read_cumulative_sky_matrix(source['sky_path']))
    zone = climate_zone(weather.temperature)
    annual = dict.fromkeys(PARTS, 0.0)
    months = [dict.fromkeys(PARTS, 0.0) for _ in MONTHS]
    area = 0.0
    spaces, daylight, warnings, applied = [], [], [], []
    for index, model in enumerate(models):
        template = f"{zone}_{request['standard']}_{request['building_type']}"
        if template not in model.buildingTemplate: raise ValueError(f'Missing template: {template}')
        for space in model.spaceList:
            if not math.isfinite(space.area) or space.area <= 0 or space.height <= 0:
                raise ValueError(f'Invalid area or height: {space.id}')
            saved = {key: space.settings[key] for key in getattr(space, 'explicit_settings', []) if key in space.settings}
            space.applySettings(template)
            space.settings.update(saved)
            record = request.get('space_settings', {}).get(str(space.id), {})
            settings = dict(record.get('values', {}))
            if 'zone_inflitration' in settings:
                settings['zone_infiltration'] = settings.pop('zone_inflitration')
            # Recompute radiation every run; never restore stale seasonal gains.
            for key in ('zone_summerrad', 'zone_winterrad', 'zone_template'):
                settings.pop(key, None)
            space.settings.update(settings)
            space.explicit_settings = sorted(set(getattr(space, 'explicit_settings', [])) | set(settings))
            derive_envelope_averages(space)
            if record.get('source') == 'legacy':
                warnings.append(f'{space.id}: preserved legacy space settings')
            applied.append({'space_id': str(space.id), 'model_index': index, 'template': template, 'settings': dict(space.settings)})
        atomic_json(directory / 'applied_settings.json', applied)
        options = dict(core=core, temporal_scale='monthly', spatial_scale='zone')
        if request['require_radiation']:
            progress('radiation')
            data = run_energy_with_radiation(model, weather=weather, cumulative_skies=skies,
                                            radiation_mode=1, reflection=0, on_stage=progress, **options).data
        else:
            progress('energy')
            data = EnergyRunner(model=model, weather=weather, require_radiation=False, **options).run().data
        model_area = sum(s.area for s in model.spaceList)
        area += model_area
        values = row(data['total'])
        for key in PARTS: annual[key] += values[key] * model_area
        for m, name in enumerate(MONTHS):
            values = row(data['months'][name])
            for key in PARTS: months[m][key] += values[key] * model_area
        progress('daylight')
        for space, thermal in zip(model.spaceList, data['spaces']):
            spaces.append({'space_id': str(space.id), 'model_index': index,
                           'name': str(space.settings.get('zone_name') or space.id),
                           'area_m2': float(space.area), 'annual': row(thermal.load)})
            daylight.append({'space_id': str(space.id), 'model_index': index, 'area_m2': float(space.area),
                             'factor_percent': float(estimate_space_daylight_factor(space))})
    atomic_json(directory / 'applied_settings.json', applied)
    annual = row({key: value / area for key, value in annual.items()})
    months = [dict(month=name, **row({k: v / area for k, v in values.items()})) for name, values in zip(MONTHS, months)]
    return {'schema_version': 2, 'request_id': request_id, 'area_m2': area,
            'model_snapshot': request.get('model_snapshot'),
            'energy': {'annual': annual, 'absolute_kwh': annual['total'] * area, 'months': months, 'spaces': spaces,
                       'annual_unit': 'kWh/m2/year', 'monthly_unit': 'kWh/m2'},
            'daylight': {'spaces': daylight, 'area_weighted_mean_percent': sum(d['factor_percent'] * d['area_m2'] for d in daylight) / area},
            'warnings': warnings, 'require_radiation': request['require_radiation']}


def run_file(request_path):
    request_path = Path(request_path).resolve()
    request = {}
    try:
        request = json.loads(request_path.read_text(encoding='utf-8-sig'))
        if not isinstance(request, dict):
            request = {}
            raise ValueError('Request must be a JSON object')
        (request_path.parent / 'result.json').unlink(missing_ok=True)
        (request_path.parent / 'error.json').unlink(missing_ok=True)
        with workspace(request_path.parent):
            result = analyze(request, request_path.parent)
        atomic_json(request_path.parent / 'result.json', result)
        atomic_json(request_path.parent / 'progress.json', {'request_id': request['request_id'], 'stage': 'complete', 'running': False})
        return result
    except Exception as error:
        atomic_json(request_path.parent / 'error.json', {'request_id': request.get('request_id'), 'message': str(error), 'traceback': traceback.format_exc()})
        atomic_json(request_path.parent / 'progress.json', {'request_id': request.get('request_id'), 'stage': 'failed', 'running': False})
        raise


if __name__ == '__main__':
    run_file(sys.argv[1])
