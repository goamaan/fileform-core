#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""CLI direct fetch oracle using only generated local media and HTTP fixtures."""
import argparse, hashlib, http.server, json, os, subprocess, tempfile, threading, wave
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli',type=Path,default=Path('.build/debug/fileform'))
parser.add_argument('--media-pack',type=Path,default=Path('Artifacts/MediaPack'))
args=parser.parse_args(); cli=args.cli.resolve(); pack=args.media_pack.resolve()
with tempfile.TemporaryDirectory(prefix='fileform-fetch-cli-') as root:
    root=Path(root); source=root/'source.wav'
    with wave.open(str(source),'wb') as w:
        w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(b'\x01\x00'*16000)
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self,*a,**kw):super().__init__(*a,directory=str(root),**kw)
        def log_message(self,*a):pass
        def end_headers(self):self.send_header('ETag','"stable-fixture"');super().end_headers()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url=f'http://127.0.0.1:{server.server_port}/source.wav'
    env={**os.environ,'FILEFORM_MEDIA_PACK':str(pack)}
    def invoke(*arguments,success=True):
        r=subprocess.run([str(cli),*map(str,arguments)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
        assert (r.returncode==0)==success,(r.returncode,r.stderr.decode())
        return json.loads(r.stdout)
    try:
        metadata=invoke('fetch','lookup',url,'--json')
        assert metadata['expectedBytes']==source.stat().st_size
        output=root/'saved.wav'
        base=['fetch','save',url,'--to','wav','--output',output,'--json']
        plan=invoke(*base,'--dry-run'); assert not output.exists()
        assert plan['fetchSource']['entityTag']=='"stable-fixture"'
        result=invoke(*base)
        assert output.read_bytes()==source.read_bytes()
        assert result['fetchReceipt']['sha256']==hashlib.sha256(source.read_bytes()).hexdigest()
        assert 'resolvedURL' not in result['fetchReceipt']
        invoke(*base,success=False); assert output.read_bytes()==source.read_bytes()
        renamed=invoke(*base,'--collision','rename');assert Path(renamed['artifacts'][0]['url'].replace('file://','')).name=='saved-1.wav'
        wrong=root/'wrong.mp4';invoke('fetch','save',url,'--to','mp4','--output',wrong,'--json',success=False);assert not wrong.exists()
        limited=root/'limited.wav';invoke('fetch','save',url,'--to','wav','--output',limited,'--max-bytes','1024','--json',success=False);assert not limited.exists()
        assert not list(root.glob('.fileform-*'))
        print('Direct fetch CLI passed: metadata, dry-run, exact bytes/hash, exclusive collision/rename, type mismatch, byte ceiling and staging cleanup.')
    finally:server.shutdown();server.server_close()
