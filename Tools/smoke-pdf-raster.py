#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise page-image export through the shipped CLI and native worker."""
import argparse
import contextlib
import hashlib
import json
import struct
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cli = root / '.build/debug/fileform'

def run(*args, status=0):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)

parser = argparse.ArgumentParser()
parser.add_argument('--work', type=Path, help='Keep fixtures and results in a new directory.')
options = parser.parse_args()
if options.work:
    options.work.mkdir(parents=True, exist_ok=False)
context = contextlib.nullcontext(options.work) if options.work else tempfile.TemporaryDirectory(prefix='fileform-page-raster-')
with context as temporary:
    work = Path(temporary)
    subprocess.run([str(root / 'Tools/generate-fixtures.sh'), str(work / 'inputs')], check=True, stdout=subprocess.DEVNULL)
    pdf, image = work / 'inputs/Cropped rotated notes.pdf', work / 'inputs/Studio chart.png'
    subprocess.run(['swift', str(root / 'Tools/generate-pdf-raster-fixture.swift'), str(work / 'inputs/Project notes.pdf'), str(pdf)], check=True)
    originals = {path: hashlib.sha256(path.read_bytes()).digest() for path in [pdf, image]}
    common = ['pdf', 'pages', '--input', pdf, '--input', image, '--dpi', '72', '--json']
    plan = run(*common, '--pages', '2,1,2,3', '--output', work / 'dry', '--dry-run')
    assert plan['request']['operation']['pdfRasterize']['dpi'] == 72 and not (work / 'dry').exists()
    result = run(*common, '--pages', '2,1,2,3', '--output', work / 'pages')
    assert result['operationID'] == 'pdf.rasterize' and result['status'] == 'succeeded'
    assert len(result['artifacts']) == 4
    assert [a['sourcePages'][0]['pageIndex'] for a in result['artifacts']] == [1, 0, 1, 0]
    assert [a['sourceIDs'] for a in result['artifacts']] == [['source-1'], ['source-1'], ['source-1'], ['source-2']]
    assert (work/'pages/001.png').read_bytes() == (work/'pages/003.png').read_bytes()
    assert struct.unpack('>II', (work/'pages/004.png').read_bytes()[16:24]) == struct.unpack('>II', image.read_bytes()[16:24])
    failure = run(*common, '--pages', '99', '--output', work/'missing', status=2)
    assert failure['code'] == 'invalid_request' and not (work/'missing').exists()
    failure = run(*common, '--output', work/'pages', status=5)
    assert failure['code'] == 'destination_exists'
    renamed = run(*common, '--pages', '1', '--output', work/'pages', '--collision', 'rename')
    assert (work/'pages-1/001.png').exists() and len(renamed['artifacts']) == 1
    jpeg = run('pdf','pages','--input',pdf,'--to','jpeg','--quality','0.6','--dpi','36','--output',work/'jpeg','--json')
    assert len(jpeg['artifacts']) == 2
    for path in (work/'jpeg').iterdir():
        data = path.read_bytes()
        assert data[:2] == b'\xff\xd8' and data[-2:] == b'\xff\xd9'
    for path, digest in originals.items(): assert hashlib.sha256(path.read_bytes()).digest() == digest
    assert not list(work.glob('.fileform-*'))
print('PDF page raster CLI passed: all/selected mixed pages, DPI, PNG/JPEG, order/duplicates/provenance, dry-run, invalid selection, no-clobber/rename, source preservation.')
