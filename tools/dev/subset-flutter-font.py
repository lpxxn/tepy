"""生成离线 UI 字体。依赖 fonttools；源字体来自 google/fonts/ofl/notosanssc。

python subset-flutter-font.py --source NotoSansSC.ttf
保留 GB2312 常用汉字、拉丁字符、标点和应用源码中的字符；罕见字由系统回退。
"""
import argparse
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'apps/mobile-flutter'
chars = set(chr(n) for n in range(0x20, 0x300))
chars.update(chr(n) for n in range(0x2000, 0x2070))
chars.update(chr(n) for n in range(0x3000, 0x3040))
chars.update(chr(n) for n in range(0xFF00, 0xFFEF))
for high in range(0xA1, 0xF8):
    for low in range(0xA1, 0xFF):
        try:
            chars.update(bytes([high, low]).decode('gb2312'))
        except UnicodeDecodeError:
            pass
for path in (app / 'lib').rglob('*.dart'):
    chars.update(path.read_text(encoding='utf-8-sig'))
font = TTFont(args.source)
options = subset.Options()
options.name_IDs = ['*']
options.name_legacy = True
options.name_languages = ['*']
subsetter = subset.Subsetter(options=options)
subsetter.populate(unicodes=[ord(c) for c in chars])
subsetter.subset(font)
# 衍生字体使用自己的名字，保留原始版权和 OFL 许可记录。
for record in font['name'].names:
    if record.nameID in (1, 4, 6, 16):
        record.string = ('TepySans' if record.nameID == 6 else 'Tepy Sans').encode(record.getEncoding())
dest = app / 'assets/fonts/TepySans.ttf'
dest.parent.mkdir(parents=True, exist_ok=True)
font.save(dest)
print(f'{dest}: {dest.stat().st_size} bytes')
