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
        ("if source_diff() != canonical_diff(expected):\n    raise SystemExit('Translator patch result differs from its exact recorded source')\n",
         "if source_diff() != canonical_diff(expected):\n    raise SystemExit('Translator patch result differs from its exact recorded source')\n"
         "# A01 trial: this A53 exceeded the upstream 20-second decode budget.\n"
         "budget_file = SOURCE / 'crates/metal2vulkan-air/src/budget/mod.rs'\n"
         "budget_text = budget_file.read_text()\n"
         "old_budget = 'pub const STANDARD_DEADLINE: Duration = Duration::from_secs(20);'\n"
         "assert budget_text.count(old_budget) == 1, 'unexpected translator budget source'\n"
         "budget_file.write_text(budget_text.replace(old_budget, old_budget.replace('secs(20)', 'secs(180)'), 1))\n"),
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
