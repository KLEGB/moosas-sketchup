"""Prepare targeted RDF/JSON updates; Ruby publishes only after context checks."""
import hashlib
import json
import math
from pathlib import Path
from rdflib import Graph, Namespace, Literal
from rdflib.namespace import RDF

M = Namespace('https://moosas#')
BOT = Namespace('https://w3id.org/bot#')
FIELDS = {'zone_name', 'zone_wallU', 'zone_winU', 'zone_win_SHGC', 'zone_c_temp',
          'zone_h_temp', 'zone_collingEER', 'zone_HeatingEER', 'zone_ppsm',
          'zone_equipment', 'zone_lighting', 'zone_infiltration'}
ELEMENT_FIELDS = {
    'wall': {'u_value', 'heat_storage_coefficient', 'thickness', 'reflection'},
    'window': {'u_value', 'shgc', 'operable', 'reflection', 'transparency'},
}

def normalize(values):
    values = dict(values)
    if 'zone_inflitration' in values:
        values.setdefault('zone_infiltration', values.pop('zone_inflitration'))
    return values

def document(path):
    path = Path(path)
    data = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
    if data.get('schema_version', 0) >= 2:
        data.setdefault('draft_revision', 0)
        data.setdefault('drafts', {})
        return data
    return {'schema_version': 3, 'revision': 0, 'draft_revision': 0, 'drafts': {}, 'spaces': {
        key: {'values': normalize(value), 'explicit': [], 'legacy': True}
        for key, value in data.items() if isinstance(value, dict)}}

def validate(field, value, settings):
    if field not in FIELDS:
        raise ValueError('Unsupported space field')
    if field == 'zone_name':
        value = str(value)
        if not value.strip() or any(c in value for c in '\r\n'):
            raise ValueError('名称不能为空或包含换行 / A single-line name is required')
        return value.strip()
    if isinstance(value, bool):
        raise ValueError('Expected a number')
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('数值必须有限 / A finite number is required')
    if field in {'zone_wallU','zone_winU','zone_collingEER','zone_HeatingEER'} and value <= 0:
        raise ValueError('该值必须大于零 / Value must be positive')
    if field in {'zone_ppsm','zone_equipment','zone_lighting','zone_infiltration'} and value < 0:
        raise ValueError('该值不能为负 / Value must be nonnegative')
    if field == 'zone_win_SHGC' and not 0 <= value <= 1:
        raise ValueError('SHGC 必须在 0–1 之间')
    combined = normalize(settings) | {field: value}
    if field in {'zone_c_temp', 'zone_h_temp'} and float(combined['zone_h_temp']) > float(combined['zone_c_temp']):
        raise ValueError('采暖设定温度不能高于制冷设定温度')
    return value

def validate_element(kind, field, value):
    if kind not in ELEMENT_FIELDS or field not in ELEMENT_FIELDS[kind]:
        raise ValueError('Unsupported element field')
    if isinstance(value, bool):
        raise ValueError('Expected a number')
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('Value must be finite')
    if field in {'u_value', 'thickness'} and value <= 0:
        raise ValueError('Value must be positive')
    if field == 'heat_storage_coefficient' and value < 0:
        raise ValueError('Value must be nonnegative')
    if field in {'shgc', 'operable', 'reflection', 'transparency'} and not 0 <= value <= 1:
        raise ValueError('Ratio must be between 0 and 1')
    return value

def space_nodes(graph):
    return {str(graph.value(s, M.Uid) or str(s).rsplit('Space_', 1)[-1]): s
            for s in graph.subjects(RDF.type, BOT.Space)}

def patch_settings(graph, subject, values, explicit=()):
    for key, value in normalize(values).items():
        if key not in FIELDS:
            continue
        # Remove legacy and canonical aliases only for the edited field.
        for old in ([key, 'zone_inflitration'] if key == 'zone_infiltration' else [key]):
            graph.remove((subject, Literal(old), None))
            graph.remove((subject, M[old], None))
            graph.remove((subject, M.hasSetting, Literal(old)))
        graph.add((subject, M.hasSetting, Literal(key)))
        graph.add((subject, M[key], Literal(value)))
    for key in explicit:
        graph.add((subject, M.explicitSetting, Literal(key)))

def element_nodes(graph):
    return {str(graph.value(s, M.Uid) or str(s).rsplit('element_', 1)[-1]): s
            for s in graph.subjects(RDF.type, BOT.Element)}

def patch_element(graph, subject, values):
    for key, value in values.items():
        graph.remove((subject, M[key], None))
        graph.remove((subject, M.hasSetting, Literal(key)))
        graph.add((subject, M.hasSetting, Literal(key)))
        graph.add((subject, M[key], Literal(value)))
        graph.add((subject, M.explicitSetting, Literal(key)))
        # Compatibility for old readers.
        if key == 'u_value':
            graph.remove((subject, M.U_Value, None)); graph.add((subject, M.U_Value, Literal(value)))
        elif key == 'shgc':
            graph.remove((subject, M.SHGC, None)); graph.add((subject, M.SHGC, Literal(value)))
        elif key == 'operable':
            graph.remove((subject, M.operable, None)); graph.add((subject, M.operable, Literal(value)))

def prepare_batch(request_path):
    request_path = Path(request_path); request = json.loads(request_path.read_text(encoding='utf-8-sig'))
    directory = request_path.parent; data = document(request['settings_path'])
    if data['revision'] != request['settings_version']:
        raise ValueError('设置已变化，请刷新 / Settings version changed')
    changes_by_file, applied = {}, []
    for item in request.get('items', []):
        kind, ident, values = item.get('type'), str(item.get('id')), dict(item.get('values') or {})
        if kind == 'space':
            values = {key: validate(key, value, item.get('current_values') or {}) for key, value in values.items()}
        else:
            values = {key: validate_element(kind, key, value) for key, value in values.items()}
        found = []
        for rdf_path in request['rdf_paths']:
            graph = changes_by_file.get(rdf_path, (None, None))[0] if rdf_path in changes_by_file else Graph().parse(rdf_path, format='turtle')
            subject = (space_nodes(graph) if kind == 'space' else element_nodes(graph)).get(ident)
            if subject is not None: found.append((rdf_path, graph, subject))
        if len(found) != 1: raise ValueError(f'{kind} {ident} must match exactly one RDF')
        rdf_path, graph, subject = found[0]; changes_by_file[rdf_path] = (graph, True)
        if kind == 'space':
            patch_settings(graph, subject, values, values.keys())
            record = data['spaces'].setdefault(ident, {'values': normalize(item.get('current_values') or {}), 'explicit': []})
            record['values'] = normalize(record.get('values', {})) | values
            record['explicit'] = sorted(set(record.get('explicit', [])) | set(values))
        else:
            patch_element(graph, subject, values)
        applied.append({'type': kind, 'id': ident, 'values': values})
    data['revision'] += 1; data['drafts'] = {}; data['draft_revision'] += 1
    changes = []
    for index, (target, (graph, _)) in enumerate(changes_by_file.items()):
        staged = directory / f'prepared-{index}.ttl'; graph.serialize(staged, format='turtle'); Graph().parse(staged, format='turtle')
        target_path = Path(target); changes.append({'target': str(target_path), 'prepared': str(staged), 'sha256': hashlib.sha256(target_path.read_bytes()).hexdigest()})
    staged_json = directory / 'prepared-settings.json'; staged_json.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2), encoding='utf-8')
    setting_path = Path(request['settings_path']); changes.append({'target': str(setting_path), 'prepared': str(staged_json), 'sha256': hashlib.sha256(setting_path.read_bytes()).hexdigest() if setting_path.exists() else None})
    result = {'request_id': request['request_id'], 'revision': data['revision'], 'items': applied, 'changes': changes}
    (directory / 'result.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8'); return result

def prepare(request_path):
    request_path = Path(request_path)
    request = json.loads(request_path.read_text(encoding='utf-8-sig'))
    directory = request_path.parent
    data = document(request['settings_path'])
    if data['revision'] != request['settings_version']:
        raise ValueError('设置版本已变化，请刷新 / Settings version changed')
    sid, field = request['space_id'], request['field']
    value = validate(field, request['value'], request['current_values'])
    matches = []
    for path in request['rdf_paths']:
        graph = Graph().parse(path, format='turtle')
        subject = space_nodes(graph).get(sid)
        if subject is not None:
            matches.append((Path(path), graph, subject))
    if len(matches) != 1:
        raise ValueError('Space ID must match exactly one current RDF file')
    path, graph, subject = matches[0]
    patch_settings(graph, subject, {field: value}, [field])
    record = data['spaces'].setdefault(sid, {'values': normalize(request['current_values']), 'explicit': []})
    record['values'] = normalize(record['values']) | {field: value}
    record['explicit'] = sorted(set(record.get('explicit', [])) | {field})
    data['revision'] += 1
    staged_rdf = directory / 'prepared.ttl'
    graph.serialize(staged_rdf, format='turtle')
    Graph().parse(staged_rdf, format='turtle')
    staged_json = directory / 'prepared-settings.json'
    staged_json.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2), encoding='utf-8')
    changes = []
    for target, staged in [(path, staged_rdf), (Path(request['settings_path']), staged_json)]:
        changes.append({'target': str(target), 'prepared': str(staged),
                        'sha256': hashlib.sha256(target.read_bytes()).hexdigest() if target.exists() else None})
    result = {'request_id': request['request_id'], 'space_id': sid, 'field': field, 'value': value,
              'revision': data['revision'], 'changes': changes}
    (directory / 'result.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    return result

if __name__ == '__main__':
    import sys
    prepare(sys.argv[1])
