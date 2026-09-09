#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real CLI PDF optimization; only Python standard library and the built pack."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def fixture(path):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    for page in range(3):
        objects.append(('<< /Type /Page /Parent 2 0 R /MediaBox [10 20 430 560] '
                        '/CropBox [15 25 425 555] /TrimBox [20 30 420 550] '
                        '/BleedBox [18 28 422 552] /ArtBox [25 35 415 545] '
                        f'/Rotate {page * 90} /Resources << /Font << /F1 3 0 R >> >> '
                        f'/Contents {5 + page * 2} 0 R >>').encode())
        content = f'BT /F1 20 Tf 30 500 Td (Fileform PDF page {page + 1}) Tj ET\n'
        content += ''.join(f'q 0.2 0.4 0.6 RG {30 + row % 20} {40 + row} m 200 {40 + row} l S Q\n' for row in range(200))
        payload = content.encode()
        objects.append(f'<< /Length {len(payload)} >>\nstream\n'.encode() + payload + b'endstream')
    objects.append(b'<< /Title (Fileform structural fixture) /Author (Fileform tests) /CustomValue (Keep me) >>')
    data = bytearray(b'%PDF-1.4\n')
    offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f'{index} 0 obj\n'.encode() + value + b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        data.extend(f'{offset:010d} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R /Info {len(objects)} 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    path.write_bytes(data)


def exercise(work):
    source = work / 'Three pages.pdf'
    fixture(source)
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    env = dict(os.environ, FILEFORM_PDF_PACK=str(ROOT / 'Artifacts/PDFPack'))

    def run(*args, error=None):
        result = subprocess.run([str(ROOT / '.build/debug/fileform'), *map(str, args)],
                                env=env, text=True, capture_output=True, timeout=180)
        value = json.loads(result.stdout)
        if error:
            assert result.returncode != 0 and value['code'] == error, (result, value)
        else:
            assert result.returncode == 0, (result, value)
        return value

    inventory = run('capabilities', '--input', source, '--inventory')
    routes = [r for r in inventory['routes'] if r['backend'] == 'qpdf']
    assert len(routes) == 1 and routes[0]['available'], routes
    destination = work / 'Smaller.pdf'
    plan = run('compress', source, '--to', 'pdf', '--output', destination, '--dry-run', '--json')
    assert plan['engine'] == 'qpdf' and not destination.exists()
    result = run('compress', source, '--to', 'pdf', '--output', destination, '--json')
    assert result['status'] == 'succeeded' and destination.stat().st_size < source.stat().st_size
    count = destination.stat().st_size
    fit = run('fit', source, '--to', 'pdf', '--output', work / 'Exact fit.pdf', '--max-bytes', count, '--json')
    assert fit['status'] == 'succeeded' and fit['outputBytes'] == count
    run('fit', source, '--to', 'pdf', '--output', work / 'Too small.pdf', '--max-bytes', count - 1,
        '--json', error='target_unmet')
    assert not (work / 'Too small.pdf').exists()
    unchanged = run('compress', destination, '--to', 'pdf', '--output', work / 'Unchanged.pdf', '--json')
    assert unchanged['status'] == 'not_smaller' and not (work / 'Unchanged.pdf').exists()
    inspected = run('inspect', destination, '--worker', ROOT / '.build/debug/fileform-worker', '--json')
    assert inspected['pageCount'] == 3
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original
    assert not list(work.glob('.fileform-*'))
    (work / 'verification.json').write_text(json.dumps({'sourceSHA256': original,
        'outputSHA256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'sourceBytes': source.stat().st_size, 'outputBytes': count, 'pages': 3,
        'exactFit': True, 'targetUnmet': True, 'notSmaller': True}, indent=2) + '\n')
    print('PDF CLI passed: available route, dry run, three-page compression, exact fit, target miss, not-smaller and source retention.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=Path, help='Retain evidence in a new directory; defaults to temporary output.')
    arguments = parser.parse_args()
    if arguments.work:
        arguments.work.mkdir(parents=True, exist_ok=False)
        exercise(arguments.work.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='fileform-pdf-smoke-') as folder:
            exercise(Path(folder))
