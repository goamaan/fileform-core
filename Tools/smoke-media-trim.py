#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real CLI trim acceptance against the existing verified source-built media pack."""
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

root = Path(__file__).resolve().parents[1]
pack = Path(os.environ.get('FILEFORM_MEDIA_PACK', root / 'Artifacts/MediaPack')).resolve()
assert (pack / 'manifest.json').is_file(), 'Build the pinned media pack before this smoke test; media verification cannot be skipped.'
cli = root / '.build/debug/fileform'
ffmpeg = pack / 'bin/ffmpeg'
ffprobe = pack / 'bin/ffprobe'
env = {**os.environ, 'FILEFORM_MEDIA_PACK': str(pack)}


def tool(executable, *args):
    result = subprocess.run([str(executable), *map(str, args)], capture_output=True, env=env, timeout=60)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    return result.stdout


def run(*args, status=0):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True, env=env, timeout=60)
    assert result.returncode == status, (result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def seconds(value):
    return value['ticks'] / value['timescale']


with tempfile.TemporaryDirectory(prefix='fileform-trim-smoke-') as directory:
    work = Path(directory)
    source = work / 'timed recording.wav'
    pcm = b''.join(struct.pack('<h', round(math.sin(index / 48000 * 440 * 2 * math.pi) * 12000)) for index in range(288000))
    with wave.open(str(source), 'wb') as writer:
        writer.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        writer.writeframes(pcm)
    digest = hashlib.sha256(source.read_bytes()).digest()
    dry = work / 'dry.wav'
    plan = run('media', 'trim', source, '--to', 'wav', '--start', '48001/48000', '--end', '144013/48000', '--output', dry, '--dry-run', '--json')
    assert not dry.exists()
    assert plan['mediaTrim']['requested'] == plan['mediaTrim']['realized']
    output = work / 'exact.wav'
    report = run('media', 'trim', source, '--to', 'wav', '--start', '48001/48000', '--end', '144013/48000', '--output', output, '--json')
    decoded = tool(ffmpeg, '-v', 'error', '-i', output, '-map', '0:a:0', '-c:a', 'pcm_s16le', '-f', 's16le', '-')
    assert decoded == pcm[48001 * 2:144013 * 2]
    assert report['operationID'] == 'media.trim' and not report['mediaTrim']['copiedStreams']
    assert report['artifacts'][0]['bytes'] == output.stat().st_size
    assert abs(seconds(report['mediaTrim']['outputDuration']) - 96012 / 48000) < 0.000022
    invalid = work / 'invalid.wav'
    assert run('media', 'trim', source, '--to', 'wav', '--start', '2', '--end', '1', '--output', invalid, '--json', status=2)['code'] == 'invalid_request'
    assert run('media', 'trim', source, '--to', 'wav', '--start', '1', '--end', '7', '--output', invalid, '--json', status=2)['code'] == 'invalid_request'
    assert run('media', 'trim', source, '--to', 'mp3', '--start', '1', '--end', '2', '--output', invalid, '--json', status=3)['code'] == 'unsupported'
    assert not invalid.exists()
    alias = work / 'alias.wav'
    os.link(source, alias)
    assert run('media', 'trim', source, '--to', 'wav', '--start', '1', '--end', '2', '--output', alias, '--collision', 'rename', '--json', status=2)['code'] == 'invalid_request'
    assert not (work / 'alias-1.wav').exists()

    amplitude_source = work / 'amplitude-seconds.wav'
    with wave.open(str(amplitude_source), 'wb') as writer:
        writer.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        writer.writeframes(b''.join(struct.pack('<h', (index // 48000 + 1) * 1000) for index in range(288000)))
    gapped = work / 'gapped-audio.m4a'
    tool(ffmpeg, '-v', 'error', '-i', amplitude_source, '-af', r'asetpts=PTS+gte(T\,2)*2/TB', '-c:a', 'aac', gapped)
    gap_digest = hashlib.sha256(gapped.read_bytes()).digest()
    timed_oracle = tool(ffmpeg, '-v', 'error', '-i', gapped, '-af', 'atrim=start=4.2:end=4.8,asetpts=PTS-STARTPTS',
                        '-c:a', 'pcm_s16le', '-f', 's16le', '-')
    assert len(timed_oracle) == 28800 * 2
    assert abs(struct.unpack_from('<h', timed_oracle, (len(timed_oracle) // 4) * 2)[0] - 3000) < 100
    gap_output = work / 'gapped-must-not-publish.wav'
    error = run('media', 'trim', gapped, '--to', 'wav', '--start', '4.2', '--end', '4.8', '--output', gap_output, '--json', status=3)
    assert error['code'] == 'unsupported' and 'audio clock' in error['message']
    assert not gap_output.exists() and hashlib.sha256(gapped.read_bytes()).digest() == gap_digest

    raw = work / 'markers.rgb'
    raw.write_bytes(b''.join(bytes((index * 4, 250 - index * 3, index * 2)) * (160 * 96) for index in range(60)))
    video = work / 'marker video.mp4'
    tool(ffmpeg, '-v', 'error', '-f', 'rawvideo', '-pixel_format', 'rgb24', '-video_size', '160x96', '-framerate', '10', '-i', raw,
         '-i', source, '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-b:v', '300000', '-g', '10', '-bf', '0', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video)
    original_video = hashlib.sha256(video.read_bytes()).digest()
    fast = work / 'fast.mp4'
    planned = run('media', 'trim', video, '--to', 'mp4', '--start', '1.35', '--end', '3.57', '--mode', 'copy', '--output', fast, '--dry-run', '--json')
    assert seconds(planned['mediaTrim']['realized']['start']) == 1
    assert seconds(planned['mediaTrim']['realized']['end']) == 4
    assert not fast.exists()
    copied = run('media', 'trim', video, '--to', 'mp4', '--start', '1.35', '--end', '3.57', '--mode', 'copy', '--output', fast, '--json')
    assert copied['mediaTrim']['copiedStreams']
    assert abs(seconds(copied['mediaTrim']['outputDuration']) - 3) <= seconds(copied['mediaTrim']['durationTolerance']) + 0.001

    def packet_hashes(path):
        data = json.loads(tool(ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_packets', '-show_entries', 'packet=data_hash', '-show_data_hash', 'sha256', '-of', 'json', path))
        return [packet['data_hash'] for packet in data['packets']]

    assert packet_hashes(fast) == packet_hashes(video)[10:40]
    exact_video = work / 'exact.mp4'
    exact = run('media', 'trim', video, '--to', 'mp4', '--start', '1.35', '--end', '3.57', '--output', exact_video, '--json')
    assert not exact['mediaTrim']['copiedStreams']
    colors = tool(ffmpeg, '-v', 'error', '-i', exact_video, '-map', '0:v:0', '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-')
    assert len(colors) == 22 * 3
    for frame in range(22):
        expected = ((frame + 14) * 4, 250 - (frame + 14) * 3, (frame + 14) * 2)
        assert all(abs(colors[frame * 3 + channel] - expected[channel]) <= 12 for channel in range(3))
    audio_only = run('media', 'trim', video, '--to', 'm4a', '--start', '1.35', '--end', '3.57', '--mode', 'copy', '--output', work / 'extracted.m4a', '--json')
    assert abs(seconds(audio_only['mediaTrim']['realized']['start']) - 1.344) < 0.000001
    assert abs(seconds(audio_only['mediaTrim']['outputDuration']) - 2.24) < 0.001
    assert audio_only['mediaTrim']['audioStreamIndex'] == 1
    inventory = run('capabilities', '--input', video, '--inventory')
    assert any(route['operationID'] == 'media.trim' and route['available'] for route in inventory['routes'])
    assert all(route['outputFormat'] != 'mp3' for route in inventory['routes'] if route['operationID'] == 'media.trim')
    mp3_enabled = 'libmp3lame' in json.loads((pack / 'manifest.json').read_text()).get('audioEncoders', [])
    assert any(route['operationID'] == 'file.convert' and route['outputFormat'] == 'mp3' and route['available'] for route in inventory['routes']) == mp3_enabled
    timeline = run('media', 'inspect', source, '--json')
    assert seconds(timeline['duration']) == 6 and timeline['audioTracks'][0]['decodedSamples'] == 288000
    waveform = run('media', 'waveform', source, '--bins', '32', '--json')
    assert len(waveform['buckets']) == 32
    assert seconds(waveform['buckets'][-1]['interval']['end']) == 6
    assert all(abs(bucket['maximum'][0] - 12000 / 32768) < 0.0001 for bucket in waveform['buckets'])
    normalized = work / 'normalized.wav'
    run('media', 'preview', source, '--output', normalized, '--json')
    assert tool(ffmpeg, '-v', 'error', '-i', normalized, '-c:a', 'pcm_s16le', '-f', 's16le', '-') == pcm
    assert run('media', 'preview', source, '--output', alias, '--json', status=2)['code'] == 'invalid_request'
    assert run('media', 'waveform', gapped, '--json', status=3)['code'] == 'unsupported'
    video_timeline = run('media', 'inspect', video, '--json')
    assert video_timeline['video']['frameCount'] == 60
    poster = work / 'poster.png'
    run('media', 'preview', video, '--poster-time', '1.35', '--max-dimension', '80', '--output', poster, '--json')
    pixel = tool(ffmpeg, '-v', 'error', '-i', poster, '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-')
    assert len(pixel) == 3 and all(abs(pixel[c] - (52, 211, 26)[c]) <= 12 for c in range(3))
    assert hashlib.sha256(source.read_bytes()).digest() == digest
    assert hashlib.sha256(video.read_bytes()).digest() == original_video
    assert not list(work.glob('.fileform-*'))

print('Media trim CLI smoke passed: exact samples/frame markers, gapped-audio rejection, snapped packet copy, dry-run, audio extraction, measured waveforms/posters/playback previews, source preservation, aliases, errors and truthful capabilities.')
