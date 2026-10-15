"""Prepare Gradle signing files without logging secret values."""
import base64
import os
from pathlib import Path


def prop(value):
    return value.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('=', '\\=').replace(':', '\\:').replace(' ', '\\ ')

names = ['KEYSTORE_BASE64', 'KEYSTORE_PASSWORD', 'KEY_ALIAS', 'KEY_PASSWORD']
if any(not os.environ.get(key) for key in names):
    raise SystemExit('Configure all four ANDROID signing secrets documented in release setup before publishing.')
Path('android/app/release.jks').write_bytes(base64.b64decode(os.environ['KEYSTORE_BASE64'], validate=True))
values = dict(storeFile='release.jks', storePassword=os.environ['KEYSTORE_PASSWORD'], keyAlias=os.environ['KEY_ALIAS'], keyPassword=os.environ['KEY_PASSWORD'])
Path('android/key.properties').write_text(''.join(f'{key}={prop(value)}\n' for key,value in values.items()))
