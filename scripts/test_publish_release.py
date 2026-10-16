"""Publication cannot create a public release before all uploads succeed."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class PublishTests(unittest.TestCase):
    def publish(self, fail_upload=False):
        script = Path(__file__).with_name('publish_release.py').resolve()
        calls = []
        def gh(args, **kwargs):
            calls.append(args)
            if args[1] == 'api':
                return json.dumps([])
            if fail_upload and args[1:3] == ['release', 'upload']:
                raise subprocess.CalledProcessError(1, args)
            return ''
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            try:
                os.chdir(directory)
                Path('dist').mkdir()
                for platform in range(5):
                    Path(f'dist/platform{platform}.sha256').write_text('fixture')
                with patch.dict(os.environ, RELEASE_TAG='v0.1.0', RELEASE_VERSION='0.1.0',
                                PRERELEASE='false', PROMOTE='true', GITHUB_SHA='build-sha',
                                GITHUB_REPOSITORY='owner/teddy'), patch('subprocess.check_output', side_effect=gh):
                    if fail_upload:
                        with self.assertRaises(subprocess.CalledProcessError):
                            runpy.run_path(str(script), run_name='__main__')
                    else:
                        runpy.run_path(str(script), run_name='__main__')
            finally:
                os.chdir(previous)
        return calls

    def test_upload_failure_does_not_publish(self):
        calls = self.publish(fail_upload=True)
        self.assertFalse(any('--draft=false' in call for call in calls))
        create = next(call for call in calls if call[1:3] == ['release', 'create'])
        self.assertIn('--draft', create)
        self.assertEqual(create[create.index('--target') + 1], 'build-sha')

    def test_publication_is_last_after_upload(self):
        calls = self.publish()
        self.assertIn('--draft=false', calls[-1])
        self.assertEqual(calls[-2][1:3], ['release', 'upload'])


if __name__ == '__main__':
    unittest.main()
