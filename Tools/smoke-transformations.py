#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise compiled CLI contracts independently of the private application."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
cli = root / '.build/debug/fileform'

def run(*args, status=0):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)

with tempfile.TemporaryDirectory(prefix='fileform-transform-smoke-') as folder:
    work = Path(folder)
    source = work / 'source 日本語.csv'
    source.write_text('name,note\nAda,"00123"\n', encoding='utf-8')
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    request = json.loads((root / 'Examples/Transformations/convert.json').read_text())
    request['assets'][0]['url'] = source.as_uri()
    request['output'].update(destination=(work / 'table.json').as_uri(), format='json')
    request_path = work / 'request.json'
    request_path.write_text(json.dumps(request))
    plan = run('transform', request_path, '--dry-run', '--json')
    assert plan['inputs'][0]['inspection']['family'] == 'table'
    assert not (work / 'table.json').exists()
    result = run('transform', request_path, '--json')
    assert result['status'] == 'succeeded' and len(result['artifacts']) == 1
    assert json.loads((work / 'table.json').read_text()) == [{'name': 'Ada', 'note': '00123'}]
    recipe = run('setup', 'create', request_path, '--name', 'Table as JSON', '--json')
    assert str(work) not in json.dumps(recipe) and source.as_uri() not in json.dumps(recipe)
    recipe_path = work / 'setup.json'
    recipe_path.write_text(json.dumps(recipe))
    source2 = work / 'other.csv'
    source2.write_text('name,note\nLin,"00234"\n')
    applied = run('setup', 'apply', recipe_path, '--asset', f'source={source2}', '--output', work / 'other.json', '--json')
    assert applied['status'] == 'succeeded'
    assert json.loads((work / 'other.json').read_text()) == [{'name': 'Lin', 'note': '00234'}]
    request['schemaVersion'] = 999
    request_path.write_text(json.dumps(request))
    assert run('transform', request_path, '--json', status=2)['code'] == 'invalid_request'
    request_path.write_bytes(b'x' * 1048577)
    assert run('transform', request_path, '--json', status=6)['code'] == 'resource_limit'
    inventory = run('capabilities', '--input', source, '--inventory')
    assert inventory['schemaVersion'] == 1 and inventory['inputFamily'] == 'table'
    assert all(route['operationID'] == 'file.convert' for route in inventory['routes'])
    assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
    assert not list(work.glob('.fileform-*'))
    subprocess.run([str(root / 'Tools/generate-fixtures.sh'), str(work / 'inputs')], check=True, stdout=subprocess.DEVNULL)
    image = work / 'inputs/Studio chart.png'
    original = image.read_bytes()
    isolated = run('inspect', image, '--worker', root / '.build/debug/fileform-worker', '--json')
    assert isolated['family'] == 'image'
    preview = run('preview', image, '--output', work / 'preview.png', '--maximum-dimension', '240', '--json')
    assert preview['status'] == 'succeeded'
    import struct
    png = (work / 'preview.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', png[16:24]) == (240, 180)
    assert image.read_bytes() == original
print('Transformation CLI passed: actual output, dry-run, source retention, portable setup rebinding, bounded JSON, inventory and real isolated PNG preview.')
