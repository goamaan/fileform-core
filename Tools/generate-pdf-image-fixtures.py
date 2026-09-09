#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Source-owned PDFs exercising resource graph and image encoding semantics."""
import base64
import subprocess
import sys
import zlib
from pathlib import Path


def stream(dictionary, data):
    return (dictionary + f' /Length {len(data)} >>\nstream\n').encode() + data + b'\nendstream'


def pdf(path, objects, generations=None):
    generations = generations or {}
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{number} {generations.get(number, 0)} obj\n'.encode() + obj + b'\nendobj\n'
    xref = len(data)
    data += f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode()
    for number, offset in enumerate(offsets[1:], 1):
        data += f'{offset:010} {generations.get(number, 0):05} n \n'.encode()
    data += f'trailer << /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    path.write_bytes(data)


def generate(work):
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swift', str(Path(__file__).with_name('generate-pdf-embedded-jpeg.swift')), str(work/'original.jpg')], check=True)
    jpeg = (work/'original.jpg').read_bytes()
    rgb = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    alpha = bytes([255, 128, 0, 255])
    image = '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceRGB'
    gray = image.replace('/DeviceRGB', '/DeviceGray')
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /Resources 11 0 R >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 9 0 R >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Again 5 0 R >> >> /Contents 10 0 R >>',
        stream(image+' /Filter /DCTDecode', jpeg),
        stream('<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources << /XObject << /RGBA 7 0 R /Cycle 6 0 R >> >>', b'q 80 0 0 80 100 100 cm /RGBA Do Q'),
        stream(image+' /Filter /FlateDecode /SMask 8 0 R', zlib.compress(rgb)),
        stream(gray+' /Filter /FlateDecode', zlib.compress(alpha)),
        stream('<<', b'q 80 0 0 80 0 0 cm /JPEG Do Q /Form Do'),
        stream('<<', b'q 100 0 0 100 0 0 cm /Again Do Q'),
        b'<< /XObject 12 0 R >>', b'<< /JPEG 5 0 R /Form 6 0 R >>']
    pdf(work/'supported.pdf', objects)
    generated = [value.replace(b'5 0 R', b'5 7 R') for value in objects]
    pdf(work/'generation.pdf', generated, {5: 7})
    mixed = objects.copy()
    mixed[11] = b'<< /JPEG 5 0 R /Form 6 0 R /Unsupported 13 0 R >>'
    mixed.append(stream(image.replace('/DeviceRGB', '/DeviceCMYK'), bytes(16)))
    pdf(work/'mixed.pdf', mixed)
    primary_mask = objects.copy()
    primary_mask[11] = b'<< /JPEG 5 0 R /Form 6 0 R /MaskAsPrimary 8 0 R >>'
    pdf(work/'primary-mask.pdf', primary_mask)
    empty = objects.copy(); empty[10] = b'<< >>'; empty[3] = b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>'
    empty[2] = b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>'
    pdf(work/'no-images.pdf', empty)
    for name, dictionary, data in [
        ('gray', gray, alpha),
        ('plain', image, rgb),
        ('hex', image+' /Filter /ASCIIHexDecode', rgb.hex().encode()+b'>'),
        ('ascii85', image+' /Filter /ASCII85Decode', base64.a85encode(rgb)+b'~>'),
        ('runlength', image+' /Filter /RunLengthDecode', bytes([len(rgb)-1])+rgb+b'\x80'),
        ('filter-chain', image+' /Filter [/ASCIIHexDecode /FlateDecode]', zlib.compress(rgb).hex().encode()+b'>'),
        ('predictor', image+' /Filter /FlateDecode /DecodeParms << /Predictor 12 /Colors 3 /BitsPerComponent 8 /Columns 2 >>', zlib.compress(b'\x00'+rgb[:6]+b'\x00'+rgb[6:])),
        ('short', image, rgb[:-1]),
        ('long', image, rgb+b'\x00'),
        ('stencil', '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ImageMask true /BitsPerComponent 1', b'\x00\x00'),
        ('jpx', image+' /Filter /JPXDecode', b'unsupported'),
        ('decode', image+' /Decode [1 0 1 0 1 0]', rgb),
        ('matte', image+' /SMask 8 0 R', rgb),
    ]:
        variant = objects.copy(); variant[10] = b'<< /XObject << /Image 7 0 R >> >>'
        variant[3] = b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>'
        variant[2] = b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>'
        variant[6] = stream(dictionary, data)
        if name == 'matte': variant[7] = stream(gray+' /Matte [1 1 1]', alpha)
        pdf(work/(name+'.pdf'), variant)
    (work/'expected-rgba.bin').write_bytes(b''.join(rgb[i*3:i*3+3]+alpha[i:i+1] for i in range(4)))


if __name__ == '__main__':
    generate(Path(sys.argv[1]))
