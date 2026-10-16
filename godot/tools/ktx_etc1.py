#!/usr/bin/env python3
"""Wrap source ETC1 mip chains in KTX1 without recompressing them.

Authorized Beta archives often contain Android-ready Unity Texture2D payloads.
When the source texture is already ETC_RGB4, decoding to RGBA and re-encoding is
both slower and destructive. This helper preserves the exact compressed blocks
and their mip order while giving Godot/libktx a standard import container.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

KTX1_IDENTIFIER = b"\xABKTX 11\xBB\r\n\x1A\n"
KTX_ENDIANNESS = 0x04030201
GL_ETC1_RGB8_OES = 0x8D64
GL_RGB = 0x1907


def etc1_mip_sizes(width: int, height: int, mip_count: int) -> list[int]:
    if width <= 0 or height <= 0 or mip_count <= 0:
        raise ValueError("width, height and mip_count must be positive")
    sizes: list[int] = []
    w, h = width, height
    for _ in range(mip_count):
        # ETC1 stores each 4x4 block in eight bytes, with at least one block per mip.
        sizes.append(max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * 8)
        w = max(1, w // 2)
        h = max(1, h // 2)
    return sizes


def build_ktx1_etc1(payload: bytes, width: int, height: int, mip_count: int) -> bytes:
    sizes = etc1_mip_sizes(width, height, mip_count)
    expected = sum(sizes)
    if len(payload) != expected:
        raise ValueError(f"ETC1 payload is {len(payload)} bytes; expected {expected}")
    output = bytearray(KTX1_IDENTIFIER)
    output += struct.pack(
        "<13I",
        KTX_ENDIANNESS,
        0,  # glType: compressed
        1,  # glTypeSize
        0,  # glFormat: compressed
        GL_ETC1_RGB8_OES,
        GL_RGB,
        width,
        height,
        0,  # depth
        0,  # array elements
        1,  # faces
        mip_count,
        0,  # key/value bytes
    )
    cursor = 0
    for size in sizes:
        output += struct.pack("<I", size)
        output += payload[cursor:cursor + size]
        cursor += size
        while len(output) & 3:
            output.append(0)
    return bytes(output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="raw Unity ETC_RGB4 mip chain")
    parser.add_argument("output", type=Path, help="output .ktx path")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--mips", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    result = build_ktx1_etc1(args.input.read_bytes(), args.width, args.height, args.mips)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(result)
    print(f"Wrote {len(result)} bytes to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
