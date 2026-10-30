#!/usr/bin/env python3
"""Renders a 1024x1024 PNG app icon (two quota rings on a rounded tile) with no third-party modules.
macOS: Scripts/make-icon.sh turns it into build/AppIcon.icns, which build-app.sh bundles."""
import math, struct, sys, zlib

SIZE = 1024
BG = (28, 30, 38)
TILE = (46, 50, 64)
RING1 = (52, 199, 89)    # Claude ring (green)
RING2 = (90, 165, 250)   # Codex ring (blue)
TRACK = (120, 125, 140)

def rounded_tile(x, y, s, r):
    cx = min(max(x, r), s - r); cy = min(max(y, r), s - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

def ring(x, y, cx, cy, radius, width, start_deg, sweep_deg):
    d = math.hypot(x - cx, y - cy)
    if abs(d - radius) > width / 2:
        return False
    ang = (math.degrees(math.atan2(-(y - cy), x - cx)) - 90) % 360
    a = (-ang) % 360
    return a <= sweep_deg

def pixel(x, y):
    if not rounded_tile(x, y, SIZE, 220):
        return BG + (0,)
    col = TILE
    cx = cy = SIZE / 2
    # outer dashed-looking track + blue arc (Codex)
    if ring(x, y, cx, cy, 330, 54, 0, 360):
        col = TRACK if (int(math.degrees(math.atan2(y - cy, x - cx)) // 12) % 2 == 0) else TILE
    if ring(x, y, cx, cy, 330, 54, 0, 150):
        col = RING2
    # inner track + green arc (Claude)
    if ring(x, y, cx, cy, 215, 90, 0, 360):
        col = TRACK
    if ring(x, y, cx, cy, 215, 90, 0, 250):
        col = RING1
    return col + (255,)

def write_png(path):
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        for x in range(SIZE):
            raw.extend(pixel(x, y))
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "build/AppIcon-1024.png"
    write_png(out)
    print("wrote", out)
