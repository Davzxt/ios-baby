#!/usr/bin/env python3
"""Adjust a disposable, pinned UniXNU checkout for an iOS 16 build trial.

This changes deployment targets only; it does not establish API compatibility.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1])
changes = {
    'scripts/build-native-metal-bridge.py': [
        ("IPHONEOS_DEPLOYMENT_TARGET='17.0'", "IPHONEOS_DEPLOYMENT_TARGET='16.0'"),
    ],
    'scripts/build-vulkan-metal-plugin.py': [
        ("'arm64-apple-ios17.0'", "'arm64-apple-ios16.0'"),
        ("MinimumOSVersion='17.0'", "MinimumOSVersion='16.0'"),
    ],
}
for name, replacements in changes.items():
    path = root / name
    source = path.read_text(encoding='utf-8')
    for old, new in replacements:
        if source.count(old) != 1:
            raise SystemExit(f'{name}: expected exactly one {old!r}')
        source = source.replace(old, new, 1)
    path.write_text(source, encoding='utf-8', newline='\n')
    print(f'prepared {name} for iOS 16')
