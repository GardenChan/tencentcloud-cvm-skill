#!/bin/bash
# 从 SKILL.md 读取元数据，原子构建发布包；不覆盖旧包，除非显式 --force。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(description='打包 CVM skill（版本由 SKILL.md metadata 决定）')
parser.add_argument('--output', type=Path, help='输出路径，默认仓库内 name-version.zip；相对路径按当前目录解析')
parser.add_argument('--force', action='store_true', help='成功构建后原子替换已有包')
parser.add_argument('--list', action='store_true', help='列出发布内容')
parser.add_argument('--info', action='store_true', help='显示元数据')
args = parser.parse_args(sys.argv[2:])
try:
    text = (root / 'SKILL.md').read_text()
    name = re.search(r'^name:\s*([a-z0-9-]+)\s*$', text, re.M).group(1)
    version = re.search(r'^  version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$', text, re.M).group(1)
    if args.info:
        print(f'Name: {name}\nVersion: {version}')
        sys.exit(0)
    files = []
    for item in ('SKILL.md', 'LICENSE', 'scripts', 'assets', 'references'):
        path = root / item
        if not path.exists():
            raise ValueError(f'缺少发布内容: {item}')
        candidates = path.rglob('*') if path.is_dir() else (path,)
        for candidate in candidates:
            rel = candidate.relative_to(root)
            if any(part.startswith('.') or part == '__pycache__' for part in rel.parts) or candidate.suffix in ('.pyc', '.log'):
                continue
            if candidate.is_symlink():
                raise ValueError(f'发布内容不能为符号链接: {rel}')
            if candidate.is_file():
                files.append(candidate)
    files.sort()
    if args.list:
        print('\n'.join(str(p.relative_to(root)) for p in files))
        sys.exit(0)
    target = (args.output or root / f'{name}-{version}.zip').absolute()
    if target.exists() and not args.force:
        raise ValueError('输出文件已存在；指定其他 --output 或使用 --force')
    if target.is_symlink():
        raise ValueError('拒绝覆盖符号链接')
    fd, temporary = tempfile.mkstemp(prefix='.skill-package-', suffix='.zip', dir=target.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                archive.write(path, f'{name}/{path.relative_to(root)}')
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip():
                raise ValueError('压缩包校验失败')
        if args.force:
            os.replace(temporary, target)
        else:
            # Atomic no-clobber publish, including concurrent packaging attempts.
            os.link(temporary, target)
            os.unlink(temporary)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'已打包: {target} ({len(files)} files)')
except (OSError, ValueError, AttributeError) as exc:
    print(f'打包失败: {exc}', file=sys.stderr)
    sys.exit(1)
PY
