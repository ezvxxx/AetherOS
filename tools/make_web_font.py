#!/usr/bin/env python3
"""Build the browser's small Noto fallback atlas with Pillow and FreeType."""
import argparse
import struct
import unicodedata
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT, BASELINE = 24, 20, 15


def chinese():
    codes = set(range(0x3000, 0x3040)) | set(range(0xFF01, 0xFF61))
    # GB2312 includes common Simplified Chinese characters and punctuation.
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                char = bytes((lead, trail)).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if 0x3400 <= ord(char) <= 0x9FFF:
                codes.add(ord(char))
    return codes


def joining_forms():
    names = ["<isolated>", "<final>", "<initial>", "<medial>"]
    forms = {}
    for code in range(0xFB50, 0xFF00):
        parts = unicodedata.decomposition(chr(code)).split()
        if len(parts) == 2 and parts[0] in names:
            base = int(parts[1], 16)
            if 0x0600 <= base <= 0x06FF:
                forms.setdefault(base, [0, 0, 0, 0])[names.index(parts[0])] = code
    return forms


def pack(font, code):
    char = chr(code)
    image = Image.new("1", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    advance = round(font.getlength(char))
    draw.text((0, BASELINE), char, font=font, anchor="ls", fill=1)
    return struct.pack("<HB", code, min(WIDTH, max(1, advance))) + image.tobytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cjk_font", type=Path)
    parser.add_argument("arabic_font", type=Path)
    args = parser.parse_args()
    # The third TTC face is Simplified Chinese in the Noto CJK collection.
    cjk = ImageFont.truetype(str(args.cjk_font), 16, index=2, layout_engine=ImageFont.Layout.BASIC)
    arabic = ImageFont.truetype(str(args.arabic_font), 16, layout_engine=ImageFont.Layout.BASIC)
    forms = joining_forms()
    arabic_codes = set(range(0x0600, 0x0700))
    arabic_codes.update(code for row in forms.values() for code in row if code)
    payload = b"".join(pack(arabic if code in arabic_codes else cjk, code) for code in sorted(chinese() | arabic_codes))
    (ROOT / "assets/fonts/AetherWebFallback.bin").write_bytes(payload)
    rows = ["//! Arabic letter joining forms from the Unicode compatibility decompositions.", "pub const Form = struct { base: u21, glyphs: [4]u21 };", "pub const forms = [_]Form{"]
    for code, variants in sorted(forms.items()):
        values = ", ".join(f"0x{value:x}" for value in variants)
        rows.append(f"    .{{ .base = 0x{code:x}, .glyphs = .{{ {values} }} }},")
    rows.append("};")
    (ROOT / "graphics/arabic_forms.zig").write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
