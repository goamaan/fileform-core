#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise a pinned downloader against generated, locally trusted HTTPS fixtures.

This is a feasibility probe, not Fileform's production acquisition adapter.
No third-party media, ambient credentials, or global certificate changes.
"""
import argparse
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import signal
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--downloader', type=Path, required=True)
parser.add_argument('--media-pack', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
downloader = args.downloader.resolve()
ffmpeg = args.media_pack.resolve() / 'bin/ffmpeg'
report = {'schemaVersion': 1, 'productionAdapter': False, 'checks': {}}

def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30, **kwargs)

with tempfile.TemporaryDirectory(prefix='fileform-downloader-spike-') as temporary:
    work = Path(temporary)
    media = work / 'media'; media.mkdir()
    output = work / 'output'; output.mkdir()
    config = work / 'ignored-config'; (config / 'yt-dlp').mkdir(parents=True)
    # If configuration leaks in, even a simple version/inspection command fails.
    (config / 'yt-dlp/config').write_text('--this-option-must-never-be-loaded\n')
    raw = media / 'frames.rgb'
    raw.write_bytes(b''.join(bytes((i * 5, 240 - i * 4, i * 3)) * (160 * 96) for i in range(30)))
    wav = media / 'tone.wav'
    with wave.open(str(wav), 'wb') as writer:
        writer.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        writer.writeframes(b''.join(struct.pack('<h', round(10000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(144000)))
    video = media / 'clip.mp4'
    generated = run([ffmpeg, '-v', 'error', '-f', 'rawvideo', '-pixel_format', 'rgb24',
                     '-video_size', '160x96', '-framerate', '10', '-i', raw, '-i', wav,
                     '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-b:v', '300000',
                     '-g', '10', '-bf', '0', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video])
    assert generated.returncode == 0, generated.stderr.decode()
    generated = run([ffmpeg, '-v', 'error', '-i', video, '-c', 'copy', '-f', 'hls',
                     '-hls_time', '1', '-hls_list_size', '0', media / 'stream.m3u8'])
    assert generated.returncode == 0, generated.stderr.decode()
    (media / 'items.html').write_text('<html><head><title>Two owned clips</title></head><body>'
        '<video controls src="/clip.mp4"></video><video controls src="/second.mp4"></video></body></html>')
    certificate = work / 'fixture.pem'; key = work / 'fixture.key'
    openssl_config = work / 'openssl.cnf'
    openssl_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
        '[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n'
        'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n'
        'extendedKeyUsage=serverAuth\n')
    cert = run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-days', '1', '-config', openssl_config, '-keyout', key, '-out', certificate])
    assert cert.returncode == 0, cert.stderr.decode()
    requests = []
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw): super().__init__(*a, directory=str(media), **kw)
        def log_message(self, *_): pass
        def do_GET(self):
            requests.append(self.path)
            if self.path == '/redirect':
                self.send_response(302); self.send_header('Location', '/clip.mp4'); self.end_headers(); return
            if self.path == '/second.mp4': self.path = '/clip.mp4'
            if self.path in ['/unknown.mp4', '/slow.mp4']:
                self.send_response(200); self.send_header('Content-Type', 'video/mp4'); self.end_headers()
                payload = video.read_bytes()
                try:
                    if self.path == '/slow.mp4':
                        for _ in range(100): self.wfile.write(payload); self.wfile.flush(); time.sleep(0.1)
                    else: self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
                return
            super().do_GET()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(certificate, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    base = f'https://127.0.0.1:{server.server_port}'
    env = {'PATH': '/usr/bin:/bin', 'TMPDIR': str(work), 'LC_ALL': 'C',
           'SSL_CERT_FILE': str(certificate), 'XDG_CONFIG_HOME': str(config)}
    common = [downloader, '--ignore-config', '--no-plugin-dirs', '--no-update',
              '--no-remote-components', '--no-js-runtimes', '--no-cache-dir',
              '--compat-options', 'no-certifi', '--proxy', '', '--socket-timeout', '5',
              '--retries', '0', '--fragment-retries', '0', '--no-progress',
              '--no-overwrites', '--ffmpeg-location', ffmpeg.parent]
    def invoke(extra, check=True):
        result = run(common + extra, env=env, cwd=work)
        if check: assert result.returncode == 0, result.stderr.decode()
        return result
    try:
        report['version'] = invoke(['--version']).stdout.decode().strip()
        assert report['version'] == '2026.08.19'
        report['checks']['ignoredConfiguration'] = True
        untrusted_env = {k: v for k, v in env.items() if k != 'SSL_CERT_FILE'}
        untrusted = run(common + ['--dump-single-json', '--skip-download', base + '/clip.mp4'], env=untrusted_env, cwd=work)
        assert untrusted.returncode != 0 and b'CERTIFICATE_VERIFY_FAILED' in untrusted.stderr
        report['checks']['untrustedTLSRejected'] = True
        for name in ['clip.mp4', 'redirect', 'unknown.mp4']:
            metadata = json.loads(invoke(['--dump-single-json', '--skip-download', base + '/' + name]).stdout)
            assert metadata.get('formats') or metadata.get('url'), metadata
            destination = output / (name.replace('.', '-') + '.mp4')
            invoke(['-f', 'best', '-o', destination, base + '/' + name])
            assert destination.read_bytes() == video.read_bytes()
            report['checks'][name] = {'byteIdentical': True, 'bytes': destination.stat().st_size}
        metadata = json.loads(invoke(['--dump-single-json', '--skip-download', '--playlist-end', '2', base + '/items.html']).stdout)
        assert len(metadata['entries']) == 2
        report['checks']['multipleItems'] = 2
        hls = output / 'hls.mp4'
        invoke(['--downloader', 'native', '-o', hls, base + '/stream.m3u8'])
        decoded = run([ffmpeg, '-v', 'error', '-i', hls, '-map', '0:v:0', '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'])
        assert decoded.returncode == 0 and len(decoded.stdout) == 90
        for i in range(30):
            expected = (i * 5, 240 - i * 4, i * 3)
            assert max(abs(decoded.stdout[i * 3 + c] - expected[c]) for c in range(3)) <= 12
        report['checks']['hls'] = {'decodedFrames': 30}
        # Probe, do not assume, whether --max-filesize enforces unknown-length streams.
        for name in ['clip.mp4', 'unknown.mp4']:
            destination = output / ('limited-' + name)
            result = invoke(['--max-filesize', '1024', '-o', destination, base + '/' + name], check=False)
            report['checks']['sizeLimit-' + name] = {'exitCode': result.returncode,
                'outputBytes': destination.stat().st_size if destination.exists() else 0}
        slow = output / 'cancelled.mp4'
        process = subprocess.Popen([str(x) for x in common + ['-o', slow, base + '/slow.mp4']],
            env=env, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 5
        while not list(output.glob('cancelled*')) and time.monotonic() < deadline: time.sleep(.02)
        assert process.poll() is None, 'Slow fixture must still be active'
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
        residue = sorted(p.name for p in output.glob('cancelled*'))
        report['checks']['cancel'] = {'terminated': process.returncode != 0, 'stagingResidue': residue}
        report['requests'] = requests
        report['limitations'] = ['No third-party service coverage claimed.',
            'Production must enforce its own streaming byte ceiling and remove owned partial files.',
            'Pinned JS runtime, signed pack installation, sandbox and redirect/address policy remain separate gates.']
    finally:
        server.shutdown(); server.server_close()
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
