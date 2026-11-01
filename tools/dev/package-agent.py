"""整理原生 macOS Agent 发布包，不构建、不读取本地配置。

python tools/dev/package-agent.py --binary apps/macos-agent/build/tepy-agent-darwin-arm64
Mac 可指定 --module-cache "$(go env GOMODCACHE)" --go-license "$(go env GOROOT)/LICENSE"。
打包前应在 Mac 执行 tepy-agent version，确认二进制版本与源码一致。
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--module-cache', type=Path, default=ROOT / '.venv/agent-gopath/pkg/mod')
parser.add_argument('--go-license', type=Path, default=ROOT / '.venv/agent-tools/windows/go/LICENSE')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
app = ROOT / 'apps/macos-agent'
version = re.search(r'var version = "(\d+\.\d+\.\d+)"', (app / 'cmd/tepy-agent/main.go').read_text(encoding='utf-8')).group(1)
with args.binary.open('rb') as binary:
    magic, cpu = struct.unpack('<II', binary.read(8))
if magic != 0xfeedfacf or cpu not in (0x100000c, 0x1000007):
    parser.error('binary 必须为 macOS Mach-O arm64 / amd64，不能使用 Windows 开发产物。')
arch = 'arm64' if cpu == 0x100000c else 'amd64'
destination = args.output or ROOT / f'dist/tepy-macos-agent-{version}-darwin-{arch}'
if destination.exists():
    parser.error('发布目录已经存在，请选择新的 --output，避免混入旧产物。')
if not args.go_license.is_file():
    parser.error('需要 Go SDK 的 LICENSE，请指定 --go-license。')

# 在写发布目录前确认依赖许可齐全。Go 模块缓存中的大写字母需转为 !小写。
modules = re.findall(r'^\s*([A-Za-z0-9_./-]+)\s+(v[^\s)]+)', (app / 'go.mod').read_text(), re.M)
licenses = []
for module, module_version in modules:
    escaped = ''.join('!' + c.lower() if c.isupper() else c for c in module)
    folder = args.module_cache / f'{escaped}@{module_version}'
    if not folder.is_dir():
        parser.error(f'找不到依赖目录：{module}；请核对 --module-cache。')
    files = [p for p in folder.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))]
    if not files:
        parser.error(f'依赖许可缺失：{module}；请核对 --module-cache。')
    licenses.extend((file, Path('licenses') / module / file.name) for file in files)
sources = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '--', 'apps/macos-agent'], text=True, encoding='utf-8').splitlines()
destination.mkdir(parents=True)

def copy(source, relative):
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)

copy(args.binary, 'tepy-agent')
(destination / 'tepy-agent').chmod(0o755)
for name in ['README.md', 'config.example.toml', 'go.mod', 'go.sum']:
    copy(app / name, name)
for source in sources:
    if (ROOT / source).is_file():
        copy(ROOT / source, source)
for source, relative in licenses:
    copy(source, relative)
copy(args.go_license, 'licenses/Go-LICENSE')
for path in (ROOT / 'protocol').rglob('*'):
    if path.is_file():
        copy(path, path.relative_to(ROOT))
for path in (ROOT / 'docs').glob('*.md'):
    # 早期本地文档可能包含独立的恢复值；只清理发布副本，不改工作区原文。
    body = re.sub(r'(?m)^\s*[a-fA-F0-9]{24,128}\s*$', '[本地值未包含在发布包中]', path.read_text(encoding='utf-8'))
    target = destination / 'docs' / path.name
    target.parent.mkdir(exist_ok=True)
    target.write_text(body, encoding='utf-8')
for name in ['agent.ps1', 'package-agent.py']:
    copy(ROOT / 'tools/dev' / name, Path('tools/dev') / name)
(destination / 'INSTALL.txt').write_text(
    f'Tepy macOS Agent {version} / darwin-{arch}\n\n'
    '解压后 chmod +x tepy-agent。首次运行 init，编辑生成的 TOML，再 validate / install。\n'
    '升级使用新程序执行 install，保留已有配置。doctor 主动诊断；diagnostics / events 读取服务。\n'
    '完整说明：docs/macos-agent.md，构建和发布：docs/releases.md。\n'
    '不包含真实配置、密码、Mac 登录输入或本地事件历史。\n', encoding='utf-8')
files = sorted(p for p in destination.rglob('*') if p.is_file())
hashes = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(destination).as_posix()}' for p in files]
(destination / 'SHA256SUMS').write_text('\n'.join(hashes) + '\n', encoding='utf-8')
archive = Path(str(destination) + '.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
    for path in sorted(p for p in destination.rglob('*') if p.is_file()):
        entry = zipfile.ZipInfo.from_file(path, (Path(destination.name) / path.relative_to(destination)).as_posix())
        entry.create_system = 3
        mode = 0o100755 if path == destination / 'tepy-agent' else 0o100644
        entry.external_attr = mode << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        output.writestr(entry, path.read_bytes())
print(f'Packaged {version} darwin-{arch}: {archive}')
