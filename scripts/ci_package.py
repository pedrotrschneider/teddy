"""Build Teddy's entry point and package complete native runtime bundles."""
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

platform = os.environ['TARGET_PLATFORM']
arch = os.environ['TARGET_ARCH']
version = os.environ['RELEASE_VERSION']
core = os.environ['BUILD_CORE']
number = os.environ['BUILD_NUMBER']
dist = Path('dist')
dist.mkdir(exist_ok=True)
name = f'Teddy-{version}-{platform}-{arch}'
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('Flutter missing')
args = [flutter, 'build', 'apk' if platform == 'android' else platform,
        '--release', '--no-pub', '--target', 'lib/teddy_main.dart',
        '--build-name', core, '--build-number', number,
        '--dart-define=ENABLE_UPDATE_CHECK=false', '--dart-define=ENABLE_SENTRY=false',
        f'--dart-define=TEDDY_RELEASE_VERSION={version}',
        f'--dart-define=TEDDY_COMPATIBILITY_VERSION={".".join(core.split(".")[:2]) if core.startswith("0.") else core.split(".")[0]}',
        f'--dart-define=TEDDY_COMPATIBILITY_MAJOR={core.split(".")[0]}']
if platform == 'linux':
    args += ['--target-platform', f'linux-{arch}']
if platform == 'android':
    # One APK covers phones and TV: the manifest declares Leanback optional.
    args += ['--target-platform', 'android-arm,android-arm64,android-x64']
subprocess.run(args, check=True)
def stamp_bundle(bundle):
    # The updater must never replace a general-purpose folder containing user files.
    entries = sorted({p.name for p in bundle.iterdir()} | {'teddy-release.json'})
    (bundle/'teddy-release.json').write_text(json.dumps({'product':'Teddy','version':version,'entries':entries}))

if platform == 'macos':
    app = Path('build/macos/Build/Products/Release/Teddy.app')
    shutil.copy('LICENSE', app/'Contents/Resources/LICENSE.txt')
    shutil.copytree('third_party', app/'Contents/Resources/third_party', dirs_exist_ok=True)
    subprocess.run(['codesign','--force','--sign','-', '--preserve-metadata=entitlements,requirements,flags', str(app)], check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)], check=True)
    arches = subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/Teddy')], text=True)
    if not all(a in arches.split() for a in ('arm64','x86_64')):
        raise SystemExit('Expected universal macOS executable')
    subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(dist/f'{name}.zip')], check=True)
elif platform == 'windows':
    bundle = Path('build/windows/x64/runner/Release')
    # Keep bundled DLLs and data, not just the executable.
    (bundle/'plezy.exe').rename(bundle/'Teddy.exe')
    shutil.copy('LICENSE', bundle/'LICENSE.txt')
    shutil.copytree('third_party', bundle/'third_party', dirs_exist_ok=True)
    stamp_bundle(bundle)
    shutil.make_archive(str(dist/name), 'zip', bundle)
elif platform == 'linux':
    bundle = Path(f'build/linux/{arch}/release/bundle')
    for pattern in ('libmpv.so*','libshaderc_shared.so*'):
        libs = list(Path('libmpv-prefix').rglob(pattern))
        if not libs:
            raise SystemExit(f'Pinned native library missing: {pattern}')
        for lib in libs:
            shutil.copy2(lib, bundle/'lib'/lib.name)
    subprocess.run(['bash','linux/packaging/bundle-libs.sh',str(bundle)], check=True)
    shutil.copy2('linux/packaging/plezy.sh', bundle/'Teddy')
    (bundle/'Teddy').chmod(0o755)
    shutil.copy('LICENSE', bundle/'LICENSE')
    shutil.copytree('third_party', bundle/'third_party', dirs_exist_ok=True)
    # Detect unresolved linked dependencies rather than publishing a broken bundle.
    env = dict(os.environ, LD_LIBRARY_PATH=str((bundle/'lib').resolve()))
    deps = subprocess.check_output(['ldd',str(bundle/'plezy')], env=env, text=True)
    if 'not found' in deps:
        raise SystemExit(deps)
    stamp_bundle(bundle)
    with tarfile.open(dist/f'{name}.tar.gz', 'w:gz') as archive:
        archive.add(bundle, arcname='Teddy')
elif platform == 'android':
    apks = list(Path('build/app/outputs/flutter-apk').glob('*release.apk'))
    if len(apks) != 1:
        raise SystemExit(f'Expected one universal APK, got {len(apks)}')
    shutil.copy2(apks[0], dist/f'{name}.apk')
else:
    raise SystemExit('Unsupported target')
# Unique checksum files avoid collisions when matrix artifacts are merged.
with (dist/f'{name}.sha256').open('w') as checksums:
    for path in sorted(dist.iterdir()):
        if path.suffix != '.sha256':
            checksums.write(f'{hashlib.file_digest(path.open("rb"), "sha256").hexdigest()}  {path.name}\n')
