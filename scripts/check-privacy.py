#!/usr/bin/env python3
"""Check only publishable files; print categories and locations, never secret values."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
# In a Git checkout inspect the index, including files ignored by mistake but staged.
tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True)
if tracked.returncode == 0:
    paths = [root / name for name in tracked.stdout.decode().split('\0') if name]
else:
    paths = [p for p in root.rglob('*') if p.is_file() and not any(part in {
        '.git', 'node_modules', 'build', '.build', '.swiftpm', 'DerivedData',
        'test-results', 'playwright-report', 'xcuserdata'
    } for part in p.relative_to(root).parts) and not p.name.endswith('.local.xcconfig')]
patterns = {
    'home directory path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'Google API credential': re.compile(r'AI' + r'za[0-9A-Za-z_-]{30,}'),
    'GitHub credential': re.compile(r'(?:gh' + r'[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'API credential': re.compile(r'sk-' + r'(?:proj-)?[A-Za-z0-9_-]{24,}'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'physical device identifier': re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b'),
    'personal signing team': re.compile(r'DEVELOPMENT_TEAM\s*=\s*["\']?[A-Z0-9]{10}\b'),
    'email address': re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
}
forbidden_suffixes = {'.p12', '.p8', '.pem', '.key', '.cer', '.mobileprovision', '.provisionprofile', '.ipa', '.heic'}
issues = []
for path in paths:
    name = path.relative_to(root).as_posix()
    if path.suffix.lower() in forbidden_suffixes or '.env' == path.name or '.env.' in path.name or path.name.endswith('.local.xcconfig') or 'xcuserdata' in path.parts:
        issues.append((name, 'private/generated file', 0))
    if not path.exists(): continue
    text = path.read_bytes().decode('utf-8', errors='replace')
    for label, pattern in patterns.items():
        for match in pattern.finditer(text):
            issues.append((name, label, text.count('\n', 0, match.start()) + 1))
for name, label, line in issues:
    print(f'{name}:{line}: {label}')
print(f'Privacy scan: {len(paths)} files, {len(issues)} findings.')
sys.exit(1 if issues else 0)
