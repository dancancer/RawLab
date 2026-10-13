"""Regenerate synthetic 16-bit LinearRaw DNG fixtures; requires cjxl only."""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def write_dng(path, pixels, compression, opcodes=None, stage1=None, active_area=None,
              default_crop=None, black_levels=None, white_levels=(65535, 65535, 65535),
              stage3=None, lens_metadata=False):
    width, height = 32, 24
    matrix = (32406, 10000, -15372, 10000, -4986, 10000,
              -9689, 10000, 18758, 10000, 415, 10000,
              557, 10000, -2040, 10000, 10570, 10000)
    tags = {
        254: (4, 1, struct.pack("<I", 0)),
        256: (4, 1, struct.pack("<I", width)),
        257: (4, 1, struct.pack("<I", height)),
        258: (3, 3, struct.pack("<3H", 16, 16, 16)),
        259: (3, 1, struct.pack("<H", compression)),
        262: (3, 1, struct.pack("<H", 34892)),
        271: (2, 7, b"RawLab\0"),
        272: (2, 10, b"Synthetic\0"),
        273: (4, 1, b"\0" * 4),
        274: (3, 1, struct.pack("<H", 6)),
        277: (3, 1, struct.pack("<H", 3)),
        278: (4, 1, struct.pack("<I", height)),
        279: (4, 1, struct.pack("<I", len(pixels))),
        284: (3, 1, struct.pack("<H", 1)),
        50706: (1, 4, bytes((1, 7, 0, 0))),
        50707: (1, 4, bytes((1, 7, 0, 0))),
        50708: (2, 24, b"RawLab synthetic linear\0"),
        50717: (4, 3, struct.pack("<3I", *white_levels)),
        50721: (10, 9, struct.pack("<18i", *matrix)),
        50728: (5, 3, struct.pack("<6I", 1, 1, 1, 1, 1, 1)),
        50778: (3, 1, struct.pack("<H", 21)),
        50829: (4, 4, struct.pack("<4I", *(active_area or (0, 0, height, width)))),
    }
    if stage1:
        tags[51008] = (7, len(stage1), stage1)
    if black_levels:
        tags[50713] = (3, 2, struct.pack("<2H", 1, 1))
        tags[50714] = (5, 3, struct.pack("<6I", *(part for value in black_levels for part in (value, 1))))
    if default_crop:
        tags[50719] = (4, 2, struct.pack("<2I", *default_crop[:2]))
        tags[50720] = (4, 2, struct.pack("<2I", *default_crop[2:]))
    if opcodes:
        tags[51009] = (7, len(opcodes), opcodes)
    if stage3:
        tags[51022] = (7, len(stage3), stage3)
    if lens_metadata:
        model = b"Test Camera\0"
        tags[272] = (2, len(model), model)
        tags[34665] = (4, 1, b"\0" * 4)
    data_start = 8 + 2 + 12 * len(tags) + 4
    exif = bytearray()
    if lens_metadata:
        lens = b"Test 24mm f/2.8\0"
        exif_tags = {
            33437: (5, 1, struct.pack("<2I", 28, 10)),
            37386: (5, 1, struct.pack("<2I", 24, 1)),
            41989: (3, 1, struct.pack("<H", 24)),
            42035: (2, 7, b"RawLab\0"),
            42036: (2, len(lens), lens),
        }
        exif_offset = data_start + sum(len(value) + len(value) % 2
                                       for _, _, value in tags.values() if len(value) > 4)
        tags[34665] = (4, 1, struct.pack("<I", exif_offset))
        exif_data_start = exif_offset + 2 + 12 * len(exif_tags) + 4
        exif_extra = bytearray()
        exif_entries = bytearray()
        for tag, (kind, count, value) in sorted(exif_tags.items()):
            if len(value) > 4:
                location = struct.pack("<I", exif_data_start + len(exif_extra))
                exif_extra.extend(value)
                if len(exif_extra) % 2:
                    exif_extra.append(0)
            else:
                location = value.ljust(4, b"\0")
            exif_entries.extend(struct.pack("<HHI", tag, kind, count) + location)
        exif = struct.pack("<H", len(exif_tags)) + exif_entries + b"\0" * 4 + exif_extra
    extra = bytearray()
    entries = bytearray()
    pixel_offset = data_start + sum(len(value) + len(value) % 2
                                    for _, _, value in tags.values() if len(value) > 4) + len(exif)
    tags[273] = (4, 1, struct.pack("<I", pixel_offset))
    for tag, (kind, count, value) in sorted(tags.items()):
        if len(value) > 4:
            location = struct.pack("<I", data_start + len(extra))
            extra.extend(value)
            if len(extra) % 2:
                extra.append(0)
        else:
            location = value.ljust(4, b"\0")
        entries.extend(struct.pack("<HHI", tag, kind, count) + location)
    path.write_bytes(b"II\x2a\0" + struct.pack("<I", 8) + struct.pack("<H", len(tags)) +
                     entries + b"\0" * 4 + extra + exif + pixels)


def main():
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    samples = [value for y in range(24) for x in range(32)
               for value in (2048 + x * 700, 4096 + y * 800, 8192 + (x + y) * 300)]
    black, white = (1024, 2048, 4096), (32767, 49151, 65535)
    with tempfile.TemporaryDirectory() as temporary:
        ppm, jxl = Path(temporary) / "pixels.ppm", Path(temporary) / "pixels.jxl"
        ppm.write_bytes(b"P6\n32 24\n65535\n" + struct.pack(f">{len(samples)}H", *samples))
        subprocess.run(["cjxl", str(ppm), str(jxl), "-d", "0", "-e", "1", "--container=1"], check=True)
        write_dng(output / "linear-jxl.dng", jxl.read_bytes(), 52546)
        write_dng(output / "linear-jxl-channel-levels.dng", jxl.read_bytes(), 52546,
                  black_levels=black, white_levels=white)
        write_dng(output / "linear-jxl-lens.dng", jxl.read_bytes(), 52546, lens_metadata=True)
        # Required Stage3 WarpRectilinear uses the SDK's serialized opcode format.
        warp = struct.pack(">I8d", 1, 1, -0.08, 0, 0, 0, 0, 0.5, 0.5)
        stage3 = struct.pack(">5I", 1, 1, 0x01030000, 0, len(warp)) + warp
        write_dng(output / "linear-jxl-stage3-lens.dng", jxl.read_bytes(), 52546,
                  stage3=stage3, lens_metadata=True)
        area = struct.pack(">8I", 0, 0, 24, 32, 0, 3, 1, 1)
        gain = struct.pack(">2I4dI12f", 2, 2, 1, 1, 0, 0, 3, *([2.0] * 12))
        payload = area + gain
        opcodes = struct.pack(">5I", 1, 9, 0x01030000, 0, len(payload)) + payload
        write_dng(output / "linear-jxl-gain.dng", jxl.read_bytes(), 52546, opcodes)
        write_dng(output / "linear-jxl-crop-gain.dng", jxl.read_bytes(), 52546,
                  opcodes, active_area=(1, 1, 23, 31))
        write_dng(output / "linear-jxl-default-crop-gain.dng", jxl.read_bytes(), 52546,
                  opcodes, active_area=(1, 1, 23, 31), default_crop=(1, 1, 28, 20))
        table = struct.pack(">I65536H", 65536, *(value // 2 for value in range(65536)))
        payload = area + table
        stage1 = struct.pack(">5I", 1, 7, 0x01030000, 0, len(payload)) + payload
        write_dng(output / "linear-jxl-stage1.dng", jxl.read_bytes(), 52546, stage1=stage1)
        unknown = struct.pack(">5I", 1, 0xFFFFFFFF, 0x01030000, 0, 0)
        write_dng(output / "linear-jxl-required-unknown.dng", jxl.read_bytes(), 52546, stage1=unknown)
    write_dng(output / "linear-uncompressed.dng", struct.pack(f"<{len(samples)}H", *samples), 1)
    write_dng(output / "linear-lens.dng", struct.pack(f"<{len(samples)}H", *samples), 1,
              lens_metadata=True)
    write_dng(output / "linear-channel-levels.dng", struct.pack(f"<{len(samples)}H", *samples), 1,
              black_levels=black, white_levels=white)
    normalized = [((value - black[c]) * 65535 + (white[c] - black[c]) // 2) // (white[c] - black[c])
                  for i, value in enumerate(samples) for c in (i % 3,)]
    write_dng(output / "linear-normalized.dng", struct.pack(f"<{len(samples)}H", *normalized), 1)
    write_dng(output / "linear-doubled.dng", struct.pack(f"<{len(samples)}H", *(value * 2 for value in samples)), 1)
    write_dng(output / "linear-halved.dng", struct.pack(f"<{len(samples)}H", *(value // 2 for value in samples)), 1)
    write_dng(output / "linear-crop-doubled.dng",
              struct.pack(f"<{len(samples)}H", *(value * 2 for value in samples)), 1,
              active_area=(1, 1, 23, 31))
    write_dng(output / "linear-default-crop-doubled.dng",
              struct.pack(f"<{len(samples)}H", *(value * 2 for value in samples)), 1,
              active_area=(1, 1, 23, 31), default_crop=(1, 1, 28, 20))


if __name__ == "__main__":
    main()
