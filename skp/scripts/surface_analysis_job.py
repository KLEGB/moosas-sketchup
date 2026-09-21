"""Asynchronous direct-sun and cumulative-radiation adapter for SketchUp grids."""
from __future__ import annotations
from datetime import datetime, timedelta
import json, math, os, traceback
from pathlib import Path

from MoosasPy.simulation.radiation.calculation import ray_test
from MoosasPy.simulation.weather.sky.cumulative import CumulativeSky, read_cumulative_sky_matrix
from MoosasPy.simulation.weather.sky.direct import DirectSky
from MoosasPy.transform.geometry.geos import Ray, Vector

SCHEMA_VERSION = 1
RAY_BATCH_SIZE = 50_000
DEFAULT_SUNHOUR_PARAMS = "default 1 21 12 21 12 1 1 7 00 18 00 t t t t t t t 1 f f"

def atomic_json(path, data):
    path = Path(path); temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False), encoding='utf-8')
    os.replace(temporary, path)

def chunks(items, size=RAY_BATCH_SIZE):
    for start in range(0, len(items), size): yield items[start:start + size]

def finite_vector(values, label):
    if not isinstance(values, (list, tuple)) or len(values) != 3: raise ValueError(f'{label} must be a three-dimensional vector')
    result = tuple(float(value) for value in values)
    if not all(math.isfinite(value) for value in result): raise ValueError(f'{label} contains a non-finite value')
    return result

def sketchup_sky_direction(direction):
    """Map the bundled weather sky's horizontal axes into SketchUp coordinates."""
    direction = Vector(direction)
    return Vector((-direction.x, -direction.y, direction.z))

def ray_batches(items, size=RAY_BATCH_SIZE):
    batch = []
    for item in items:
        batch.append(item)
        if len(batch) == size:
            yield batch
            batch = []
    if batch:
        yield batch

def run_ray_batches(scene_path, items):
    """Yield (metadata, engine_hit) pairs without materializing the full job."""
    for batch in ray_batches(items):
        hits = ray_test([item[-1] for item in batch], geo_path=str(scene_path))
        if len(hits) != len(batch):
            raise RuntimeError('Ray engine returned an incomplete batch')
        yield from zip(batch, hits)

def grids_from_request(request):
    if not isinstance(request.get('grids'), list) or not request['grids']: raise ValueError('No analysis grids')
    output = []
    for source in request['grids']:
        grid_id = str(source['id']); normal = Vector(finite_vector(source['normal'], f'grid {grid_id} normal')).unit()
        rows = source['nodes']
        if not isinstance(rows, list) or not rows or not all(isinstance(row, list) for row in rows): raise ValueError(f'Grid {grid_id} has no node matrix')
        values, points = [[None for _ in row] for row in rows], []
        for row_index, row in enumerate(rows):
            for column_index, point in enumerate(row):
                if point is not None:
                    values[row_index][column_index] = 0.0
                    points.append((row_index, column_index, Vector(finite_vector(point, f'grid {grid_id} node'))))
        if not points: raise ValueError(f'Grid {grid_id} has no valid nodes')
        output.append({'id': grid_id, 'normal': normal, 'points': points, 'values': values})
    return output

def parse_sunhour_parameters(raw):
    values = str(raw or DEFAULT_SUNHOUR_PARAMS).split()
    if not values: raise ValueError('Missing sun-hour parameters')
    values.pop(0)
    try:
        date_count = int(values.pop(0)); dates = []
        for _ in range(date_count):
            start_day, start_month, end_day, end_month = (int(values.pop(0)) for _ in range(4))
            dates.append(((start_month, start_day), (end_month, end_day)))
        type_count = int(values.pop(0)); periods_by_type = []
        for _ in range(type_count):
            count = int(values.pop(0)); periods = []
            for _ in range(count):
                start_hour, start_minute, end_hour, end_minute = (int(values.pop(0)) for _ in range(4))
                periods.append(((start_hour, start_minute), (end_hour, end_minute)))
            periods_by_type.append(periods)
        weekdays = [[values.pop(0) == 't' for _ in range(7)] for _ in range(type_count)]
        step_hours = float(values.pop(0))
    except (IndexError, ValueError) as error: raise ValueError('Invalid sun-hour parameter string') from error
    if date_count < 1 or type_count < 1 or not math.isfinite(step_hours) or step_hours <= 0: raise ValueError('Invalid sun-hour analysis period')
    return dates, periods_by_type, weekdays, step_hours

def analysis_times(raw):
    dates, periods_by_type, weekdays, step_hours = parse_sunhour_parameters(raw); step = timedelta(hours=step_hours)
    for (start_month, start_day), (end_month, end_day) in dates:
        current, end_date = datetime(2015, start_month, start_day), datetime(2015, end_month, end_day)
        while current <= end_date:
            ruby_weekday = (current.weekday() + 1) % 7
            selected_type = next((index for index, flags in enumerate(weekdays) if flags[ruby_weekday]), None)
            if selected_type is not None:
                for (start_hour, start_minute), (end_hour, end_minute) in periods_by_type[selected_type]:
                    start, end = current.replace(hour=start_hour, minute=start_minute), current.replace(hour=end_hour, minute=end_minute)
                    if end <= start: end += timedelta(days=1)
                    moment = start
                    while moment < end:
                        duration = min(step, end - moment).total_seconds() / 3600.0
                        yield moment, duration
                        moment += step
            current += timedelta(days=1)

def statistics(grid):
    values = [value for row in grid['values'] for value in row if value is not None]
    return {'minimum': min(values), 'maximum': max(values), 'mean': sum(values) / len(values), 'count': len(values)}

def calculate_sunhour(request):
    scene_path = Path(request['scene_path']).resolve()
    if not scene_path.is_file(): raise ValueError('Missing analysis scene')
    location = request['location']; sky = DirectSky(float(location['latitude']), float(location['longitude']))
    grids, total_time = grids_from_request(request), 0.0
    for moment, duration in analysis_times(request.get('sunhour_parameters')):
        sun = sketchup_sky_direction(sky.sun_at_datetime(moment))
        if sun.z <= 0: continue
        queued = []
        for grid_index, grid in enumerate(grids):
            if Vector.dot(grid['normal'], sun) > 0:
                queued += [(grid_index, row, column, Ray(origin, sun)) for row, column, origin in grid['points']]
        for batch in chunks(queued):
            for item, hit in run_ray_batches(scene_path, batch):
                if hit is None: grids[item[0]]['values'][item[1]][item[2]] += duration
        total_time += duration
    return {'analysis': 'sunhour', 'unit': 'h', 'value_range': total_time,
            'grids': [{'id': grid['id'], 'values': grid['values'], 'statistics': statistics(grid)} for grid in grids]}

def calculate_radiation(request):
    scene_path, sky_path = Path(request['scene_path']).resolve(), Path(request['cumulative_sky_path']).resolve()
    if not scene_path.is_file() or not sky_path.is_file(): raise ValueError('Missing radiation scene or cumulative sky data')
    sky = CumulativeSky.from_period(read_cumulative_sky_matrix(str(sky_path)), 0, CumulativeSky.HOURS_PER_YEAR)
    grids = grids_from_request(request)
    def radiation_rays():
        for grid_index, grid in enumerate(grids):
            for row, column, origin in grid['points']:
                for source_direction, irradiance in zip(sky.positions, sky.values):
                    direction = sketchup_sky_direction(source_direction)
                    cosine = max(Vector.dot(grid['normal'], direction), 0.0)
                    if cosine > 0 and irradiance > 0:
                        yield (grid_index, row, column, float(irradiance * cosine), Ray(origin, direction))
    for item, hit in run_ray_batches(scene_path, radiation_rays()):
        if hit is None: grids[item[0]]['values'][item[1]][item[2]] += item[3]
    return {'analysis': 'radiation', 'unit': 'kWh/m2', 'value_range': 1500.0,
            'grids': [{'id': grid['id'], 'values': grid['values'], 'statistics': statistics(grid)} for grid in grids]}

def execute(request_path):
    request_path = Path(request_path).resolve(); request = json.loads(request_path.read_text(encoding='utf-8-sig')); job_id = request.get('job_id')
    try:
        if request.get('schema_version') != SCHEMA_VERSION or not job_id: raise ValueError('Unsupported surface-analysis request')
        if request.get('analysis') == 'sunhour': result = calculate_sunhour(request)
        elif request.get('analysis') == 'radiation': result = calculate_radiation(request)
        else: raise ValueError(f"Unsupported surface analysis: {request.get('analysis')!r}")
        result.update({'schema_version': SCHEMA_VERSION, 'job_id': job_id, 'success': True})
    except Exception as error:
        result = {'schema_version': SCHEMA_VERSION, 'job_id': job_id, 'success': False, 'error': str(error), 'traceback': traceback.format_exc()}
        atomic_json(request_path.parent / 'result.json', result); raise
    atomic_json(request_path.parent / 'result.json', result); return result

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(); parser.add_argument('request'); execute(parser.parse_args().request)
