#!/usr/bin/env python3
"""Sinh ảnh minh hoạ cho catalog sản phẩm.

Ràng buộc #4 đo p95 của toàn bộ trang, mà trang bán hàng B2B thật thì có ảnh
sản phẩm. Ảnh là nội dung tĩnh, không đổi giữa các request, nên nó thuộc về
S3 + CloudFront chứ không nên đi qua Web tier — đó là phần muốn chứng minh.

Ảnh sinh xác định theo SKU (cùng SKU luôn ra cùng ảnh), nên chạy lại nhiều
lần không tạo ra diff giả trong git và không làm hỏng ETag đã cache.

Viết PNG bằng zlib thuần, không cần Pillow hay ImageMagick.

    python3 scripts/gen-product-images.py
    python3 scripts/gen-product-images.py --width 800 --height 600
"""
from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import zlib

PRODUCT_LINES = [
    ("BRG", "Vong bi cong nghiep"),
    ("MTR", "Dong co dien 3 pha"),
    ("VLV", "Van cong nghiep"),
    ("PMP", "Bom ly tam"),
    ("GBX", "Hop giam toc"),
    ("BLT", "Day dai truyen dong"),
    ("SNS", "Cam bien ap suat"),
    ("PLC", "Bo dieu khien PLC"),
]
VARIANTS = 6

# Bảng chữ 5x7 chấm, đủ để in mã SKU lên ảnh. Chỉ cần chữ hoa, số và dấu gạch.
GLYPHS = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
}


def palette(sku: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Hai màu nền, suy ra từ SKU nên cùng SKU luôn ra cùng ảnh."""
    digest = hashlib.sha256(sku.encode()).digest()
    top = (60 + digest[0] % 90, 70 + digest[1] % 90, 90 + digest[2] % 90)
    bottom = (max(0, top[0] - 45), max(0, top[1] - 45), max(0, top[2] - 45))
    return top, bottom


def draw(sku: str, width: int, height: int) -> bytearray:
    top, bottom = palette(sku)
    digest = hashlib.sha256(sku.encode()).digest()
    band = 30 + digest[3] % 60          # độ dốc dải chéo
    step = 24 + digest[4] % 24          # bước lưới

    rows = bytearray()
    for y in range(height):
        rows.append(0)                  # filter byte: None
        ratio = y / max(1, height - 1)
        base = [round(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)]
        for x in range(width):
            r, g, b = base
            if (x + y * 2) % band < band // 3:            # dải chéo
                r, g, b = min(255, r + 26), min(255, g + 26), min(255, b + 26)
            if x % step < 2 or y % step < 2:              # lưới mờ
                r, g, b = max(0, r - 18), max(0, g - 18), max(0, b - 18)
            rows += bytes((r, g, b))
    stamp(rows, sku, width, height)
    return rows


def stamp(rows: bytearray, sku: str, width: int, height: int) -> None:
    """In mã SKU lên ảnh bằng bảng chữ chấm."""
    scale = max(2, width // 90)
    text_w = len(sku) * 6 * scale
    ox, oy = (width - text_w) // 2, height // 2 - 4 * scale

    for index, char in enumerate(sku.upper()):
        glyph = GLYPHS.get(char)
        if glyph is None:
            continue
        for gy, line in enumerate(glyph):
            for gx, bit in enumerate(line):
                if bit != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        px = ox + (index * 6 + gx) * scale + dx
                        py = oy + gy * scale + dy
                        if 0 <= px < width and 0 <= py < height:
                            at = py * (width * 3 + 1) + 1 + px * 3
                            rows[at:at + 3] = b"\xf2\xf4\xf7"


def chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


def encode_png(rows: bytes, width: int, height: int) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, default=480)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(root, "app", "web", "static", "products")
    os.makedirs(out, exist_ok=True)

    total = 0
    for prefix, _label in PRODUCT_LINES:
        for variant in range(1, VARIANTS + 1):
            sku = f"{prefix}-{variant:03d}"
            png = encode_png(draw(sku, args.width, args.height), args.width, args.height)
            with open(os.path.join(out, f"{sku}.png"), "wb") as fh:
                fh.write(png)
            total += len(png)

    count = len(PRODUCT_LINES) * VARIANTS
    print(f"da sinh {count} anh {args.width}x{args.height} vao {os.path.relpath(out, root)}")
    print(f"tong {total / 1024:.0f} KB, trung binh {total / count / 1024:.1f} KB moi anh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
