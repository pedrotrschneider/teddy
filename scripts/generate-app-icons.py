#!/usr/bin/env python3
"""Regenerate native raster icons from icon.png on macOS (Python stdlib + sips)."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = root / 'icon.png'

def png(destination, size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['sips', '-z', str(size), str(size), str(source), '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)

catalog = root / 'macos/Assets.xcassets'
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f'icon_{size}@{scale}x.png'
        png(catalog / 'AppIcon.appiconset' / name, size * scale)
        images.append(dict(filename=name, idiom='mac', scale=f'{scale}x', size=f'{size}x{size}'))
(catalog / 'AppIcon.appiconset/Contents.json').write_text(json.dumps(dict(images=images, info=dict(author='xcode', version=1)), indent=2) + '\n')
(catalog / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    png(root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)
    png(root / f'android/app/src/main/res/drawable-{density}/teddy_icon.png', size)
with tempfile.TemporaryDirectory(prefix='teddy-icons-') as temporary:
    frames = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        path = Path(temporary) / f'{size}.png'
        png(path, size)
        frames.append((size, path.read_bytes()))
    offset = 6 + 16 * len(frames)
    directory = b''
    body = b''
    for size, data in frames:
        directory += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        body += data
        offset += len(data)
    (root / 'windows/runner/resources/app_icon.ico').write_bytes(struct.pack('<HHH', 0, 1, len(frames)) + directory + body)
