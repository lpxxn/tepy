"""从 Android 相同的 T 字标几何形状生成 Windows ICO，无第三方依赖。"""
from pathlib import Path
import struct
import zlib


def png(size):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            rgba = [0, 0, 0, 0]
            for sy in range(4):
                for sx in range(4):
                    px = (x + (sx + .5) / 4) * 108 / size
                    py = (y + (sy + .5) / 4) * 108 / size
                    dx = max(27 - px, 0, px - 81)
                    dy = max(27 - py, 0, py - 81)
                    if dx * dx + dy * dy > 27 * 27:
                        continue
                    color = (255, 255, 255) if (28 <= px < 80 and 28 <= py < 42) or (47 <= px < 61 and 42 <= py < 82) else (83, 100, 244)
                    for i in range(3):
                        rgba[i] += color[i]
                    rgba[3] += 255
            count = rgba[3] / 255
            rows.extend([round(n / count) if count else 0 for n in rgba[:3]])
            rows.append(round(rgba[3] / 16))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')


sizes = [16, 24, 32, 48, 64, 128, 256]
images = [png(size) for size in sizes]
offset = 6 + 16 * len(sizes)
header = struct.pack('<HHH', 0, 1, len(sizes))
for size, image in zip(sizes, images):
    header += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(image), offset)
    offset += len(image)
target = Path(__file__).resolve().parents[2] / 'apps/mobile-flutter/windows/runner/resources/app_icon.ico'
target.write_bytes(header + b''.join(images))
print(target)
