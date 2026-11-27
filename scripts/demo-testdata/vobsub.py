"""Minimal VobSub (.idx/.sub) writer.

ffmpeg's dvdsub encoder needs a bitmap subtitle source, so this module writes
the DVD sub-picture stream directly: each cue is a 2-bit RLE bitmap in an SPU
packet, wrapped in MPEG-2 program-stream packs of 2048 bytes. The result is
readable by ffmpeg's vobsub demuxer, VLC, Plex and Jellyfin, and can be muxed
into Matroska with `ffmpeg -i x.idx -c copy`.
"""
import struct
from PIL import Image, ImageDraw, ImageFont

SECTOR = 2048
# palette index 0 black, 1 white, 2 grey, 3 yellow; the rest unused
PALETTE = ["000000", "ffffff", "808080", "ffff00"] + ["000000"] * 12


def render_cue(text, width, height, font_path=None, size=36):
    """Text -> 2-bit pixel rows (0 transparent, 1 fill, 2 outline)."""
    font = ImageFont.truetype(font_path, size) if font_path else ImageFont.load_default(size)
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    l, t, r, b = probe.textbbox((0, 0), text, font=font, stroke_width=3)
    w, h = r - l + 8, b - t + 8
    w += w % 2
    h += h % 2
    fill = Image.new("L", (w, h))
    edge = Image.new("L", (w, h))
    ImageDraw.Draw(edge).text((4 - l, 4 - t), text, font=font, fill=255, stroke_width=3, stroke_fill=255)
    ImageDraw.Draw(fill).text((4 - l, 4 - t), text, font=font, fill=255)
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            if fill.getpixel((x, y)) > 127:
                row.append(1)
            elif edge.getpixel((x, y)) > 127:
                row.append(2)
            else:
                row.append(0)
        rows.append(row)
    x0 = (width - w) // 2
    y0 = height - h - 40
    return rows, x0, y0


class _Nibbles:
    def __init__(self):
        self.n = []

    def put(self, value, count):
        for i in reversed(range(count)):
            self.n.append((value >> (4 * i)) & 0xF)

    def align(self):
        if len(self.n) % 2:
            self.n.append(0)

    def bytes(self):
        self.align()
        return bytes((self.n[i] << 4) | self.n[i + 1] for i in range(0, len(self.n), 2))


def _rle_field(rows):
    out = _Nibbles()
    for row in rows:
        x = 0
        while x < len(row):
            c = row[x]
            n = 1
            while x + n < len(row) and row[x + n] == c and n < 255:
                n += 1
            if x + n == len(row) and n > 63 and c == 0:
                out.put(c, 4)  # 0000 0000 0000 00cc: fill to end of line
            elif n < 4:
                out.put((n << 2) | c, 1)
            elif n < 16:
                out.put((n << 2) | c, 2)
            elif n < 64:
                out.put((n << 2) | c, 3)
            else:
                out.put((n << 2) | c, 4)
            x += n
        out.align()
    return out.bytes()


def spu(rows, x0, y0, duration_s):
    top = _rle_field(rows[0::2])
    bottom = _rle_field(rows[1::2])
    h, w = len(rows), len(rows[0])
    top_off = 4
    bot_off = top_off + len(top)
    ctrl1 = bot_off + len(bottom)
    x1, x2, y1, y2 = x0, x0 + w - 1, y0, y0 + h - 1
    cmds1 = (bytes([0x03, (2 << 4) | 0, (1 << 4) | 0])          # colours: px3 grey, px2 black, px1 white, px0 black
             + bytes([0x04, 0xFF, 0xF0])                         # alpha: px0 transparent, the rest opaque
             + bytes([0x05, x1 >> 4, ((x1 & 0xF) << 4) | (x2 >> 8), x2 & 0xFF,
                      y1 >> 4, ((y1 & 0xF) << 4) | (y2 >> 8), y2 & 0xFF])
             + bytes([0x06]) + struct.pack(">HH", top_off, bot_off)
             + bytes([0x01, 0xFF]))
    ctrl2 = ctrl1 + 4 + len(cmds1)
    ctrl2 += ctrl2 % 2
    delay = int(duration_s * 90000 / 1024)
    seq1 = struct.pack(">HH", 0, ctrl2) + cmds1
    seq1 += b"\xff" * (ctrl2 - ctrl1 - len(seq1))
    seq2 = struct.pack(">HH", delay, ctrl2) + bytes([0x02, 0xFF])
    body = top + bottom + seq1 + seq2
    size = 4 + len(body)
    return struct.pack(">HH", size, ctrl1) + body


def _ts(v, marker):
    return bytes([(marker << 4) | (((v >> 30) & 0x7) << 1) | 1,
                  (v >> 22) & 0xFF, (((v >> 15) & 0x7F) << 1) | 1,
                  (v >> 7) & 0xFF, ((v & 0x7F) << 1) | 1])


def _pack_header(scr):
    b = bytearray(10)
    b[0] = 0x44 | (((scr >> 30) & 0x7) << 3) | ((scr >> 28) & 0x3)
    b[1] = (scr >> 20) & 0xFF
    b[2] = (((scr >> 15) & 0x1F) << 3) | 0x04 | ((scr >> 13) & 0x3)
    b[3] = (scr >> 5) & 0xFF
    b[4] = ((scr & 0x1F) << 3) | 0x04
    b[5] = 0x01
    mux = 25200
    b[6], b[7], b[8] = (mux >> 14) & 0xFF, (mux >> 6) & 0xFF, ((mux & 0x3F) << 2) | 0x3
    b[9] = 0xF8
    return b"\x00\x00\x01\xba" + bytes(b)


def _sectors(packet, pts):
    out = []
    first = True
    pos = 0
    while pos < len(packet):
        hdr_extra = 5 if first else 0
        room = SECTOR - 14 - 9 - hdr_extra - 1
        chunk = packet[pos:pos + room]
        left = room - len(chunk)
        if 0 < left < 6:  # no space for a padding packet: shorten the chunk
            chunk = chunk[:len(chunk) - 6]
            left = room - len(chunk)
        flags = 0x80 if first else 0x00
        pes_body = bytes([0x81, flags, hdr_extra]) + (_ts(pts, 0x2) if first else b"") + b"\x20" + chunk
        pes = b"\x00\x00\x01\xbd" + struct.pack(">H", len(pes_body)) + pes_body
        sector = _pack_header(pts) + pes
        pad = SECTOR - len(sector)
        if pad:
            sector += b"\x00\x00\x01\xbe" + struct.pack(">H", pad - 6) + b"\xff" * (pad - 6)
        assert len(sector) == SECTOR
        out.append(sector)
        pos += len(chunk)
        first = False
    return out


def write(stem, cues, width, height, lang="en", font_path=None):
    """cues: [(start_s, end_s, text)] -> stem.idx + stem.sub"""
    sub = bytearray()
    lines = []
    for start, end, text in cues:
        rows, x0, y0 = render_cue(text, width, height, font_path)
        pts = int(start * 90000)
        filepos = len(sub)
        for s in _sectors(spu(rows, x0, y0, end - start), pts):
            sub += s
        ms = int(start * 1000)
        hh, mm, ss, mmm = ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000
        lines.append(f"timestamp: {hh:02d}:{mm:02d}:{ss:02d}:{mmm:03d}, filepos: {filepos:09x}")
    idx = "\n".join([
        "# VobSub index file, v7 (do not modify this line!)",
        f"size: {width}x{height}", "org: 0, 0", "scale: 100%, 100%", "alpha: 100%",
        "smooth: OFF", "fadein/out: 0, 0", "align: OFF at LEFT TOP", "time offset: 0",
        "forced subs: OFF", "palette: " + ", ".join(PALETTE),
        "custom colors: OFF, tridx: 0000, colors: 000000, 000000, 000000, 000000",
        "langidx: 0", f"id: {lang}, index: 0", *lines, ""])
    with open(f"{stem}.sub", "wb") as f:
        f.write(sub)
    with open(f"{stem}.idx", "w") as f:
        f.write(idx)
