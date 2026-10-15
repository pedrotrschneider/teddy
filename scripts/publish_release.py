"""Stage all assets in a draft, publish only after upload succeeds."""
import json
import os
import subprocess
from pathlib import Path

tag = os.environ['RELEASE_TAG']
version = os.environ['RELEASE_VERSION']
pre = os.environ['PRERELEASE'] == 'true'
repo = os.environ['GITHUB_REPOSITORY']

def gh(*args):
    return subprocess.check_output(['gh',*args], text=True)

# A completed rerun must never replace already-public release assets.
releases = json.loads(gh('api', f'repos/{repo}/releases', '--paginate', '--slurp'))
release = next((r for page in releases for r in page if r['tag_name']==tag), None)
if release and not release['draft']:
    print(f'{tag} already published; leaving its assets unchanged.')
    raise SystemExit(0)
files = list(Path('dist').iterdir())
if len([p for p in files if p.suffix=='.sha256']) != 5:
    raise SystemExit('Expected checksum manifests for all five platform builds')
notes = (f'Teddy {version}\n\nRequires TED major {version.split(".")[0]} (including major zero). '
         'Minor and patch versions may differ.\n\n'
         'macOS: universal ad-hoc signed ZIP, not notarized. Windows: unsigned portable ZIP. '
         'Linux: x64/ARM64 portable tarballs; run Teddy from the extracted folder. '
         'Android: signed universal APK for phones and Android TV. No iOS build.\n\n'
         'See release setup documentation for runtime prerequisites and signing limitations.')
Path('release-notes.txt').write_text(notes)
if not release:
    gh('release','create',tag,'--verify-tag','--draft','--title',f'Teddy {version}',
       '--notes-file','release-notes.txt', *(['--prerelease'] if pre else []))
gh('release','upload',tag, *[str(p) for p in files], '--clobber')
gh('release','edit',tag,'--draft=false', f'--prerelease={str(pre).lower()}',
   f'--latest={str(not pre and os.environ["PROMOTE"] == "true").lower()}')
