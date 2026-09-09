#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real qpdf/native-worker extraction CLI, portable setup and publication checks."""
import argparse
import contextlib
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse
import importlib.util

root = Path(__file__).resolve().parents[1]
cli = root/'.build/debug/fileform'
pack = Path(os.environ.get('FILEFORM_PDF_PACK', root/'Artifacts/PDFPack')).resolve()

def run(*args, status=0):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True,
                            env={**os.environ, 'FILEFORM_PDF_PACK': str(pack)})
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)

def path(artifact):
    return Path(unquote(urlparse(artifact['url']).path))

parser = argparse.ArgumentParser()
parser.add_argument('--work', type=Path, help='Keep fixtures and JSON evidence in a new directory.')
options = parser.parse_args()
if options.work:
    options.work.mkdir(parents=True, exist_ok=False)
context = contextlib.nullcontext(options.work) if options.work else tempfile.TemporaryDirectory(prefix='fileform-pdf-images-')
with context as temporary:
    work = Path(temporary).resolve()
    spec = importlib.util.spec_from_file_location('fixtures', root/'Tools/generate-pdf-image-fixtures.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.generate(work/'inputs')
    original = work/'inputs/supported.pdf'
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (work/'inputs').iterdir()}
    common = ['pdf', 'extract-images', '--input', original, '--json']
    plan = run(*common, '--output', work/'images', '--dry-run')
    assert plan['pdfImageExtraction']['discoveredCount'] == 2
    assert plan['pdfImageExtraction']['supportedCount'] == 2
    assert not (work/'images').exists()
    (work/'plan.json').write_text(json.dumps(plan, indent=2))
    (work/'request.json').write_text(json.dumps(plan['request'], indent=2))
    result = run('transform', work/'request.json', '--json')
    assert result['operationID'] == 'pdf.extract-images' and result['status'] == 'succeeded'
    assert len(result['artifacts']) == 2
    for artifact in result['artifacts']:
        candidate = artifact['pdfEmbeddedImage']
        assert hashlib.sha256(path(artifact).read_bytes()).hexdigest() == candidate['sha256']
        assert candidate['byteCount'] == artifact['bytes'] == path(artifact).stat().st_size
        assert candidate['width'] == 2 and candidate['height'] == 2
        if artifact['format'] == 'jpeg':
            assert path(artifact).read_bytes() == (work/'inputs/original.jpg').read_bytes()
            assert [p['pageIndex'] for p in candidate['resourcePages']] == [0, 1]
        else:
            assert candidate['resourcePaths'] == ['page 1: /Form → /RGBA']
            assert candidate['encodingOutcome'] == 'reconstructedPixels'
    (work/'result.json').write_text(json.dumps(result, indent=2))
    assert run(*common, '--output', work/'images', status=5)['code'] == 'destination_exists'
    renamed = run(*common, '--output', work/'images', '--collision', 'rename')
    assert path(renamed['artifacts'][0]).parent.name == 'images-1'
    selected = run(*common, '--pages', '2,2', '--output', work/'selected')
    assert len(selected['artifacts']) == 1 and selected['artifacts'][0]['format'] == 'jpeg'
    assert run(*common, '--pages', '99', '--output', work/'bad-selection', status=2)['code'] == 'invalid_request'
    alias = work/'alias.pdf'; alias.symlink_to(original)
    assert run(*common, '--input', alias, '--output', work/'duplicate', status=2)['code'] == 'invalid_request'
    assert run(*common, '--output', alias, status=2)['code'] == 'invalid_request'
    copy = work/'independent.pdf'; copy.write_bytes(original.read_bytes())
    independent = run(*common, '--input', copy, '--output', work/'independent-images')
    assert len(independent['artifacts']) == 4
    assert {a['sourceIDs'][0] for a in independent['artifacts']} == {'source-1', 'source-2'}
    mixed = run('pdf', 'extract-images', '--input', work/'inputs/mixed.pdf', '--output', work/'mixed', '--json')
    assert mixed['pdfImageExtraction']['skippedCount'] == 1 and len(mixed['artifacts']) == 2
    (work/'mixed-result.json').write_text(json.dumps(mixed, indent=2))
    zero = run('pdf', 'extract-images', '--input', work/'inputs/no-images.pdf', '--output', work/'zero', '--dry-run', '--json')
    assert zero['pdfImageExtraction']['discoveredCount'] == 0
    assert run('pdf', 'extract-images', '--input', work/'inputs/no-images.pdf', '--output', work/'zero', '--json', status=3)['code'] == 'unsupported'
    assert not (work/'zero').exists()
    generated = run('pdf', 'extract-images', '--input', work/'inputs/generation.pdf', '--output', work/'generation', '--json')
    assert next(a for a in generated['artifacts'] if a['format'] == 'jpeg')['pdfEmbeddedImage']['generation'] == 7
    assert next(path(a) for a in generated['artifacts'] if a['format'] == 'jpeg').read_bytes() == (work/'inputs/original.jpg').read_bytes()
    encrypted = work/'encrypted.pdf'
    subprocess.run([str(pack/'bin/qpdf'), str(original), '--encrypt', 'reader', 'owner', '256', '--', str(encrypted)], check=True, capture_output=True)
    assert run('pdf','extract-images','--input', encrypted,'--output',work/'encrypted-images','--json',status=3)['code'] == 'unsupported'
    assert not (work/'encrypted-images').exists()
    setup = run('setup','create',work/'request.json','--name','Embedded originals','--json')
    assert setup['format'] == 'images' and 'file:' not in json.dumps(setup)
    (work/'setup.json').write_text(json.dumps(setup, indent=2))
    applied = run('setup','apply',work/'setup.json','--asset',f'source-1={original}','--output',work/'setup-images','--json')
    assert len(applied['artifacts']) == 2
    caps = run('capabilities','--inventory','--json')
    assert any(r['operationID'] == 'pdf.extract-images' and r['available'] and r['outputFormat'] == 'images' for r in caps['routes'])
    for source, digest in hashes.items(): assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
    assert not list(work.glob('.fileform-*'))
    (work/'evidence.json').write_text(json.dumps({'passed': True, 'jpegBytesPreserved': True, 'uniqueObjects': 2, 'mixedSkipped': 1, 'objectGeneration': 7, 'scope': 'resource-referenced images; no paint-occurrence claim'}, indent=2))
print('PDF image extraction CLI passed: inherited/indirect/nested/reused objects, generation, mixed JPEG/PNG, explicit skips/no-images, selection, aliases/source identity, encryption rejection, transform/setup, checksums, no-clobber/rename, source preservation.')
