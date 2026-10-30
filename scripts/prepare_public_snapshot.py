#!/usr/bin/env python3
"""Stage a public source snapshot, excluding personal device data and local history."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
destination = root / 'build' / 'PublicRelease'
if destination.exists():
    raise SystemExit('build/PublicRelease already exists; inspect it before preparing another snapshot')
destination.mkdir(parents=True)
for name in ('PaiDian', 'PaiDianTests', 'PaiDianUITests', 'scripts', 'resources'):
    shutil.copytree(root / name, destination / name,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
project = destination / 'PaiDian.xcodeproj'
project.mkdir()
shutil.copy2(root / 'PaiDian.xcodeproj/project.pbxproj', project / 'project.pbxproj')
shutil.copytree(root / 'PaiDian.xcodeproj/xcshareddata', project / 'xcshareddata')
for name in ('README.md', 'LICENSE', 'NOTICE.md', '.gitignore'):
    shutil.copy2(root / name, destination / name)
docs = destination / 'docs'
docs.mkdir()
for name in ('BUILDING.md', 'SOURCES.md'):
    shutil.copy2(root / 'docs' / name, docs / name)
for name in ('licenses', 'screenshots'):
    shutil.copytree(root / 'docs' / name, docs / name)
print(destination)
