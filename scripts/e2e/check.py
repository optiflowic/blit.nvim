#!/usr/bin/env python3
"""Fixture generation and screenshot checks for scripts/e2e/run.sh.

    check.py fixture <out.png> [variant]
    check.py calibrate <req.json> <screenshot.bmp> <calib.json>
    check.py analyze <req.json> <screenshot.bmp> <calib.json>

The fixture is a 4x6 grid of pure colors (channels 0 or 255 only: some
terminals, e.g. Ghostty, color-manage images and shift mid-tones a lot).
Neighboring cells, and cells one or two rows apart, never share a color, so a
misplaced or wrongly cropped image shows up as a wrong color. A variant
shifts every cell's color by the same amount, so a different image of the
same layout can be told apart from the default one (variant 0).

`calibrate` measures cell size and the screen origin from marker blocks that
scenario.lua paints with a Neovim highlight. The terminal draws them as cell
backgrounds, so the measurement is independent of blit: a systematic error in
blit's placement (e.g. every image one cell off) still fails. `analyze`
samples each grid cell where the request says it should be visible, and scans
everything else for leftover fixture colors. Both print one result line and
exit 1 on FAIL. Standard library only (the screenshot is read as BMP; run.sh
converts it).

Image positions are judged against the terminal's cell grid as measured, and
no correction is applied on top. kitty's default placement_strategy=center
moves the whole grid by a fraction of a cell on every window resize. That is
correct terminal behavior, and blit places images in cells, so it is not
something to fix or compensate for: the grid is measured again after every
resize instead.
"""

import json
import os
import struct
import sys
import zlib

GRID_COLS, GRID_ROWS = 4, 6
CELL_PX = 20
COLORS = {
    "red": (255, 0, 0),
    "yellow": (255, 255, 0),
    "green": (0, 255, 0),
    "cyan": (0, 255, 255),
    "blue": (0, 0, 255),
    "magenta": (255, 0, 255),
}
PALETTE = list(COLORS.values())
NAMES = list(COLORS)
# Background of scenario.lua's calibration markers (BlitE2EMarker). Unlike red,
# yellow and green, it cannot be confused with the macOS traffic lights.
MARKER_INDEX = NAMES.index("magenta")
MATCH_TOLERANCE = 80
GHOST_LIMIT = 6


def color_index(gx, gy, variant=0):
    """Color of grid cell (gx, gy); shifting by one or two cells changes it."""
    return (gy + 2 * gx + variant) % len(PALETTE)


def write_fixture(path, variant=0):
    width, height = GRID_COLS * CELL_PX, GRID_ROWS * CELL_PX
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row += bytes(PALETTE[color_index(x // CELL_PX, y // CELL_PX, variant)])
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(b"".join(rows))))
        f.write(chunk(b"IEND", b""))


class Bitmap:
    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        offset = struct.unpack_from("<I", data, 10)[0]
        self.width, height = struct.unpack_from("<ii", data, 18)
        self.top_down = height < 0
        self.height = abs(height)
        bpp, compression = struct.unpack_from("<HI", data, 28)
        if bpp not in (24, 32):
            raise ValueError(f"unsupported BMP depth: {bpp}")
        self.bytes_per_px = bpp // 8
        self.stride = (self.width * self.bytes_per_px + 3) & ~3
        self.data = data[offset:]
        # BI_BITFIELDS: channel masks follow the basic header.
        if compression == 3:
            masks = struct.unpack_from("<III", data, 54)
            self.shifts = [(m & -m).bit_length() - 1 for m in masks]
        else:
            self.shifts = [16, 8, 0]

    def pixel(self, x, y):
        row = y if self.top_down else self.height - 1 - y
        i = row * self.stride + x * self.bytes_per_px
        value = int.from_bytes(self.data[i : i + self.bytes_per_px], "little")
        return tuple((value >> s) & 0xFF for s in self.shifts)


def palette_index(rgb):
    for i, color in enumerate(PALETTE):
        if max(abs(a - b) for a, b in zip(rgb, color)) <= MATCH_TOLERANCE:
            return i
    return None


def intersect(a, b):
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    return (x0, y0, x1, y1) if x0 < x1 and y0 < y1 else None


def cell_rect(calib, rect):
    """Pixel box (x0, y0, x1, y1) for a 1-based cell rectangle."""
    cw, ch = calib["cell_w"], calib["cell_h"]
    x0 = calib["origin_x"] + (rect["col"] - 1) * cw
    y0 = calib["origin_y"] + (rect["row"] - 1) * ch
    return (x0, y0, x0 + rect["cols"] * cw, y0 + rect["rows"] * ch)


def dense_blocks(counts):
    """[start, end] blocks of adjacent entries at least half the maximum, widest first."""
    threshold = max(max(counts) / 2, 1)
    runs = []
    for i, count in enumerate(counts):
        if count < threshold:
            continue
        if runs and i == runs[-1][1] + 1:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    return sorted(runs, key=lambda run: run[0] - run[1])


def find_box(hits, rows):
    """Pixel box of the widest block of hits within the given pixel rows."""
    width = len(hits[0])
    blocks = dense_blocks([sum(hits[y][x] for y in range(rows[0], rows[1] + 1)) for x in range(width)])
    if not blocks:
        return None
    return (blocks[0][0], rows[0], blocks[0][1] + 1, rows[1] + 1)


def calibrate(bmp, markers):
    """Derive cell size and screen origin from the two marker blocks.

    `markers` is the top-left block and the one further right and down. Their
    outer edges span most of the screen, which keeps rounding error small.
    """
    hits = [[palette_index(bmp.pixel(x, y)) == MARKER_INDEX for x in range(bmp.width)] for y in range(bmp.height)]
    row_blocks = sorted(dense_blocks([sum(row) for row in hits])[:2])
    if len(row_blocks) < 2:
        return None
    first = find_box(hits, row_blocks[0])
    second = find_box(hits, row_blocks[1])
    if not first or not second:
        return None
    a, b = markers
    cell_w = (second[2] - first[0]) / (b["col"] + b["cols"] - a["col"])
    cell_h = (second[3] - first[1]) / (b["row"] + b["rows"] - a["row"])
    return {
        "cell_w": cell_w,
        "cell_h": cell_h,
        "origin_x": first[0] - (a["col"] - 1) * cell_w,
        "origin_y": first[1] - (a["row"] - 1) * cell_h,
    }


def sample(bmp, x, y):
    x = min(max(int(x), 0), bmp.width - 1)
    y = min(max(int(y), 0), bmp.height - 1)
    return palette_index(bmp.pixel(x, y))


def check_image(bmp, calib, placement):
    """Return problems for one expected placement, and its visible pixel box."""
    full = cell_rect(calib, placement["image"])
    visible = intersect(full, cell_rect(calib, placement["clip"]))
    if not visible:
        return [], None
    problems = []
    grid_w = (full[2] - full[0]) / GRID_COLS
    grid_h = (full[3] - full[1]) / GRID_ROWS
    for gy in range(GRID_ROWS):
        for gx in range(GRID_COLS):
            grid = (
                full[0] + gx * grid_w,
                full[1] + gy * grid_h,
                full[0] + (gx + 1) * grid_w,
                full[1] + (gy + 1) * grid_h,
            )
            part = intersect(grid, visible)
            # Skip slivers: the terminal rounds crops to whole pixels.
            if not part or part[2] - part[0] < grid_w / 2 or part[3] - part[1] < grid_h / 2:
                continue
            cx, cy = (part[0] + part[2]) / 2, (part[1] + part[3]) / 2
            got = sample(bmp, cx, cy)
            want = color_index(gx, gy, placement.get("variant", 0))
            if got != want:
                row = int((cy - calib["origin_y"]) // calib["cell_h"]) + 1
                col = int((cx - calib["origin_x"]) // calib["cell_w"]) + 1
                found = "blank" if got is None else NAMES[got]
                problems.append(f"screen {row},{col}: {found}, expected {NAMES[want]}")
    return problems, visible


def find_ghosts(bmp, calib, screen, keep_out):
    """Look for fixture colors inside the terminal grid but outside keep_out."""
    margin = min(calib["cell_w"], calib["cell_h"]) / 3
    step = max(1, int(min(calib["cell_w"], calib["cell_h"]) / 4))
    boxes = [(b[0] - margin, b[1] - margin, b[2] + margin, b[3] + margin) for b in keep_out]
    grid = cell_rect(calib, {"row": 1, "col": 1, "rows": screen["rows"], "cols": screen["cols"]})
    x0, y0 = max(0, int(grid[0])), max(0, int(grid[1]))
    x1, y1 = min(bmp.width, int(grid[2])), min(bmp.height, int(grid[3]))
    hits = []
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            if any(b[0] <= x < b[2] and b[1] <= y < b[3] for b in boxes):
                continue
            if palette_index(bmp.pixel(x, y)) is not None:
                hits.append((x, y))
    if len(hits) <= GHOST_LIMIT:
        return None
    x, y = hits[0]
    row = int((y - calib["origin_y"]) // calib["cell_h"]) + 1
    col = int((x - calib["origin_x"]) // calib["cell_w"]) + 1
    return f"fixture pixels outside expected area, first near screen {row},{col}"


def report(name, problems):
    """Print the result line; return the exit code."""
    if problems:
        shown = "; ".join(problems[:3])
        more = f" (+{len(problems) - 3} more)" if len(problems) > 3 else ""
        print(f"FAIL {name}: {shown}{more}")
        return 1
    print(f"PASS {name}")
    return 0


def load_request(req_path):
    with open(req_path) as f:
        return json.load(f)


def write_calibration(req_path, bmp_path, calib_path):
    """Write calib.json from the markers, or remove it so later checks fail."""
    req = load_request(req_path)
    bmp = Bitmap(bmp_path)
    calib = calibrate(bmp, req["markers"])
    if not calib:
        if os.path.exists(calib_path):
            os.remove(calib_path)
        return report(req["name"], ["calibration markers not found on screen"])
    with open(calib_path, "w") as f:
        json.dump(calib, f)
    # No image may be visible while the markers are, since they share colors.
    keep_out = [cell_rect(calib, marker) for marker in req["markers"]]
    ghost = find_ghosts(bmp, calib, req["screen"], keep_out)
    return report(req["name"], [ghost] if ghost else [])


def analyze(req_path, bmp_path, calib_path):
    req = load_request(req_path)
    if not os.path.exists(calib_path):
        return report(req["name"], ["no calibration (the last calibration failed)"])
    with open(calib_path) as f:
        calib = json.load(f)
    bmp = Bitmap(bmp_path)

    problems, keep_out = [], []
    for placement in req["images"]:
        image_problems, visible = check_image(bmp, calib, placement)
        problems += image_problems
        if visible:
            keep_out.append(visible)
    ghost = find_ghosts(bmp, calib, req["screen"], keep_out)
    if ghost:
        problems.append(ghost)
    return report(req["name"], problems)


def main(argv):
    if len(argv) in (3, 4) and argv[1] == "fixture":
        write_fixture(argv[2], int(argv[3]) if len(argv) == 4 else 0)
        return 0
    if len(argv) == 5 and argv[1] == "calibrate":
        return write_calibration(argv[2], argv[3], argv[4])
    if len(argv) == 5 and argv[1] == "analyze":
        return analyze(argv[2], argv[3], argv[4])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
