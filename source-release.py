#!/usr/bin/env python3
"""Package maintained source files; omit local state and build output."""
from pathlib import Path
import hashlib
import plistlib
import re
import zipfile

ROOT = Path(__file__).resolve().parent
FILES = ['Package.swift', 'README.md', '.gitignore', '.gitattributes', 'build.sh', 'test.sh', 'source-release.py',
         '.github/RELEASES.md', '.github/release.json',
         '.github/scripts/release.py', '.github/scripts/test_release.py']
TREES = {
    'Sources': {'.swift'}, 'Tests': {'.swift', '.py', '.ps1'},
    'Resources': {'.plist', '.png', '.svg'},
    'Windows': {'.cs', '.csproj', '.props', '.manifest', '.ico', '.ps1', '.md', '.txt', '.png'},
    'docs': {'.md', '.jpg'}, '.github': {'.yml'},
}
EXCLUDE = {'bin', 'obj', '.git', '.build', 'build', '.DS_Store', '__pycache__'}

def source_files(root):
    result = [root / name for name in FILES]
    for name, extensions in TREES.items():
        for path in (root / name).rglob('*'):
            if EXCLUDE.intersection(path.relative_to(root).parts):
                continue
            if path.is_file() and not path.is_symlink() and (path.suffix in extensions or path.name == 'packages.lock.json'):
                result.append(path)
    for path in result:
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Missing or linked source file: {path}')
    return sorted(result)

def package(root=ROOT):
    files = source_files(root)
    included = {path.resolve() for path in files}
    for doc in (p for p in files if p.suffix == '.md'):
        for target in re.findall(r'\]\(([^)]+)\)', doc.read_text()):
            if '://' in target or target.startswith('#'):
                continue
            if (doc.parent / target.split('#')[0]).resolve() not in included:
                raise ValueError(f'Unpackaged documentation link: {doc.name}: {target}')
    version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    output = root / 'build' / f'JustRecorder-{version}-source.zip'
    output.parent.mkdir(exist_ok=True)
    temporary = output.with_suffix('.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in files:
                name = (Path('JustRecorder') / path.relative_to(root)).as_posix()
                info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                info.create_system = 3
                executable = path.name in {'build.sh', 'test.sh', 'source-release.py'}
                info.external_attr = (0o100755 if executable else 0o100644) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes(), compresslevel=9)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError('Archive verification failed')
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output, len(files)

if __name__ == '__main__':
    output, count = package()
    print(f'{output}\n{count} source files\nSHA256 {hashlib.sha256(output.read_bytes()).hexdigest()}')
