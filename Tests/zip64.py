#!/usr/bin/env python3
"""ZIP64 flag normalization at real 64-bit offsets, using sparse test files."""
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
NAME = "中文.txt".encode()
PAYLOAD = b"zip64 payload"
CRC = zlib.crc32(PAYLOAD)


def fixture(path, local_offset, size64):
    extra_local = struct.pack("<HHQQ", 1, 16, len(PAYLOAD), len(PAYLOAD)) if size64 else b""
    size_field = 0xFFFFFFFF if size64 else len(PAYLOAD)
    with path.open("wb") as f:
        f.seek(local_offset)
        f.write(struct.pack("<4s5H3I2H", b"PK\x03\x04", 45, 0, 0, 0, 0, CRC, size_field, size_field, len(NAME), len(extra_local)))
        f.write(NAME + extra_local + PAYLOAD)
        central_offset = f.tell()
        offset_field = 0xFFFFFFFF if local_offset > 0xFFFFFFFF else local_offset
        extra_values = ([] if not size64 else [len(PAYLOAD), len(PAYLOAD)]) + ([local_offset] if offset_field == 0xFFFFFFFF else [])
        extra = struct.pack("<HH", 1, len(extra_values) * 8) + b"".join(struct.pack("<Q", v) for v in extra_values) if extra_values else b""
        f.write(struct.pack("<4s6H3I5H2I", b"PK\x01\x02", (3 << 8) | 45, 45, 0, 0, 0, 0, CRC, size_field, size_field, len(NAME), len(extra), 0, 0, 0, 0o100644 << 16, offset_field))
        f.write(NAME + extra)
        central_size = f.tell() - central_offset
        record_offset = f.tell()
        f.write(struct.pack("<4sQ2H2I4Q", b"PK\x06\x06", 44, 45, 45, 0, 0, 1, 1, central_size, central_offset))
        f.write(struct.pack("<4sIQI", b"PK\x06\x07", 0, record_offset, 1))
        f.write(struct.pack("<4s4H2IH", b"PK\x05\x06", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0))


with tempfile.TemporaryDirectory(prefix="clearzip-zip64-") as tmp:
    for label, offset, size64 in [("end-record", 0, False), ("offset64", 2**32 + 16, False), ("sizes-and-offset64", 2**32 + 16, True)]:
        path = Path(tmp) / (label + ".zip")
        fixture(path, offset, size64)
        subprocess.run([str(ROOT / "build/cancellation-tests"), "--mark-utf8", str(path)], check=True)
        with zipfile.ZipFile(path) as z:
            assert z.namelist() == [NAME.decode()], z.namelist()
            assert z.read(NAME.decode()) == PAYLOAD
            assert z.getinfo(NAME.decode()).flag_bits & 0x800
        with path.open("rb") as f:
            f.seek(offset + 6)
            assert struct.unpack("<H", f.read(2))[0] & 0x800
        print("PASS ZIP64:", label)
