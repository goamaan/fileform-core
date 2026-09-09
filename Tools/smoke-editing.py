#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the shipped editing commands against generated, redistributable fixtures."""
import hashlib, json, struct, subprocess, tempfile
from pathlib import Path
from urllib.parse import urlparse, unquote
root = Path(__file__).resolve().parents[1]
cli = root / '.build/debug/fileform'
def run(*args, status=0):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)
with tempfile.TemporaryDirectory(prefix='fileform-edit-smoke-') as name:
    work = Path(name)
    subprocess.run([str(root/'Tools/generate-fixtures.sh'),str(work/'inputs')],check=True,stdout=subprocess.DEVNULL)
    image, pdf = work/'inputs/Studio chart.png', work/'inputs/Project notes.pdf'
    hashes = {path:hashlib.sha256(path.read_bytes()).digest() for path in [image,pdf]}
    crop = run('image','crop',image,'--to','png','--x','100','--y','100','--width','600','--height','400',
               '--max-dimension','300','--output',work/'crop.png','--json')
    assert crop['operationID']=='image.crop' and crop['status']=='succeeded'
    assert struct.unpack('>II',(work/'crop.png').read_bytes()[16:24])==(300,200)
    merged=run('pdf','merge',pdf,image,'--output',work/'combined.pdf','--json')
    assert merged['status']=='succeeded' and len(merged['artifacts'])==1
    assert run('inspect',work/'combined.pdf','--json')['pageCount']==3
    split=run('pdf','split',work/'combined.pdf','--ranges','2;1,3','--output',work/'parts','--json')
    assert len(split['artifacts'])==2
    assert [run('inspect',Path(unquote(urlparse(a['url']).path)),'--json')['pageCount'] for a in split['artifacts']]==[1,2]
    invalid=run('pdf','split',pdf,'--ranges','0;1','--output',work/'invalid','--json',status=2)
    assert invalid['code']=='invalid_request' and not (work/'invalid').exists()
    for path,digest in hashes.items(): assert hashlib.sha256(path.read_bytes()).digest()==digest
    assert not list(work.glob('.fileform-*'))
print('Editing CLI passed: crop geometry, merged page count, atomic split cardinalities, invalid ranges and source hashes.')
