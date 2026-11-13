"""Rewrite a dataset's chunk positions so its chunks land in many regions, a few per region.

A real world's chunks sit in a handful of regions, which never exercises the open-region limit.
"""
import struct
import sys


def main():
    source, target, per_region = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(source, "rb") as file:
        data = file.read()
    magic, count = struct.unpack_from("<4sI", data, 0)
    assert magic == b"ZGDS", "not a dataset"
    out = bytearray(data[:8])
    at = 8
    for index in range(count):
        _, _, records = struct.unpack_from("<iiH", data, at)
        start = at
        at += 10
        for _ in range(records):
            at += 6 + struct.unpack_from("<BbI", data, at)[2]
        region, local = divmod(index, per_region)
        out += struct.pack("<iiH", (region % 64) * 32 + local % 32, (region // 64) * 32 + local // 32, records)
        out += data[start + 10:at]
    with open(target, "wb") as file:
        file.write(out)
    print(f"{count} chunks over {-(-count // per_region)} regions")


if __name__ == "__main__":
    main()
