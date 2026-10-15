import struct
import unittest

from godot.tools.ktx_etc1 import (
    GL_ETC1_RGB8_OES,
    KTX1_IDENTIFIER,
    build_ktx1_etc1,
    etc1_mip_sizes,
)


class Etc1KtxTests(unittest.TestCase):
    def test_source_mip_chain_is_preserved(self):
        sizes = etc1_mip_sizes(512, 512, 10)
        self.assertEqual(sum(sizes), 174776)
        source = bytes((i * 17 + 3) & 0xFF for i in range(sum(sizes)))
        ktx = build_ktx1_etc1(source, 512, 512, 10)
        self.assertEqual(ktx[:12], KTX1_IDENTIFIER)
        header = struct.unpack_from("<13I", ktx, 12)
        self.assertEqual(header[4], GL_ETC1_RGB8_OES)
        self.assertEqual(header[6:8], (512, 512))
        self.assertEqual(header[11], 10)
        cursor = 64
        recovered = bytearray()
        for expected in sizes:
            size = struct.unpack_from("<I", ktx, cursor)[0]
            cursor += 4
            self.assertEqual(size, expected)
            recovered += ktx[cursor:cursor + size]
            cursor += size
            cursor = (cursor + 3) & ~3
        self.assertEqual(bytes(recovered), source)

    def test_invalid_payload_and_dimensions_fail_closed(self):
        with self.assertRaises(ValueError):
            etc1_mip_sizes(0, 512, 1)
        with self.assertRaises(ValueError):
            build_ktx1_etc1(b"too short", 512, 512, 10)


if __name__ == "__main__":
    unittest.main()
