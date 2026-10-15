#!/usr/bin/env python3
"""Compile native protocol/buffering tests without signing, API calls or devices."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = ['LooiSettings', 'LooiBodyProtocol', 'LooiAIRequest', 'LooiPlaybackQueue', 'LooiLiveConfiguration']
with tempfile.TemporaryDirectory(prefix='looi-native-tests-') as folder:
    output = Path(folder) / 'native-checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/LooiNative' / (name + '.swift')) for name in sources],
                    str(root / 'Tests/native/main.swift'), '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True)
