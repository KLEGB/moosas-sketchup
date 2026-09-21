"""SketchUp geometry -> MoosasPy transform -> RDF/geometry output."""
from pathlib import Path
import json
from urllib.parse import urlsplit
from rdflib import Graph, Literal, URIRef
from MoosasPy.transform import transform, TransformOptions
from MoosasPy.transform.importers.geo import writeGeo
from MoosasPy.model.io.rdf import writeRDF
from skp.scripts.space_settings import document, normalize


def _namespace_group_outputs(geo_path, rdf_path, namespace):
    """Make identifiers unique across independently transformed selections."""
    geo_ids = {}
    lines = Path(geo_path).read_text(encoding='utf-8').splitlines()
    rewritten = []
    for line in lines:
        columns = line.split(',')
        if len(columns) >= 3 and columns[0] == 'f':
            geo_ids[columns[2]] = f'{namespace}_{columns[2]}'
            columns[2] = geo_ids[columns[2]]
            line = ','.join(columns)
        rewritten.append(line)
    Path(geo_path).write_text('\n'.join(rewritten) + '\n', encoding='utf-8')

    graph = Graph()
    graph.parse(rdf_path, format='turtle')

    def remap_uri(node):
        if not isinstance(node, URIRef):
            return node
        value = str(node)
        # Moosas emits local identifiers for elements, spaces, levels, and
        # geometry. Ontology predicates and classes are absolute URIs.
        if urlsplit(value).scheme:
            return node
        for old_id in sorted(geo_ids, key=len, reverse=True):
            if value == old_id:
                return URIRef(geo_ids[old_id])
            if value.startswith(old_id) and value[len(old_id):].startswith(('fv', 'fh')):
                return URIRef(geo_ids[old_id] + value[len(old_id):])
        return URIRef(f'{namespace}_{value}')

    triples = list(graph)
    graph.remove((None, None, None))
    for subject, predicate, obj in triples:
        local_predicate = str(predicate).rsplit('#', 1)[-1].rsplit('/', 1)[-1]
        mapped_subject = remap_uri(subject)
        mapped_predicate = remap_uri(predicate)
        mapped_object = remap_uri(obj)
        if isinstance(obj, Literal) and local_predicate in {'Uid', 'faceId'}:
            mapped_object = Literal(
                f'{namespace}_{obj}', datatype=obj.datatype, lang=obj.language
            )
        graph.add((mapped_subject, mapped_predicate, mapped_object))
    graph.serialize(destination=rdf_path, format='turtle', encoding='utf-8')

def execute(request):
    if not isinstance(request, dict):
        request = json.loads(Path(request).read_text(encoding='utf-8-sig'))
    settings = document(request['settings_path'])['spaces'] if request.get('settings_path') else {}
    matched = set()
    for file_index, (source, rdf, geo) in enumerate(zip(
        request['input_file'], request['rdf_file'], request['geo_file'], strict=True
    )):
        model = transform(source, input_type='geo', options=TransformOptions(
            solve_duplicated=True, solve_redundant=True, solve_overlap=True,
            break_wall_vertical=True, break_wall_horizontal=True, attach_shading=False))
        for space in model.spaceList:
            record = settings.get(str(space.id))
            if record:
                space.settings.update(normalize(record['values']))
                space.explicit_settings = list(record.get('explicit', []))
                matched.add(str(space.id))
        writeGeo(geo, model=model)
        writeRDF(model, rdf, fileFormat='turtle')
        _namespace_group_outputs(geo, rdf, f'group{file_index}')
    missing = sorted(set(settings) - matched)
    if missing:
        print('Saved settings did not match current spaces:', ', '.join(missing))
    return missing

if __name__ == '__main__':
    import sys
    execute(sys.argv[1])
