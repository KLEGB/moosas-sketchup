"""Prepare an isolated EPW import; the Ruby caller publishes validated assets."""
import json
import re
import traceback
from pathlib import Path
from skp.scripts.workspace import workspace
from MoosasPy.simulation.weather.epw import prepare_epw


def prepare_station(directory):
    directory = Path(directory)
    try:
        request = json.loads((directory / 'request.json').read_text(encoding='utf-8-sig'))
        with workspace(directory):
            prepared = prepare_epw(str(directory / 'source.epw'), str(directory / 'prepared'))
        location = prepared.weather.location
        if not re.fullmatch(r'[0-9]+', location.station_id):
            raise ValueError('EPW station ID must contain digits only')
        result = {'station': [location.station_id, request.get('city') or location.city,
                              location.state, location.latitude, location.longitude,
                              location.altitude, location.pressure],
                  'weather_file': prepared.weather.weather_file,
                  'sky_file': prepared.cumulative_sky_file,
                  'hours': len(prepared.weather.temperature)}
        (directory / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        return result
    except Exception as error:
        (directory / 'error.json').write_text(json.dumps({'message': str(error), 'traceback': traceback.format_exc()}, ensure_ascii=False), encoding='utf-8')
        raise


if __name__ == '__main__':
    import sys
    prepare_station(sys.argv[1])
