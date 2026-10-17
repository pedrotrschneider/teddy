#!/usr/bin/env python3
"""Regenerate Teddy branding from icon.png (stdlib, sips and Devbox FFmpeg)."""
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = root / 'icon.png'

def png(destination, size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['sips', '-z', str(size), str(size), str(source), '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)

def rectangle(destination, width, height):
    # Keep the full wordmark: resize the square, then crop only its background.
    png(destination, max(width, height))
    subprocess.run(['sips', '-c', str(height), str(width), str(destination), '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)

def transparent(destination, size, color=None):
    filters = ['colorkey=0x14191d:0.02:0.1']
    if color is not None:
        filters.append(f'lutrgb=r={color[0]}:g={color[1]}:b={color[2]}')
    filters.append(f'scale={size}:{size}')
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', str(source), '-vf', ','.join(filters),
                    '-frames:v', '1', '-update', '1', str(destination)], check=True)

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
    drawable = root / f'android/app/src/main/res/drawable-{density}'
    rectangle(drawable / 'tv_banner.png', size * 10 // 3, size * 15 // 8)
    # Android status icons must be a white alpha mask, not an opaque square.
    transparent(drawable / 'ic_stat_notification.png', size // 2, (255,255,255))
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

# Retained Windows tile artwork must agree with the regular executable icon.
for destination in sorted((root / 'windows/msix/assets').glob('*.png')):
    width, height = struct.unpack('>II', destination.read_bytes()[16:24])
    if 'altform-' in destination.name:
        # Unplated taskbar variants retain transparency and light-theme contrast.
        transparent(destination, width, (20,25,29) if 'lightunplated' in destination.name else None)
    else:
        rectangle(destination, width, height)

# iOS uses an Icon Composer resource rather than the Mac's raster catalog.
composer = root / 'ios/Teddy.icon'
(composer / 'Assets').mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, composer / 'Assets/teddy.png')
(composer / 'icon.json').write_text(json.dumps({
    'fill': {'solid': 'gray:0.94630,1.00000'},
    'groups': [{'layers': [{
        'image-name': 'teddy.png', 'name': 'Teddy', 'glass': False, 'hidden': False,
        'position': {'scale': 1, 'translation-in-points': [0, 0]},
    }], 'shadow': {'kind': 'neutral', 'opacity': 0}, 'translucency': {'enabled': False, 'value': 0}}],
    'supported-platforms': {'circles': ['watchOS'], 'squares': 'shared'},
}, indent=2) + '\n')
