"""Cut the tile out of a generated icon draft and lay it on the macOS icon grid.

usage: python3 icon/make_icon.py icon/source.png
Writes icon/AppIcon.png (1024) and icon/AppIcon.icns.
"""
import subprocess, sys, shutil
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw

src = Image.open(sys.argv[1]).convert("RGB")
# The tile is everything clearly away from the white background; the soft shadow stays under the threshold.
diff = ImageChops.difference(src, Image.new("RGB", src.size, "white")).convert("L")
box = diff.point(lambda v: 255 if v > 45 else 0).getbbox()
print("tile bbox", box)
# The shadow pads the bottom of the bbox; the tile is square, so trust its width.
# Inset past the anti-aliased rim so no white shows through our own mask.
side = box[2] - box[0]
i = 0 if box == (0, 0, *src.size) else round(side * 0.02)  # full-bleed drafts need no inset
tile = src.crop((box[0] + i, box[1] + i, box[2] - i, box[1] + side - i)).resize((824, 824), Image.LANCZOS)
# macOS 26 masks a full-bleed opaque square itself; a pre-shaped tile with transparent corners gets
# boxed into a gray plate ("icon jail"), so ship the art edge to edge.
out = tile.resize((1024, 1024), Image.LANCZOS)
# Fill the draft's own white rounded corners with the tile color next to them, so the system mask finds no white.
keep = ImageChops.difference(out, Image.new("RGB", out.size, "white")).convert("L").point(lambda v: 255 if v > 45 else 0)
inner = Image.new("L", out.size, 0)  # only touch pixels outside the draft's rounded corners (whiskers are white too)
ImageDraw.Draw(inner).rounded_rectangle((0, 0, 1023, 1023), radius=260, fill=255)
keep = ImageChops.lighter(keep, inner)
for cx, cy in ((0, 0), (1, 0), (0, 1), (1, 1)):
    x0, y0 = cx * 768, cy * 768
    fill = Image.new("RGB", (256, 256), out.getpixel((x0 + 128 + (60 if cx == 0 else -60), y0 + 128 + (60 if cy == 0 else -60))))
    region = out.crop((x0, y0, x0 + 256, y0 + 256))
    out.paste(Image.composite(region, fill, keep.crop((x0, y0, x0 + 256, y0 + 256))), (x0, y0))

here = Path(__file__).parent
out.save(here / "AppIcon.png")
iconset = here / "AppIcon.iconset"
shutil.rmtree(iconset, ignore_errors=True)
iconset.mkdir()
for s in (16, 32, 128, 256, 512):
    out.resize((s, s), Image.LANCZOS).save(iconset / f"icon_{s}x{s}.png")
    out.resize((s * 2, s * 2), Image.LANCZOS).save(iconset / f"icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(here / "AppIcon.icns")], check=True)
shutil.rmtree(iconset)
print("wrote", here / "AppIcon.icns")
