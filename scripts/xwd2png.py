#!/usr/bin/env python3
"""Minimal XWD (X Window Dump, ZPixmap) -> PNG converter.

Only used to grab a screenshot of the DCV desktop on this box, where neither
ImageMagick nor PIL is available.  Handles the 24/32-bpp TrueColor case that
Xdcv produces and falls back to the standard BGRA byte order otherwise.
"""
import struct
import sys
import zlib


def read_xwd(path):
    with open(path, "rb") as fh:
        raw = fh.read()

    # XWD v7 header: 25 big-endian CARD32 fields
    fields = struct.unpack(">25I", raw[:100])
    (header_size, file_version, pixmap_format, depth, width, height, xoffset,
     byte_order, bitmap_unit, bitmap_bit_order, bitmap_pad, bits_per_pixel,
     bytes_per_line, visual_class, red_mask, green_mask, blue_mask,
     bits_per_rgb, colormap_entries, ncolors, *_win) = fields

    if file_version != 7 or pixmap_format != 2:
        raise SystemExit(f"unsupported XWD: version={file_version} format={pixmap_format}")
    if bits_per_pixel not in (24, 32):
        raise SystemExit(f"unsupported bits_per_pixel={bits_per_pixel}")

    off = header_size + (ncolors * 12 if ncolors else 0)
    data = raw[off:off + bytes_per_line * height]

    # mask -> shift, so any channel layout maps to RGB
    def shift_of(mask):
        return (mask & -mask).bit_length() - 1 if mask else 0

    sr, sg, sb = shift_of(red_mask), shift_of(green_mask), shift_of(blue_mask)
    bpp = bits_per_pixel // 8
    little = (byte_order == 0)  # 0 = LSBFirst

    out = bytearray()
    for y in range(height):
        row = data[y * bytes_per_line:(y + 1) * bytes_per_line]
        out.append(0)  # PNG filter: none
        for x in range(width):
            px = int.from_bytes(row[x * bpp:(x + 1) * bpp], "little" if little else "big")
            out += bytes(((px & red_mask) >> sr, (px & green_mask) >> sg, (px & blue_mask) >> sb))
    return width, height, bytes(out)


def write_png(path, width, height, raw_rgb):
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit truecolour
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", ihdr))
        fh.write(chunk(b"IDAT", zlib.compress(raw_rgb, 6)))
        fh.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    w, h, rgb = read_xwd(src)
    write_png(dst, w, h, rgb)
    print(f"{src} -> {dst} ({w}x{h})")
