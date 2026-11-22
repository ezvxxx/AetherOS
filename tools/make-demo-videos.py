from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]


def box(kind, payload):
    return struct.pack(">I4s", len(payload) + 8, kind.encode("ascii")) + payload


def fullbox(kind, payload):
    return box(kind, b"\0\0\0\0" + payload)


def mp4_demo():
    jpg = (ROOT / "assets" / "wallpaper.jpg").read_bytes()
    samples = [jpg, jpg, jpg, jpg]
    duration = 300
    ftyp = box("ftyp", b"isom" + struct.pack(">I", 0x200) + b"isommp42")
    mdat = box("mdat", b"".join(samples))
    matrix = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    mvhd = fullbox("mvhd", struct.pack(">IIIIIH", 0, 0, 1000, duration * len(samples), 0x10000, 0x100) +
                   b"\0" * 10 + matrix + b"\0" * 24 + struct.pack(">I", 2))
    tkhd = fullbox("tkhd", struct.pack(">IIIII", 0, 0, 1, 0, duration * len(samples)) +
                   b"\0" * 8 + struct.pack(">hhhh", 0, 0, 0x100, 0) + matrix +
                   struct.pack(">II", 1920 << 16, 1080 << 16))
    mdhd = fullbox("mdhd", struct.pack(">IIIIHH", 0, 0, 1000, duration * len(samples), 0x55c4, 0))
    hdlr = fullbox("hdlr", b"\0" * 4 + b"vide" + b"\0" * 12 + b"Aether MJPEG demo\0")
    vmhd = fullbox("vmhd", b"\0" * 8)
    url = fullbox("url ", b"\x01")
    dref = fullbox("dref", struct.pack(">I", 1) + url)
    dinf = box("dinf", dref)

    visual = (
        b"\0" * 6 + struct.pack(">H", 1) + b"\0" * 16 +
        struct.pack(">HHII", 1920, 1080, 0x00480000, 0x00480000) +
        b"\0" * 4 + struct.pack(">H", 1) + b"\0" * 32 +
        struct.pack(">HH", 0x18, 0xffff)
    )
    jpeg_entry = box("jpeg", visual)
    stsd = fullbox("stsd", struct.pack(">I", 1) + jpeg_entry)
    stts = fullbox("stts", struct.pack(">III", 1, len(samples), duration))
    stsc = fullbox("stsc", struct.pack(">IIII", 1, 1, len(samples), 1))
    stsz = fullbox("stsz", struct.pack(">II", 0, len(samples)) + b"".join(struct.pack(">I", len(s)) for s in samples))

    def build_moov(chunk_offset):
        stco = fullbox("stco", struct.pack(">II", 1, chunk_offset))
        stbl = box("stbl", stsd + stts + stsc + stsz + stco)
        minf = box("minf", vmhd + dinf + stbl)
        mdia = box("mdia", mdhd + hdlr + minf)
        trak = box("trak", tkhd + mdia)
        return box("moov", mvhd + trak)

    moov = build_moov(len(ftyp) + 8)
    (ROOT / "assets" / "sample-mjpeg.mp4").write_bytes(ftyp + mdat + moov)


def vint(value):
    for length in range(1, 9):
        if value < (1 << (7 * length)) - 1:
            return (value | (1 << (7 * length))).to_bytes(length, "big")
    raise ValueError("EBML value too large")


def ebml(identifier, payload):
    return identifier + vint(len(payload)) + payload


def uint(identifier, value):
    size = max(1, (value.bit_length() + 7) // 8)
    return ebml(identifier, value.to_bytes(size, "big"))


def mkv_demo():
    fixture = (ROOT / "third_party" / "vp8" / "fixtures.zig").read_text(encoding="utf-8")
    match = re.search(r"pub const quality_50 = \[_\]u8\{(.*?)\};", fixture, re.S)
    if not match:
        raise RuntimeError("Could not locate the bundled VP8 keyframe")
    frame = bytes(int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{2})", match.group(1)))
    ebml_header = ebml(bytes.fromhex("1a45dfa3"),
        uint(bytes.fromhex("4286"), 1) + uint(bytes.fromhex("42f7"), 1) +
        uint(bytes.fromhex("42f2"), 4) + uint(bytes.fromhex("42f3"), 8) +
        ebml(bytes.fromhex("4282"), b"matroska") + uint(bytes.fromhex("4287"), 4) +
        uint(bytes.fromhex("4285"), 2))
    info = ebml(bytes.fromhex("1549a966"), uint(bytes.fromhex("2ad7b1"), 1_000_000))
    video = ebml(bytes.fromhex("e0"), uint(bytes.fromhex("b0"), 64) + uint(bytes.fromhex("ba"), 48))
    track = ebml(bytes.fromhex("ae"),
        uint(bytes.fromhex("d7"), 1) + uint(bytes.fromhex("73c5"), 1) +
        uint(bytes.fromhex("83"), 1) + ebml(bytes.fromhex("86"), b"V_VP8") + video)
    tracks = ebml(bytes.fromhex("1654ae6b"), track)
    cluster_payload = uint(bytes.fromhex("e7"), 0)
    for time_ms in (0, 250, 500, 750):
        block = b"\x81" + struct.pack(">hB", time_ms, 0x80) + frame
        cluster_payload += ebml(bytes.fromhex("a3"), block)
    cluster = ebml(bytes.fromhex("1f43b675"), cluster_payload)
    segment_id = bytes.fromhex("18538067")
    unknown_size = b"\x01" + b"\xff" * 7
    (ROOT / "assets" / "sample-vp8.mkv").write_bytes(
        ebml_header + segment_id + unknown_size + info + tracks + cluster)


if __name__ == "__main__":
    mp4_demo()
    mkv_demo()
