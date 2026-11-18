"""Cut a 3x2 concept sheet (drafts/cat-*.png) into per-state sprites of one skin with a transparent background.

Usage: python3 slice.py [sheet] [outdir] [keep_height]
Each cell is 512x512; the bottom strip with the text label is dropped (keep_height, default 425), the cream
background is removed by flood fill from the cell border, and the result is cropped
to one shared bounding box so every pose keeps the same ground line.
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

SHEET = sys.argv[1] if len(sys.argv) > 1 else "drafts/cat-c.png"
OUT = sys.argv[2] if len(sys.argv) > 2 else "sprites/fluffy"
NAMES = [["idle", "working", "waiting"], ["done", "error", "petted"]]
CELL, TOL = 512, 38
KEEP_H = int(sys.argv[3]) if len(sys.argv) > 3 else 425

sheet = np.asarray(Image.open(SHEET).convert("RGB")).astype(int)
bg = sheet[5, 5]
cells = {}

for r, row in enumerate(NAMES):
    for c, name in enumerate(row):
        cell = sheet[r * CELL : r * CELL + KEEP_H, c * CELL : (c + 1) * CELL]
        h, w, _ = cell.shape
        near_bg = np.abs(cell - bg).sum(axis=2) < TOL
        outside = np.zeros((h, w), bool)
        q = deque((y, x) for y in range(h) for x in (0, w - 1)) + deque((y, x) for x in range(w) for y in (0, h - 1))
        while q:
            y, x = q.popleft()
            if 0 <= y < h and 0 <= x < w and near_bg[y, x] and not outside[y, x]:
                outside[y, x] = True
                q.extend(((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)))
        rgba = np.dstack([cell, np.where(outside, 0, 255)]).astype(np.uint8)
        cells[name] = Image.fromarray(rgba, "RGBA")

boxes = [im.getbbox() for im in cells.values()]
box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
for name, im in cells.items():
    im.crop(box).save(f"{OUT}/{name}.png")
print("box", box)
