#!/usr/bin/env python3
"""Compile native protocol/buffering tests without signing, API calls or devices."""
from pathlib import Path
import subprocess
import shutil
import os
import plistlib
import tempfile

root = Path(__file__).resolve().parents[1]
sources = ['LooiFirmwareCache', 'LooiSettings', 'LooiBodyProtocol', 'LooiAIRequest', 'LooiPlaybackQueue', 'LooiLiveConfiguration', 'LooiLocalization', 'LooiConversationLanguage']
with tempfile.TemporaryDirectory(prefix='looi-native-tests-') as folder:
    output = Path(folder) / 'native-checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/LooiNative' / (name + '.swift')) for name in sources],
                    str(root / 'Tests/native/main.swift'), '-o', str(output)], check=True)
    bundle = Path(folder) / 'Localization.bundle'
    bundle.mkdir()
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.example.looi.tests', 'CFBundleDevelopmentRegion': 'en'}))
    for language in ['en', 'zh-Hans']:
        shutil.copytree(root / 'Native/Sources/LooiNative/Resources' / (language + '.lproj'), bundle / (language + '.lproj'))
    subprocess.run([str(output)], check=True, env={**os.environ, 'LOOI_TEST_BUNDLE': str(bundle)})

    remote_output = Path(folder) / 'remote-checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/LooiNative' / (name + '.swift')) for name in ['LooiSettings', 'LooiBodyProtocol', 'LooiRemoteControl']],
                    str(root / 'Tests/remote/RemoteTests.swift'), '-o', str(remote_output)], check=True)
    subprocess.run([str(remote_output)], check=True)
