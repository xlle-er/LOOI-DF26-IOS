#!/usr/bin/env python3
"""Verify translation coverage and format placeholders without building the app."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
resources = root / 'Native/Sources/LooiNative/Resources'
def read(path):
    pairs = re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', path.read_text())
    result = {json.loads(key): json.loads(value) for key, value in pairs}
    assert len(result) == len(pairs), f'Duplicate keys in {path.name}'
    return result
zh = read(resources / 'zh-Hans.lproj/Localizable.strings')
en = read(resources / 'en.lproj/Localizable.strings')
assert zh.keys() == en.keys(), 'Language catalogs must contain the same keys'
for key in zh:
    assert zh[key] == key and en[key].strip(), 'Missing translation'
    assert key.count('%@') == en[key].count('%@'), f'Placeholder mismatch: {key}'
for path in (root / 'Native/Sources/LooiNative').glob('*.swift'):
    for key in re.findall(r'\bL\(("(?:\\.|[^"\\])*")', path.read_text()):
        value = json.loads(key)
        assert value in en, f'Missing UI translation in {path.name}: {value}'
for language in ['en', 'zh-Hans']:
    permissions = read(root / 'App' / (language + '.lproj') / 'InfoPlist.strings')
    assert all(permissions.get(key) for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSBluetoothAlwaysUsageDescription', 'NSLocalNetworkUsageDescription'])
print(f'Localization coverage passed: {len(en)} keys, 2 languages, 4 permission descriptions per language.')
